import {
  assert,
  assertEquals,
  assertRejects,
  assertThrows,
} from "jsr:@std/assert@1";
import {
  AeroApi,
  dedupeByFaFlightId,
  ENDPOINT_COST,
  estimateCost,
  toFlightRow,
  toFlightRows,
} from "./aeroapi.ts";
import type { AeroFlight } from "./aeroapi_types.ts";
import { ApiError, errorResponse } from "./errors.ts";
import { requireUser } from "./auth.ts";

const fixture = (name: string) =>
  Deno.readTextFile(new URL(`./fixtures/${name}`, import.meta.url));
const flightsOf = async (name: string, key: string): Promise<AeroFlight[]> =>
  JSON.parse(await fixture(name))[key];

type Handler = (req: Request) => Response | Promise<Response>;

function fakeFetch(
  body: string | null,
  status = 200,
  calls: Request[] = [],
): typeof fetch {
  return (input, init) => {
    calls.push(new Request(input as string, init));
    return Promise.resolve(
      new Response(body, {
        status,
        headers: { "content-type": "application/json" },
      }),
    );
  };
}

function routed(handler: Handler, calls: Request[] = []): typeof fetch {
  return (input, init) => {
    const req = new Request(input as string, init);
    calls.push(req);
    return Promise.resolve(handler(req));
  };
}

const NOW = new Date("2026-11-03T10:00:00Z");
const opts = { now: () => NOW };
const path = (r: Request) => new URL(r.url).pathname.replace("/aeroapi", "");

Deno.test("flightsByIdent parses fixture", async () => {
  const api = new AeroApi("k", fakeFetch(await fixture("flight_af84.json")));
  const flights = await api.flightsByIdent("AF84");
  assertEquals(flights.length, 1);
  assertEquals(flights[0].ident_iata, "AF84");
  const row = toFlightRow(flights[0], NOW);
  assertEquals(row.origin_icao, "LFPG");
  assertEquals(row.destination_icao, "KSFO");
  assert(row.scheduled_out !== null);
  assertEquals(row.status, "en_route");
  assertEquals(row.baggage_belt, "G");
  assertEquals(row.ident, "AF84");
  assertEquals(row.updated_at, NOW.toISOString());
  // The ident endpoint carries no position, so the row must not touch position columns.
  assert(!("position_lat" in row));
});

Deno.test("toFlightRow maps off and on times", async () => {
  const f = (await flightsOf("flight_af84.json", "flights"))[0];
  const row = toFlightRow({
    ...f,
    scheduled_off: "2026-11-03T01:00:00Z",
    scheduled_on: "2026-11-03T11:00:00Z",
    estimated_off: "2026-11-03T01:05:00Z",
    estimated_on: "2026-11-03T11:05:00Z",
  }, NOW);
  assertEquals(row.scheduled_off, "2026-11-03T01:00:00Z");
  assertEquals(row.scheduled_on, "2026-11-03T11:00:00Z");
  assertEquals(row.estimated_off, "2026-11-03T01:05:00Z");
  assertEquals(row.estimated_on, "2026-11-03T11:05:00Z");
  assertEquals(
    toFlightRow({ ...f, scheduled_off: null }, NOW).scheduled_off,
    null,
  );
});

Deno.test("flight fixture has no last_position (real endpoint does not return it)", async () => {
  const f = (await flightsOf("flight_af84.json", "flights"))[0];
  assert(!("last_position" in f));
});

Deno.test("flightsByIdent passes start/end and tolerates a non-array flights", async () => {
  const calls: Request[] = [];
  const api = new AeroApi("k", fakeFetch('{"flights":"oops"}', 200, calls));
  assertEquals(
    await api.flightsByIdent("AFR84", "2026-11-03", "2026-11-04"),
    [],
  );
  const u = new URL(calls[0].url);
  assertEquals(u.searchParams.get("start"), "2026-11-03");
  assertEquals(u.searchParams.get("end"), "2026-11-04");
});

