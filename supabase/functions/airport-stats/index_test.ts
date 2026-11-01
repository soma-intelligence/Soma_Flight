// airport-stats without a database or a provider: the boards, the airports table and the rate limit
// are fakes. Covers BOARD_PROVIDER=none (no call at all), the detail and list shapes, the trend, the
// traffic counts and a provider failure in the list.
import { assert, assertEquals } from "jsr:@std/assert@1";
import type { AirportRow } from "../_shared/airport_codes.ts";
import type { BoardRow } from "../_shared/board_rows.ts";
import { ApiError } from "../_shared/errors.ts";
import {
  type Board,
  type Deps,
  type Detail,
  type Direction,
  handler,
  type List,
  MAX_AIRPORTS,
  traffic,
  trend,
} from "./handler.ts";

const NOW = new Date("2026-10-31T20:10:00Z");
const ROWS: AirportRow[] = [
  { icao: "KSFO", iata: "SFO", country: "US" },
  { icao: "KLAX", iata: "LAX", country: "US" },
  { icao: "KJFK", iata: "JFK", country: "US" },
  { icao: "CYVR", iata: "YVR", country: "CA" },
  { icao: "RJTT", iata: "HND", country: "JP" },
];

const verifier = {
  auth: {
    getUser: (jwt: string) =>
      Promise.resolve({ data: { user: { id: jwt } }, error: null }),
  },
};

const iso = (minutes: number) =>
  new Date(NOW.getTime() + minutes * 60_000).toISOString();

/** A departure from SFO: scheduled `at` minutes from now, `late` minutes late, actual when done. */
function dep(
  n: number,
  to: string,
  op: string,
  at: number,
  late: number | null,
  status: BoardRow["status"] = "departed",
): BoardRow {
  const done = at + (late ?? 0) <= 0 && status !== "canceled";
  return {
    id: `d${n}`,
    provider_id: `p${n}`,
    ident: `${op}${n}`,
    operator: op,
    origin_icao: "KSFO",
    origin_iata: "SFO",
    destination_icao: to,
    destination_iata: null,
    scheduled_out: iso(at),
    scheduled_in: iso(at + 90),
    estimated_out: late === null ? null : iso(at + late),
    estimated_in: null,
    scheduled_off: null,
    scheduled_on: null,
    estimated_off: null,
    estimated_on: null,
    actual_out: done ? iso(at + (late ?? 0)) : null,
    actual_off: null,
    actual_on: null,
    actual_in: null,
    gate_origin: null,
    gate_destination: null,
    terminal_origin: null,
    terminal_destination: null,
    baggage_belt: null,
    aircraft_type: null,
    registration: null,
    status: done ? status : status === "canceled" ? "canceled" : "scheduled",
    updated_at: NOW.toISOString(),
  };
}

const DEPARTURES: BoardRow[] = [
  dep(1, "KLAX", "UAL", -110, 0),
  dep(2, "KLAX", "UAL", -100, 5),
  dep(3, "KJFK", "DAL", -70, 40),
  dep(4, "CYVR", "ACA", -50, 0, "canceled"),
  dep(5, "RJTT", "UAL", -20, 20),
  dep(6, "KLAX", "SWA", 30, 25),
];

function deps(over: Partial<Deps> = {}) {
  const calls: string[] = [];
  const d: Deps = {
    verifier,
    now: () => NOW,
    provider: "aeroapi",
    airports: (codes) =>
      Promise.resolve(
        ROWS.filter((r) => codes.includes(r.icao) || codes.includes(r.iata!)),
      ),
    board: (icao: string, kind: Direction): Promise<Board> => {
      calls.push(`${icao} ${kind}`);
      return Promise.resolve({
        flights: kind === "departures" ? DEPARTURES : [],
        fetchedAt: NOW.toISOString(),
        stale: false,
      });
    },
    ...over,
  };
  return { d, calls };
}

async function ask<T>(query: string, d: Deps) {
  const res = await handler(
    new Request(`http://localhost/airport-stats?${query}`, {
      headers: { authorization: "Bearer user-1" },
    }),
    d,
  );
  return { status: res.status, body: await res.json() as T };
}

Deno.test("BOARD_PROVIDER=none: available false, no board call, no rate count", async () => {
  let rated = 0;
  const { d, calls } = deps({
    provider: "none",
    rate: () => {
      rated++;
      return Promise.resolve();
    },
  });
  const one = await ask<Detail>("airport=SFO", d);
  assertEquals(one.status, 200);
  assertEquals(one.body.available, false);
  assertEquals(one.body.reason, "no_provider");
  assertEquals(one.body.icao, "KSFO");
  assertEquals(one.body.departures, null);
  const list = await ask<List>("airports=SFO,LAX", d);
  assertEquals(list.body.available, false);
  assertEquals(list.body.airports, []);
  assertEquals(calls, []);
  assertEquals(rated, 0);
});