Deno.test("flightById sends ident_type=fa_flight_id, null on 404", async () => {
  const calls: Request[] = [];
  const api = new AeroApi(
    "k",
    fakeFetch(await fixture("flight_af84.json"), 200, calls),
  );
  const f = await api.flightById("AFR84-1793600000-schedule-1234p");
  assertEquals(f?.ident_iata, "AF84");
  assertEquals(
    new URL(calls[0].url).searchParams.get("ident_type"),
    "fa_flight_id",
  );
  assertEquals(
    await new AeroApi("k", fakeFetch("{}", 404)).flightById("x"),
    null,
  );
});

Deno.test("flightPosition maps last_position to position columns", async () => {
  const calls: Request[] = [];
  const seen: string[] = [];
  const api = new AeroApi(
    "k",
    fakeFetch(await fixture("position_af84.json"), 200, calls),
    (e) => {
      seen.push(e);
      return Promise.resolve();
    },
  );
  const p = await api.flightPosition("AFR84-1793600000-schedule-1234p");
  assertEquals(p, {
    position_lat: 57.48,
    position_lon: -21.35,
    position_altitude_ft: 38000,
    position_ground_speed_kt: 512,
    position_heading: 312,
    position_at: "2026-11-03T16:42:10Z",
  });
  assertEquals(
    path(calls[0]),
    "/flights/AFR84-1793600000-schedule-1234p/position",
  );
  assertEquals(seen, ["/flights/{id}/position"]);
  assertEquals(
    await new AeroApi("k", fakeFetch("{}", 404)).flightPosition("x"),
    null,
  );
  assertEquals(
    await new AeroApi("k", fakeFetch('{"last_position":null}')).flightPosition(
      "x",
    ),
    null,
  );
});

Deno.test("airportFlights hits each of the four lists and parses departures", async () => {
  for (
    const kind of [
      "departures",
      "arrivals",
      "scheduled_departures",
      "scheduled_arrivals",
    ] as const
  ) {
    const calls: Request[] = [];
    const api = new AeroApi(
      "k",
      fakeFetch(`{"${kind}":[],"links":null,"num_pages":1}`, 200, calls),
    );
    assertEquals(await api.airportFlights("KAUS", kind), []);
    assertEquals(path(calls[0]), `/airports/KAUS/flights/${kind}`);
  }
  const api = new AeroApi(
    "k",
    fakeFetch(await fixture("departures_kaus.json")),
  );
  const flights = await api.airportFlights("KAUS", "departures");
  assertEquals(flights.length, 1);
  const row = toFlightRow(flights[0], NOW);
  assertEquals(row.status, "en_route"); // departed from airport, wheels up
  assertEquals(row.origin_icao, "KAUS");
});

Deno.test("airportFlights follows links.next up to maxPages and meters every page", async () => {
  const seen: string[] = [];
  const calls: Request[] = [];
  const page1 = await fixture("departures_kaus.json");
  const page2 = await fixture("departures_kaus_page2.json");
  const api = new AeroApi(
    "k",
    routed((r) => {
      const cursor = new URL(r.url).searchParams.get("cursor");
      return new Response(cursor ? page2 : page1, { status: 200 });
    }, calls),
    (e) => {
      seen.push(e);
      return Promise.resolve();
    },
  );
  const all = await api.airportFlights("KAUS", "departures", 2);
  assertEquals(all.map((f) => f.ident_iata), ["UA1630", "AA1822"]);
  assertEquals(
    new URL(calls[1].url).searchParams.get("cursor"),
    "gAAAAABnKAUS1",
  );
  assertEquals(seen.length, 2);
  // maxPages=1 stops after the first page even if a next link exists.
  calls.length = 0;
  assertEquals((await api.airportFlights("KAUS", "departures", 1)).length, 1);
  assertEquals(calls.length, 1);
});

Deno.test("boardFlights merges done and upcoming, dedupes by fa_flight_id, done wins", async () => {
  const dep = await fixture("departures_kaus.json");
  const dep2 = await fixture("departures_kaus_page2.json");
  const sched = await fixture("scheduled_departures_kaus.json");
  const calls: Request[] = [];
  const api = new AeroApi(
    "k",
    routed((r) => {
      const p = path(r);
      if (p.endsWith("/scheduled_departures")) return new Response(sched);
      return new Response(
        new URL(r.url).searchParams.get("cursor") ? dep2 : dep,
      );
    }, calls),
  );
  const board = await api.boardFlights("KAUS", "departures");
  const ids = board.map((f) => f.ident_iata);
  assertEquals(ids, ["UA1630", "AA1822", "DL1744", "AA2417", "WN1182"]);
  // UA1630 is in both lists; the departed copy (with actual_off) is kept.
  assert(board[0].actual_off !== null);
  assertEquals(new Set(ids).size, ids.length);
  // Cancelled flights show up in scheduled_departures.
  assertEquals(toFlightRow(board[2], NOW).status, "canceled");
  assertEquals(
    calls.filter((c) => path(c).endsWith("scheduled_departures")).length,
    1,
  );
  // arrivals use the arrivals pair
  const arr = new AeroApi("k", routed(() => new Response("{}"), calls));
  calls.length = 0;
  await arr.boardFlights("KAUS", "arrivals");
  assertEquals(calls.map(path), [
    "/airports/KAUS/flights/arrivals",
    "/airports/KAUS/flights/scheduled_arrivals",
  ]);
});

Deno.test("searchRoute uses flights/to with a one-day nonstop window and returns flights", async () => {
  const calls: Request[] = [];
  const api = new AeroApi(
    "k",
    fakeFetch(await fixture("route_kaus_kdfw.json"), 200, calls),
    undefined,
    opts,
  );
  const flights = await api.searchRoute("KAUS", "KDFW", "2026-11-03");
  // third itinerary departs 2026-11-04 UTC and is outside the day
  assertEquals(flights.map((f) => f.ident_iata), ["AA2417", "AA2431"]);
  assert(flights[0].scheduled_out !== null);
  assertEquals(path(calls[0]), "/airports/KAUS/flights/to/KDFW");
  const u = new URL(calls[0].url);
  assertEquals(u.searchParams.get("connection"), "nonstop");
  assertEquals(u.searchParams.get("start"), "2026-11-03T00:00:00.000Z");
  assertEquals(u.searchParams.get("end"), "2026-11-04T00:00:00.000Z");
});

Deno.test("searchRoute skips multi-leg itineraries and out-of-window dates without a call", async () => {
  const calls: Request[] = [];
  const two = JSON.stringify({
    flights: [{ segments: [{ fa_flight_id: "a" }, { fa_flight_id: "b" }] }],
    links: null,
    num_pages: 1,
  });
  const api = new AeroApi("k", fakeFetch(two, 200, calls), undefined, opts);
  assertEquals(await api.searchRoute("KAUS", "KDFW", "2026-11-03"), []);
  assertEquals(calls.length, 1);
  assertEquals(await api.searchRoute("KAUS", "KDFW", "2026-10-01"), []); // too far back
  assertEquals(await api.searchRoute("KAUS", "KDFW", "2026-11-20"), []); // too far ahead
  assertEquals(await api.searchRoute("KAUS", "KDFW", "not-a-date"), []);
  assertEquals(calls.length, 1);
});

for (
  const [status, code] of [[404, "not_found"], [429, "rate_limited"], [
    503,
    "provider_unavailable",
  ]] as const
) {
  Deno.test(`${status} becomes ${code}`, async () => {
    const api = new AeroApi("k", fakeFetch("{}", status));
    const e = await assertRejects(() => api.flightsByIdent("AF84"), ApiError);
    assertEquals(e.code, code);
  });
}

for (const status of [400, 401, 402, 403]) {
  Deno.test(`${status} becomes provider_unavailable and logs status and endpoint, not the key`, async () => {
    const logs: unknown[][] = [];
    const orig = console.error;
    console.error = (...a: unknown[]) => void logs.push(a);
    try {
      const api = new AeroApi(
        "super-secret",
        fakeFetch('{"detail":"nope"}', status),
      );
      const e = await assertRejects(() => api.flightsByIdent("AF84"), ApiError);
      assertEquals(e.code, "provider_unavailable");
    } finally {
      console.error = orig;
    }
    const line = logs.flat().join(" ");
    assert(line.includes(`status=${status}`));
    assert(line.includes("/flights/{ident}"));
    assert(!line.includes("super-secret"));
  });
}