Deno.test("detail: counts, trend and traffic from the boards", async () => {
  const { d, calls } = deps();
  const r = await ask<Detail>("airport=SFO", d);
  assertEquals(r.status, 200);
  assertEquals(calls.sort(), ["KSFO arrivals", "KSFO departures"]);
  const b = r.body;
  assertEquals(b.available, true);
  assertEquals(b.provider, "aeroapi");
  // Flights due by now: 1 to 5. On time: 1 and 2 (5 min is on time); late 15+: 3 and 5; canceled: 4.
  assertEquals(b.departures!.total, 5);
  assertEquals(b.departures!.on_time, 2);
  assertEquals(b.departures!.delayed, 2);
  assertEquals(b.departures!.canceled, 1);
  assertEquals(b.arrivals!.total, 0);
  const t = b.today!;
  assertEquals(t.departures, 5, "canceled flights do not count as traffic");
  assertEquals(t.airlines, 3);
  assertEquals(t.airports_served, 3);
  assertEquals(t.countries_served, 2);
  assertEquals(t.busiest_airlines[0], { operator: "UAL", flights: 3 });
  assertEquals(t.busiest_routes[0], { icao: "KLAX", flights: 3 });
  assertEquals(b.next_7_days, null);
});

Deno.test("trend: by UTC hour of the schedule, actual first, estimated ahead", () => {
  const bins = trend(DEPARTURES, "departures");
  const last = bins[bins.length - 1];
  assertEquals(last.estimated, true, "the flight ahead is an estimate");
  assertEquals(last.avg_delay_minutes, 25);
  assert(bins.slice(0, -1).every((b) => !b.estimated));
  assertEquals(bins.reduce((n, b) => n + b.flights, 0), 5, "canceled left out");
});

Deno.test("traffic without countries known counts zero countries", () => {
  const t = traffic(DEPARTURES, () => null);
  assertEquals(t.countries_served, 0);
  assertEquals(t.busiest_routes.length, 3, "the canceled route is left out");
});

Deno.test("list: one summary per airport; a provider failure marks only that airport", async () => {
  const { d } = deps({
    board: (icao, kind) =>
      icao === "KJFK"
        ? Promise.reject(new ApiError("provider_unavailable", 503))
        : Promise.resolve({
          flights: kind === "departures" ? DEPARTURES : [],
          fetchedAt: NOW.toISOString(),
          stale: true,
        }),
  });
  const r = await ask<List>("airports=SFO,JFK,ZZZ", d);
  assertEquals(r.status, 200);
  assertEquals(r.body.airports.map((a) => a.icao), ["KSFO", "KJFK"]);
  assertEquals(r.body.airports[0].departures?.on_time, 2);
  assertEquals(r.body.airports[0].stale, true);
  assertEquals(r.body.airports[1].error, "provider_unavailable");
  assertEquals(r.body.airports[1].departures, null);
});

Deno.test("request checks", async () => {
  const { d } = deps();
  assertEquals((await ask("airport=SFO,LAX", d)).status, 400, "one code");
  assertEquals((await ask("airport=ZZZZ", d)).status, 400, "unknown");
  const many = Array.from(
    { length: MAX_AIRPORTS + 1 },
    (_, i) => `K${String(i).padStart(3, "0")}`,
  ).join(",");
  assertEquals((await ask(`airports=${many}`, d)).status, 400);
  const limited = deps({
    rate: () => Promise.reject(new ApiError("rate_limited", 429)),
  });
  assertEquals((await ask("airport=SFO", limited.d)).status, 429);
  const noToken = await handler(
    new Request("http://localhost/airport-stats?airport=SFO"),
    d,
  );
  assertEquals(noToken.status, 401);
});

const CONTRACT_DIR = new URL("./contract/", import.meta.url);

/** Compares to contract/<name>.json; UPDATE_CONTRACT=1 rewrites it from the handler's answer. */
async function checkContract(name: string, actual: unknown) {
  const url = new URL(`${name}.json`, CONTRACT_DIR);
  const text = JSON.stringify(actual, null, 2) + "\n";
  if (Deno.env.get("UPDATE_CONTRACT") === "1") {
    await Deno.mkdir(CONTRACT_DIR, { recursive: true });
    await Deno.writeTextFile(url, text);
    return;
  }
  assertEquals(
    JSON.parse(await Deno.readTextFile(url)),
    JSON.parse(text),
    `contract/${name}.json is out of date: run with UPDATE_CONTRACT=1`,
  );
}

Deno.test("contract examples match the handler's answers", async () => {
  const { d } = deps();
  await checkContract("detail", (await ask("airport=SFO", d)).body);
  await checkContract("list", (await ask("airports=SFO,LAX", d)).body);
  const none = deps({ provider: "none" }).d;
  await checkContract("no_provider", (await ask("airport=SFO", none)).body);
});

Deno.test("detail: the most disrupted routes and airlines, worst first", async () => {
  const { d } = deps();
  const r = await ask<Detail>("airport=SFO", d);
  const routes = r.body.departures!.worst_routes.map((x) => x.icao);
  assert(routes.includes("KJFK") && routes.includes("RJTT"), routes.join());
  assert(
    r.body.departures!.worst_airlines.some((a) =>
      a.operator === "ACA" && a.canceled === 1
    ),
  );
});