Deno.test("fetch throws becomes provider_unavailable with a fixed message", async () => {
  const orig = console.error;
  console.error = () => {};
  try {
    const api = new AeroApi(
      "k",
      () => Promise.reject(new TypeError("dns https://aeroapi.example/x")),
    );
    const e = await assertRejects(() => api.flightsByIdent("AF84"), ApiError);
    assertEquals(e.code, "provider_unavailable");
    assertEquals(e.message, "Provider unreachable");
  } finally {
    console.error = orig;
  }
});

Deno.test("request carries an abort signal and a hung fetch times out as provider_unavailable", async () => {
  const orig = console.error;
  console.error = () => {};
  try {
    let signal: AbortSignal | null | undefined;
    const hang: typeof fetch = (_u, init) => {
      signal = init?.signal;
      return new Promise((_res, rej) => {
        init?.signal?.addEventListener("abort", () => rej(init.signal!.reason));
      });
    };
    const api = new AeroApi("k", hang, undefined, { timeoutMs: 20 });
    const e = await assertRejects(() => api.flightsByIdent("AF84"), ApiError);
    assertEquals(e.code, "provider_unavailable");
    assert(signal instanceof AbortSignal);
  } finally {
    console.error = orig;
  }
});

Deno.test("onCall is invoked once per request with the endpoint template, and a throw does not block", async () => {
  const seen: string[] = [];
  const api = new AeroApi(
    "k",
    fakeFetch(await fixture("flight_af84.json")),
    (e) => {
      seen.push(e);
      return Promise.resolve();
    },
  );
  await api.flightsByIdent("AF84");
  assertEquals(seen, ["/flights/{ident}"]);

  const orig = console.error;
  console.error = () => {};
  try {
    const failing = new AeroApi(
      "k",
      fakeFetch(await fixture("flight_af84.json")),
      () => Promise.reject(new Error("db down")),
    );
    assertEquals((await failing.flightsByIdent("AF84")).length, 1);
  } finally {
    console.error = orig;
  }
});

Deno.test("an ApiError from onCall (budget spent) stops the request before it is sent", async () => {
  let fetched = 0;
  const api = new AeroApi(
    "k",
    (() => {
      fetched++;
      return Promise.resolve(new Response("{}"));
    }) as typeof fetch,
    () =>
      Promise.reject(
        new ApiError(
          "provider_unavailable",
          503,
          "Daily provider budget reached",
        ),
      ),
  );
  const e = await assertRejects(() => api.flightPosition("X-1"), ApiError);
  assertEquals(e.code, "provider_unavailable");
  assertEquals(fetched, 0);
});

Deno.test("flightHistory asks one 7 day window, never in the future, and dedupes diversions", async () => {
  const calls: Request[] = [];
  const api = new AeroApi(
    "k",
    fakeFetch(await fixture("history_af84.json"), 200, calls),
    undefined,
    opts,
  );
  const start = new Date(NOW.getTime() - 7 * 86_400_000);
  const flights = await api.flightHistory(
    "AF84",
    start,
    new Date(NOW.getTime() + 3_600_000),
  );
  assertEquals(calls.length, 1);
  const url = new URL(calls[0].url);
  assertEquals(path(calls[0]), "/history/flights/AF84");
  assertEquals(url.searchParams.get("ident_type"), "designator");
  assertEquals(url.searchParams.get("start"), start.toISOString());
  // The provider refuses a bound in the future: a minute behind the clock.
  assertEquals(url.searchParams.get("end"), "2026-11-03T09:59:00.000Z");
  // 15 rows, the diverted flight twice: 14 flights, its diverted row kept.
  assertEquals(flights.length, 14);
  assert(flights.find((f) => f.fa_flight_id.includes("1792411800"))!.diverted);
  // An empty window costs nothing; an unknown ident is no flights.
  assertEquals(await api.flightHistory("AF84", NOW, NOW), []);
  assertEquals(calls.length, 1);
  const missing = new AeroApi("k", fakeFetch("{}", 404), undefined, opts);
  assertEquals(await missing.flightHistory("ZZ1", start, NOW), []);
});

Deno.test("estimateCost covers every endpoint the client uses and throws on unknown", async () => {
  const used = new Set<string>();
  const record = (e: string) => {
    used.add(e);
    return Promise.resolve();
  };
  const ok = (body: string, headers: HeadersInit = {}) =>
    routed(() => new Response(body, { status: 200, headers }));
  const f = await fixture("flight_af84.json");
  const nowOpts = { now: () => NOW };
  await new AeroApi("k", ok(f), record).flightsByIdent("AF84");
  await new AeroApi("k", ok(await fixture("position_af84.json")), record)
    .flightPosition("x");
  await new AeroApi(
    "k",
    ok(await fixture("route_kaus_kdfw.json")),
    record,
    nowOpts,
  )
    .searchRoute("KAUS", "KDFW", "2026-11-03");
  for (
    const k of [
      "departures",
      "arrivals",
      "scheduled_departures",
      "scheduled_arrivals",
    ] as const
  ) {
    await new AeroApi("k", ok("{}"), record).airportFlights("KAUS", k);
  }
  await new AeroApi("k", ok("{}", { location: "/alerts/1" }), record)
    .createAlert("AFR84", "2026-11-03", "2026-11-03");
  await new AeroApi("k", ok(""), record).deleteAlert(1);
  await new AeroApi(
    "k",
    ok(await fixture("history_af84.json")),
    record,
    nowOpts,
  ).flightHistory("AF84", new Date(NOW.getTime() - 7 * 86_400_000), NOW);
  await new AeroApi("k", ok(await fixture("schedules_ksfo_kord.json")), record)
    .schedules("KSFO", "KORD", NOW, new Date(NOW.getTime() + 86_400_000));
  await new AeroApi("k", ok('{"flights":[]}'), record).searchArea({
    south: 37,
    west: -123,
    north: 38,
    east: -121,
  });
  assertEquals(
    used.size,
    Object.keys(ENDPOINT_COST).length - 0,
    "every priced endpoint is used and vice versa",
  );
  for (const e of used) assert(estimateCost(e) >= 0);
  assertEquals(estimateCost("/flights/{ident}"), 0.005);
  assertEquals(estimateCost("/flights/{id}/position"), 0.01);
  assertEquals(
    estimateCost("/airports/{id}/flights/scheduled_departures"),
    0.005,
  );
  assertEquals(estimateCost("/alerts"), 0);
  assertEquals(estimateCost("/flights/search"), 0.05);
  assertThrows(() => estimateCost("/nope"));
});

Deno.test("sends x-apikey header", async () => {
  const calls: Request[] = [];
  const api = new AeroApi(
    "secret-key",
    fakeFetch(await fixture("flight_af84.json"), 200, calls),
  );
  await api.flightsByIdent("AF84");
  assertEquals(calls[0].headers.get("x-apikey"), "secret-key");
  assert(
    calls[0].url.startsWith(
      "https://aeroapi.flightaware.com/aeroapi/flights/AF84",
    ),
  );
});

Deno.test("createAlert posts the documented body and reads the id from Location", async () => {
  const calls: Request[] = [];
  const api = new AeroApi(
    "k",
    routed(
      () =>
        new Response(null, {
          status: 201,
          headers: { location: "/alerts/8841" },
        }),
      calls,
    ),
  );
  assertEquals(
    await api.createAlert("AFR84", "2026-11-03", "2026-11-03"),
    8841,
  );
  assertEquals(calls[0].method, "POST");
  assertEquals(path(calls[0]), "/alerts");
  const body = await calls[0].json();
  assertEquals(body.ident, "AFR84");
  assertEquals(body.start, "2026-11-03");
  assertEquals(body.end, "2026-11-03");
  assertEquals(Object.keys(body.events).sort(), [
    "arrival",
    "cancelled",
    "departure",
    "diverted",
    "filed",
    "in",
    "off",
    "on",
    "out",
  ]);
  assert(Object.values(body.events).every((v) => v === true));
  // fallback to body.id
  const viaBody = new AeroApi("k", fakeFetch('{"id": 77}', 201));
  assertEquals(
    await viaBody.createAlert("AFR84", "2026-11-03", "2026-11-03"),
    77,
  );
  // no id anywhere
  await assertRejects(
    () => new AeroApi("k", fakeFetch("", 201)).createAlert("a", "b", "c"),
    ApiError,
  );
});

Deno.test("deleteAlert sends DELETE to /alerts/{id}, tolerates 404", async () => {
  const calls: Request[] = [];
  await new AeroApi(
    "k",
    routed(() => new Response(null, { status: 204 }), calls),
  ).deleteAlert(8841);
  assertEquals(calls[0].method, "DELETE");
  assertEquals(path(calls[0]), "/alerts/8841");
  await new AeroApi("k", fakeFetch(null, 404)).deleteAlert(8841);
});

Deno.test("statusOf branches through toFlightRow", async () => {
  const base = (await flightsOf("flight_af84.json", "flights"))[0];
  const blank: AeroFlight = {
    ...base,
    actual_out: null,
    actual_off: null,
    actual_on: null,
    actual_in: null,
    cancelled: false,
    diverted: false,
    status: "Scheduled",
  };
  const st = (o: Partial<AeroFlight>) =>
    toFlightRow({ ...blank, ...o }, NOW).status;
  assertEquals(st({}), "scheduled");
  assertEquals(st({ actual_out: "2026-11-03T12:20:00Z" }), "departed");
  assertEquals(st({ actual_off: "2026-11-03T12:38:00Z" }), "en_route");
  assertEquals(st({ actual_on: "2026-11-03T22:55:00Z" }), "landed");
  assertEquals(st({ actual_in: "2026-11-03T23:05:00Z" }), "arrived");
  assertEquals(st({ cancelled: true }), "canceled");
  assertEquals(st({ diverted: true }), "diverted");
  assertEquals(st({ status: "Something new" }), "unknown");
  assertEquals(st({ status: "Landed / Taxiing" }), "landed");
});

Deno.test("toFlightRow tolerates null airports and missing keys with nulls, not undefined", () => {
  const sparse = {
    fa_flight_id: "X-1",
    ident: "XYZ1",
    origin: null,
    destination: null,
    status: "",
    cancelled: false,
    diverted: false,
  } as unknown as AeroFlight;
  const row = toFlightRow(sparse, NOW);
  assertEquals(row.origin_icao, null);
  assertEquals(row.destination_iata, null);
  assertEquals(row.ident, "XYZ1");
  for (const [k, v] of Object.entries(row)) {
    assert(v !== undefined, `${k} is undefined`);
  }
  assertEquals(row.status, "unknown");
});

Deno.test("diverted flights collapse to one row per provider_id", async () => {
  const base = (await flightsOf("flight_af84.json", "flights"))[0];
  const planned: AeroFlight = { ...base, diverted: false };
  const diverted: AeroFlight = {
    ...base,
    diverted: true,
    destination: { ...base.destination!, code_icao: "KSMF" },
  };
  for (const order of [[planned, diverted], [diverted, planned]]) {
    const rows = toFlightRows(order, NOW);
    assertEquals(rows.length, 1);
    assertEquals(rows[0].status, "diverted");
    assertEquals(rows[0].destination_icao, "KSMF");
  }
  const other = { ...base, fa_flight_id: "other" };
  assertEquals(dedupeByFaFlightId([planned, other, planned]).length, 2);
});

Deno.test("errorResponse shapes", async () => {
  const r = errorResponse(new ApiError("plan_limit", 402, "Free plan"));
  assertEquals(r.status, 402);
  assertEquals((await r.json()).error.code, "plan_limit");
  const orig = console.error;
  console.error = () => {};
  try {
    const u = errorResponse(new Error("x"));
    assertEquals(u.status, 500);
    assertEquals((await u.json()).error.code, "provider_unavailable");
  } finally {
    console.error = orig;
  }
});

Deno.test("requireUser: missing, malformed, error, valid", async () => {
  const mk = (
    res: { data: { user: { id: string } | null }; error: unknown },
  ) => ({
    auth: { getUser: (_jwt: string) => Promise.resolve(res) },
  });
  const req = (h?: string) =>
    new Request("https://x", h ? { headers: { authorization: h } } : {});
  const good = mk({ data: { user: { id: "u-1" } }, error: null });
  for (const bad of [undefined, "Basic abc", "Bearer", "Bearer "]) {
    const e = await assertRejects(() => requireUser(req(bad), good), ApiError);
    assertEquals(e.code, "unauthorized");
    assertEquals(e.status, 401);
  }
  const err = await assertRejects(
    () =>
      requireUser(
        req("Bearer t"),
        mk({ data: { user: null }, error: new Error("bad jwt") }),
      ),
    ApiError,
  );
  assertEquals(err.code, "unauthorized");
  await assertRejects(
    () =>
      requireUser(req("Bearer t"), mk({ data: { user: null }, error: null })),
    ApiError,
  );
  let seen = "";
  const spy = {
    auth: {
      getUser: (
        jwt: string,
      ) => (seen = jwt,
        Promise.resolve({ data: { user: { id: "u-9" } }, error: null })),
    },
  };
  assertEquals(await requireUser(req("bearer tok.en"), spy), { userId: "u-9" });
  assertEquals(seen, "tok.en");
});

Deno.test("searchRoute follows links.next up to maxPages and meters each page", async () => {
  const route = JSON.parse(await fixture("route_kaus_kdfw.json"));
  const first = {
    ...route,
    flights: [route.flights[0]],
    links: { next: "/airports/KAUS/flights/to/KDFW?cursor=c2" },
  };
  const second = {
    ...route,
    flights: [route.flights[1]],
    links: { next: "/airports/KAUS/flights/to/KDFW?cursor=c3" },
  };
  const third = { ...route, flights: [route.flights[2]], links: null };
  const calls: Request[] = [];
  const seen: string[] = [];
  const api = new AeroApi(
    "k",
    routed((r) => {
      const c = new URL(r.url).searchParams.get("cursor");
      return new Response(
        JSON.stringify(c === "c2" ? second : c === "c3" ? third : first),
      );
    }, calls),
    (e) => {
      seen.push(e);
      return Promise.resolve();
    },
    opts,
  );
  const two = await api.searchRoute("KAUS", "KDFW", "2026-11-03");
  assertEquals(two.map((f) => f.ident_iata), ["AA2417", "AA2431"]);
  assertEquals(calls.length, 2); // default cap is 2 pages
  assertEquals(seen, [
    "/airports/{id}/flights/to/{dest_id}",
    "/airports/{id}/flights/to/{dest_id}",
  ]);
  const u = new URL(calls[1].url);
  assertEquals(u.searchParams.get("cursor"), "c2");
  assertEquals(u.searchParams.get("connection"), "nonstop"); // filters kept on later pages
  assertEquals(u.searchParams.get("start"), "2026-11-03T00:00:00.000Z");
  calls.length = 0;
  assertEquals(
    (await api.searchRoute("KAUS", "KDFW", "2026-11-03", 1)).length,
    1,
  );
  assertEquals(calls.length, 1);
});

Deno.test("flightsByIdent sends ident_type=designator", async () => {
  const calls: Request[] = [];
  await new AeroApi("k", fakeFetch('{"flights":[]}', 200, calls))
    .flightsByIdent("AFR84");
  assertEquals(
    new URL(calls[0].url).searchParams.get("ident_type"),
    "designator",
  );
});

Deno.test("flightById picks the diverted row of a diverted flight", async () => {
  const base = (await flightsOf("flight_af84.json", "flights"))[0];
  const planned = { ...base, diverted: false };
  const diverted = { ...base, diverted: true };
  for (const rows of [[planned, diverted], [diverted, planned]]) {
    const api = new AeroApi("k", fakeFetch(JSON.stringify({ flights: rows })));
    assertEquals((await api.flightById(base.fa_flight_id))?.diverted, true);
  }
});

Deno.test("boardFlights starts both list fetches before either finishes", async () => {
  let inFlight = 0;
  let peak = 0;
  const api = new AeroApi(
    "k",
    routed(async () => {
      inFlight++;
      peak = Math.max(peak, inFlight);
      await new Promise((r) => setTimeout(r, 10));
      inFlight--;
      return new Response("{}");
    }),
  );
  await api.boardFlights("KAUS", "departures");
  assertEquals(peak, 2);
});

Deno.test("fixtures agree on fa_flight_id for the same flight", async () => {
  const sched = await flightsOf(
    "scheduled_departures_kaus.json",
    "scheduled_departures",
  );
  const route = JSON.parse(await fixture("route_kaus_kdfw.json")).flights;
  const a = sched.find((f) => f.ident_iata === "AA2417")!;
  const b = route[0].segments[0];
  assertEquals(b.ident_iata, "AA2417");
  assertEquals(a.fa_flight_id, b.fa_flight_id);
});

Deno.test("schedules reads one route's operating flights in the window, each once", async () => {
  const calls: Request[] = [];
  const api = new AeroApi(
    "k",
    routed(
      async () => new Response(await fixture("schedules_ksfo_kord.json")),
      calls,
    ),
  );
  const start = new Date("2026-11-03T15:00:00Z");
  const end = new Date("2026-11-04T15:00:00Z");
  const rows = await api.schedules("KSFO", "KORD", start, end);
  assertEquals(calls.length, 1);
  const url = new URL(calls[0].url);
  assertEquals(
    decodeURIComponent(path(calls[0])),
    "/schedules/2026-11-03T15:00:00.000Z/2026-11-04T15:00:00.000Z",
  );
  assertEquals(url.searchParams.get("origin"), "KSFO");
  assertEquals(url.searchParams.get("destination"), "KORD");
  assertEquals(url.searchParams.get("include_codeshares"), "false");
  // The repeated UA 2306 counts once; UA 640 leaves the next day, after the window.
  assertEquals(rows.map((r) => r.ident_iata), [
    "UA2306",
    "AA1781",
    "UA1958",
    "AS1314",
  ]);
});

Deno.test("schedules: an empty window costs nothing, an unknown route is empty", async () => {
  const calls: Request[] = [];
  const api = new AeroApi(
    "k",
    routed(() => new Response("{}", { status: 404 }), calls),
  );
  const t = new Date("2026-11-03T15:00:00Z");
  assertEquals(await api.schedules("KSFO", "KORD", t, t), []);
  assertEquals(calls.length, 0);
  assertEquals(
    await api.schedules("KSFO", "KZZZ", t, new Date(t.getTime() + 3_600_000)),
    [],
  );
  assertEquals(calls.length, 1);
});

Deno.test("schedules: origin and destination are optional, airline and flight number filter", async () => {
  const calls: Request[] = [];
  const api = new AeroApi(
    "k",
    routed(
      async () => new Response(await fixture("schedules_ksfo_kord.json")),
      calls,
    ),
  );
  const start = new Date("2026-11-03T00:00:00Z");
  await api.schedules(
    undefined,
    undefined,
    start,
    new Date(start.getTime() + 86_400_000),
    3,
    { airline: "UA", flightNumber: "1958" },
  );
  const q = new URL(calls[0].url).searchParams;
  assertEquals(q.get("origin"), null);
  assertEquals(q.get("destination"), null);
  assertEquals(q.get("airline"), "UA");
  assertEquals(q.get("flight_number"), "1958");
  assertEquals(q.get("include_codeshares"), "false");
});

Deno.test("scheduleWindow says when pages were left over", async () => {
  const body = JSON.parse(await fixture("schedules_ksfo_kord.json"));
  const start = new Date("2026-11-03T15:00:00Z");
  const end = new Date("2026-11-04T15:00:00Z");
  // Every page points at another: the third is the last read, and the answer says more were left.
  const calls: Request[] = [];
  const endless = new AeroApi(
    "k",
    routed(
      () =>
        new Response(JSON.stringify({
          ...body,
          links: { next: "/schedules/x/y?cursor=more" },
        })),
      calls,
    ),
  );
  const cut = await endless.scheduleWindow("KSFO", undefined, start, end, 3);
  assertEquals(calls.length, 3);
  assertEquals(cut.truncated, true);
  assertEquals(cut.flights.map((r) => r.ident_iata), [
    "UA2306",
    "AA1781",
    "UA1958",
    "AS1314",
  ]);
  // One page with no next link: all of it.
  const whole = await new AeroApi(
    "k",
    routed(() => new Response(JSON.stringify({ ...body, links: null }))),
  ).scheduleWindow("KSFO", undefined, start, end, 3);
  assertEquals(whole.truncated, false);
  // An empty window: nothing asked, nothing left.
  assertEquals(
    await endless.scheduleWindow("KSFO", undefined, start, start, 3),
    { flights: [], truncated: false },
  );
});
