import { assert, assertEquals } from "jsr:@std/assert@1";
import type { AeroFlight } from "../_shared/aeroapi_types.ts";
import { AeroApi, ENDPOINT_COST } from "../_shared/aeroapi.ts";
import { ApiError } from "../_shared/errors.ts";
import { usageCounter } from "../_shared/limits.ts";
import {
  fakeVerifier,
  makeUser,
  test as baseTest,
  testDb,
} from "../_shared/test_util.ts";
import { handler } from "./handler.ts";

const NOW = new Date("2026-11-03T15:00:00Z");
const minAgo = (m: number) =>
  new Date(NOW.getTime() - m * 60_000).toISOString();
const fixture = (name: string) =>
  JSON.parse(
    Deno.readTextFileSync(
      new URL(`../_shared/fixtures/${name}`, import.meta.url),
    ),
  );
const board: AeroFlight[] = [
  ...fixture("departures_kaus.json").departures,
  ...fixture("scheduled_departures_kaus.json").scheduled_departures,
];

const db = await testDb();

async function clearKaus() {
  for (const t of ["airport_snapshots", "airport_refresh_leases"]) {
    const r = await db.from(t).delete().eq("icao", "KAUS");
    if (r.error) throw r.error;
  }
}

/** Every test starts and ends with no KAUS snapshots or leases, so rls_test.sql stays green. */
function test(name: string, fn: () => Promise<void>) {
  baseTest(db, name, async () => {
    await clearKaus();
    try {
      await fn();
    } finally {
      await clearKaus();
    }
  });
}

function fakeAero(
  opts: {
    fail?: boolean | Error;
    delayMs?: number;
    flights?: AeroFlight[];
  } = {},
) {
  const calls: unknown[][] = [];
  return {
    calls,
    async boardFlights(...a: unknown[]) {
      calls.push(a);
      if (opts.delayMs) await new Promise((r) => setTimeout(r, opts.delayMs));
      if (opts.fail instanceof Error) throw opts.fail;
      if (opts.fail) throw new ApiError("provider_unavailable", 503);
      return opts.flights ?? board;
    },
  };
}

function get(user: string, query: string) {
  return new Request(`http://local/airport-board?${query}`, {
    headers: { authorization: `Bearer ${user}` },
  });
}

function deps(aero = fakeAero(), extra: Record<string, unknown> = {}) {
  return { db, aero, verifier: fakeVerifier, now: () => NOW, ...extra };
}

async function seed(
  kind: string,
  fetchedAt: string,
  payload: unknown = { flights: [] },
) {
  const r = await db.from("airport_snapshots").insert({
    icao: "KAUS",
    kind,
    payload,
    fetched_at: fetchedAt,
  });
  if (r.error) throw r.error;
}

async function snapshot(kind: string) {
  const r = await db.from("airport_snapshots").select("*").eq("icao", "KAUS")
    .eq("kind", kind).maybeSingle();
  if (r.error) throw r.error;
  return r.data;
}

test("board accepts IATA: AUS resolves to KAUS", async () => {
  const user = await makeUser(db);
  const aero = fakeAero();
  const res = await handler(
    get(user, "airport=AUS&kind=departures"),
    deps(aero),
  );
  assertEquals(res.status, 200);
  const body = await res.json();
  assertEquals(body.icao, "KAUS");
  assertEquals(body.kind, "departures");
  assertEquals(body.stale, false);
  assertEquals(body.fetched_at, NOW.toISOString());
  assertEquals(body.flights.length, 4);
  assertEquals(aero.calls, [["KAUS", "departures"]]);
  const row = await snapshot("departures");
  assertEquals(row.payload.flights.length, 4);
  assertEquals(row.last_viewed_at !== null, true);
  const lease = await db.from("airport_refresh_leases").select("*").eq(
    "icao",
    "KAUS",
  );
  assertEquals(lease.data, []);
});

test("fresh snapshot is served without a provider call and updates last_viewed_at", async () => {
  const user = await makeUser(db);
  await seed("departures", minAgo(1), { flights: [{ ident: "XX1" }] });
  const aero = fakeAero();
  const res = await handler(
    get(user, "airport=KAUS&kind=departures"),
    deps(aero),
  );
  const body = await res.json();
  assertEquals(aero.calls.length, 0);
  assertEquals(body.stale, false);
  assertEquals(body.fetched_at, minAgo(1));
  assertEquals(body.flights, [{ ident: "XX1" }]);
  assertEquals((await snapshot("departures")).last_viewed_at !== null, true);
});

test("old snapshot triggers a refresh", async () => {
  const user = await makeUser(db);
  await seed("departures", minAgo(10));
  const aero = fakeAero();
  const body = await (await handler(
    get(user, "airport=KAUS&kind=departures"),
    deps(aero),
  )).json();
  assertEquals(aero.calls.length, 1);
  assertEquals(body.stale, false);
  assertEquals(body.fetched_at, NOW.toISOString());
  assertEquals(body.flights.length, 4);
});

test("provider 503 with an old snapshot returns it stale with the original fetchedAt", async () => {
  const user = await makeUser(db);
  await seed("arrivals", minAgo(30), { flights: [{ ident: "OLD1" }] });
  const res = await handler(
    get(user, "airport=KAUS&kind=arrivals"),
    deps(fakeAero({ fail: true })),
  );
  assertEquals(res.status, 200);
  const body = await res.json();
  assertEquals(body.stale, true);
  assertEquals(body.fetched_at, minAgo(30));
  assertEquals(body.flights, [{ ident: "OLD1" }]);
});

test("provider 503 with no snapshot returns 503 provider_unavailable", async () => {
  const user = await makeUser(db);
  const res = await handler(
    get(user, "airport=KAUS&kind=departures"),
    deps(fakeAero({ fail: true })),
  );
  assertEquals(res.status, 503);
  assertEquals((await res.json()).error.code, "provider_unavailable");
  const lease = await db.from("airport_refresh_leases").select("*").eq(
    "icao",
    "KAUS",
  );
  assertEquals(lease.data, []);
});

test("concurrent readers of a stale board cause one provider refresh", async () => {
  const user = await makeUser(db);
  await seed("departures", minAgo(10), { flights: [{ ident: "OLD1" }] });
  const aero = fakeAero({ delayMs: 400 });
  const results = await Promise.all(
    Array.from(
      { length: 6 },
      () =>
        handler(get(user, "airport=KAUS&kind=departures"), deps(aero))
          .then((r) => r.json()),
    ),
  );
  assertEquals(aero.calls.length, 1);
  assertEquals(results.filter((r) => !r.stale).length, 1);
  assertEquals(results.filter((r) => r.stale).length, 5);
  assert(results.every((r) => r.flights.length >= 1));
});

test("first-ever load while another request refreshes waits for its snapshot", async () => {
  const user = await makeUser(db);
  const claimed = await db.rpc("claim_airport_refresh", {
    p_icao: "KAUS",
    p_kind: "departures",
    p_lease_seconds: 20,
  });
  assertEquals(claimed.data, true);
  const aero = fakeAero();
  let polls = 0;
  const sleep = async () => {
    if (++polls === 2) {
      await seed("departures", minAgo(0), { flights: [{ ident: "NEW1" }] });
    }
  };
  const body = await (await handler(
    get(user, "airport=KAUS&kind=departures"),
    deps(aero, { sleep }),
  )).json();
  assertEquals(aero.calls.length, 0);
  assertEquals(body.stale, false);
  assertEquals(body.flights, [{ ident: "NEW1" }]);
});

test("first-ever load with a lease held and nothing arriving is 503", async () => {
  const user = await makeUser(db);
  await db.rpc("claim_airport_refresh", {
    p_icao: "KAUS",
    p_kind: "departures",
    p_lease_seconds: 20,
  });
  const res = await handler(
    get(user, "airport=KAUS&kind=departures"),
    deps(fakeAero(), { sleep: () => Promise.resolve(), waitMs: 1200 }),
  );
  assertEquals(res.status, 503);
  assertEquals((await res.json()).error.code, "provider_unavailable");
});

test("an expired lease can be claimed again", async () => {
  const user = await makeUser(db);
  const r = await db.from("airport_refresh_leases").insert({
    icao: "KAUS",
    kind: "departures",
    until: new Date(Date.now() - 60_000).toISOString(),
  });
  assertEquals(r.error, null);
  const aero = fakeAero();
  const res = await handler(
    get(user, "airport=KAUS&kind=departures"),
    deps(aero),
  );
  assertEquals(res.status, 200);
  assertEquals(aero.calls.length, 1);
});

test("stats are computed from the departures and arrivals snapshots", async () => {
  const user = await makeUser(db);
  const aero = fakeAero();
  const res = await handler(get(user, "airport=KAUS&kind=stats"), deps(aero));
  assertEquals(res.status, 200);
  const body = await res.json();
  assertEquals(aero.calls.length, 2);
  assertEquals(body.kind, "stats");
  assertEquals(body.stale, false);
  // NOW is 15:00: the 15:05 and 15:20 departures have not left and do not count.
  assertEquals(body.departures.total, 2);
  assertEquals(body.departures.canceled, 1);
  assertEquals(body.departures.severity, "major"); // 1 of 2 counted is canceled
  assertEquals(typeof body.arrivals.total, "number");
  assertEquals("severity" in body, false);
  assert(await snapshot("departures"));
  assert(await snapshot("arrivals"));
  // A second read inside the TTL needs no provider call.
  const again = await handler(get(user, "airport=KAUS&kind=stats"), deps(aero));
  assertEquals((await again.json()).departures.total, 2);
  assertEquals(aero.calls.length, 2);
});

test("stats with a stale board are flagged stale and use the board's age", async () => {
  const user = await makeUser(db);
  await seed("departures", minAgo(20), { flights: [] });
  await seed("arrivals", minAgo(20), { flights: [] });
  const body = await (await handler(
    get(user, "airport=KAUS&kind=stats"),
    deps(fakeAero({ fail: true })),
  )).json();
  assertEquals(body.stale, true);
  assertEquals(body.fetched_at, minAgo(20));
  assertEquals(body.departures.total, 0);
  assertEquals(body.departures.severity, "normal");
});

const metar = fixture("metar_kaus.json");
const taf = fixture("taf_kaus.json");
function weatherFetch(calls: string[]): typeof fetch {
  return ((input: string | URL | Request) => {
    const url = String(input);
    calls.push(url);
    return Promise.resolve(
      new Response(JSON.stringify(url.includes("/metar?") ? metar : taf)),
    );
  }) as typeof fetch;
}

test("weather is fetched, stored and served for 15 minutes", async () => {
  const user = await makeUser(db);
  const calls: string[] = [];
  const d = deps(fakeAero(), { fetchFn: weatherFetch(calls) });
  const body = await (await handler(get(user, "airport=AUS&kind=weather"), d))
    .json();
  assertEquals(body.icao, "KAUS");
  assertEquals(body.stale, false);
  assertEquals(body.weather.category, "IFR");
  assertEquals(body.weather.ceilingFt, 900);
  assertEquals(body.weather.forecast.length, 5);
  assertEquals(calls.length, 2);

  // 14 minutes later: still fresh, no new fetch.
  const later = deps(fakeAero(), {
    fetchFn: weatherFetch(calls),
    now: () => new Date(NOW.getTime() + 14 * 60_000),
  });
  await handler(get(user, "airport=AUS&kind=weather"), later);
  assertEquals(calls.length, 2);

  // 16 minutes later: refetched.
  const stale = deps(fakeAero(), {
    fetchFn: weatherFetch(calls),
    now: () => new Date(NOW.getTime() + 16 * 60_000),
  });
  await handler(get(user, "airport=AUS&kind=weather"), stale);
  assertEquals(calls.length, 4);
});

test("weather: a board-stale snapshot at 10 minutes is still fresh for weather", async () => {
  const user = await makeUser(db);
  await seed("weather", minAgo(10), { weather: { category: "VFR" } });
  const calls: string[] = [];
  const body = await (await handler(
    get(user, "airport=KAUS&kind=weather"),
    deps(fakeAero(), { fetchFn: weatherFetch(calls) }),
  )).json();
  assertEquals(calls.length, 0);
  assertEquals(body.stale, false);
});

test("rejects missing tokens, bad kinds, bad airports and wrong methods", async () => {
  const user = await makeUser(db);
  const d = deps();
  const anon = await handler(
    new Request("http://local/airport-board?airport=AUS&kind=stats"),
    d,
  );
  assertEquals(anon.status, 401);
  const kind = await handler(get(user, "airport=AUS&kind=gates"), d);
  assertEquals(kind.status, 400);
  const unknown = await handler(get(user, "airport=QQQQ&kind=stats"), d);
  assertEquals(unknown.status, 400);
  const missing = await handler(get(user, "kind=stats"), d);
  assertEquals(missing.status, 400);
  const post = await handler(
    new Request("http://local/airport-board?airport=AUS&kind=stats", {
      method: "POST",
      headers: { authorization: `Bearer ${user}` },
    }),
    d,
  );
  assertEquals(post.status, 405);
});

test("120 calls an hour, the 121st is rate_limited", async () => {
  const user = await makeUser(db);
  await seed("departures", minAgo(1));
  const rows = Array.from({ length: 120 }, () => ({
    user_id: user,
    endpoint: "airport-board",
  }));
  const ins = await db.from("rate_events").insert(rows);
  assertEquals(ins.error, null);
  const aero = fakeAero();
  const res = await handler(
    get(user, "airport=KAUS&kind=departures"),
    deps(aero),
  );
  assertEquals(res.status, 429);
  assertEquals((await res.json()).error.code, "rate_limited");
  assertEquals(aero.calls.length, 0);
});

// --- Review round 1 ---

test("board rows decode as the app's Flight: id, no null airports, ISO dates", async () => {
  const user = await makeUser(db);
  const body = await (await handler(
    get(user, "airport=KAUS&kind=departures"),
    deps(),
  )).json();
  for (const f of body.flights) {
    assertEquals(
      /^[0-9a-f]{8}-[0-9a-f]{4}-5[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/
        .test(f.id),
      true,
    );
    assertEquals(typeof f.origin_icao, "string");
    assertEquals(typeof f.destination_icao, "string");
    assertEquals(typeof f.updated_at, "string");
    assertEquals(f.status.length > 0, true);
  }
  const ids = body.flights.map((f: { id: string }) => f.id);
  assertEquals(new Set(ids).size, ids.length);
  // The id is stable across refreshes.
  await clearKaus();
  const again = await (await handler(
    get(user, "airport=KAUS&kind=departures"),
    deps(),
  )).json();
  assertEquals(again.flights.map((f: { id: string }) => f.id), ids);
});

test("null airports: the viewed side is filled, the other side drops the row", async () => {
  const user = await makeUser(db);
  const [a, b, c] = structuredClone([board[0], board[1], board[3]]);
  a.origin = null; // departures: the viewed airport
  b.destination = null; // departures: unknown, dropped
  const body = await (await handler(
    get(user, "airport=KAUS&kind=departures"),
    deps(fakeAero({ flights: [a, b, c] })),
  )).json();
  assertEquals(body.flights.length, 2);
  assertEquals(body.flights[0].origin_icao, "KAUS");
  assertEquals(
    body.flights.some((f: { provider_id: string }) =>
      f.provider_id === b.fa_flight_id
    ),
    false,
  );
});

test("a failed METAR keeps the old weather snapshot and marks it stale", async () => {
  const user = await makeUser(db);
  await seed("weather", minAgo(30), { weather: { metarRaw: "OLD" } });
  const failing = ((input: string | URL | Request) =>
    Promise.resolve(
      String(input).includes("/metar?")
        ? new Response("down", { status: 503 })
        : new Response(JSON.stringify(taf)),
    )) as typeof fetch;
  const body = await (await handler(
    get(user, "airport=KAUS&kind=weather"),
    deps(fakeAero(), { fetchFn: failing }),
  )).json();
  assertEquals(body.stale, true);
  assertEquals(body.fetched_at, minAgo(30));
  assertEquals(body.weather.metarRaw, "OLD");
  assertEquals((await snapshot("weather")).payload.weather.metarRaw, "OLD");
});

test("an airport with no usable METAR is 404 and nothing is cached", async () => {
  const user = await makeUser(db);
  const empty = (() => Promise.resolve(new Response("[]"))) as typeof fetch;
  const res = await handler(
    get(user, "airport=KAUS&kind=weather"),
    deps(fakeAero(), { fetchFn: empty }),
  );
  assertEquals(res.status, 404);
  assertEquals(await snapshot("weather"), null);
});

test("a failing lease release does not turn a good read into a 500", async () => {
  const user = await makeUser(db);
  const flaky = new Proxy(db, {
    get(target, prop) {
      if (prop === "rpc") {
        return (fn: string, args: unknown) =>
          fn === "release_airport_refresh"
            ? Promise.resolve({ error: { message: "boom" } })
            : target.rpc(fn, args as Record<string, unknown>);
      }
      const v = Reflect.get(target, prop);
      return typeof v === "function" ? v.bind(target) : v;
    },
  });
  const res = await handler(
    get(user, "airport=KAUS&kind=departures"),
    { ...deps(), db: flaky },
  );
  assertEquals(res.status, 200);
  assertEquals((await res.json()).stale, false);
  // And in the failed-refresh path the provider answer stays a 503, not a 500.
  await clearKaus();
  const res2 = await handler(
    get(user, "airport=KAUS&kind=arrivals"),
    { ...deps(fakeAero({ fail: true })), db: flaky },
  );
  assertEquals(res2.status, 503);
});

test("an internal error is a 500, never served as a stale snapshot", async () => {
  const user = await makeUser(db);
  await seed("departures", minAgo(10), { flights: [{ ident: "OLD1" }] });
  const res = await handler(
    get(user, "airport=KAUS&kind=departures"),
    deps(fakeAero({ fail: new TypeError("bug") })),
  );
  assertEquals(res.status, 500);
  // The lease was released, so the next request can refresh.
  const lease = await db.from("airport_refresh_leases").select("*").eq(
    "icao",
    "KAUS",
  );
  assertEquals(lease.data, []);
});

test("a refresh that outlives its deadline falls back to the stale snapshot", async () => {
  const user = await makeUser(db);
  await seed("departures", minAgo(10), { flights: [{ ident: "OLD1" }] });
  const body = await (await handler(
    get(user, "airport=KAUS&kind=departures"),
    deps(fakeAero({ delayMs: 400 }), { refreshDeadlineMs: 50 }),
  )).json();
  assertEquals(body.stale, true);
  assertEquals(body.flights, [{ ident: "OLD1" }]);
});

test("every AeroAPI page goes through increment_usage with its price", async () => {
  const user = await makeUser(db);
  const day = new Date().toISOString().slice(0, 10);
  const read = async () => {
    const r = await db.from("usage_counters").select("*").eq("day", day)
      .like("endpoint", "/airports/%");
    if (r.error) throw r.error;
    return new Map(
      r.data!.map((x) => [x.endpoint as string, x] as const),
    );
  };
  const before = await read();
  const paths: string[] = [];
  const fetchFn = ((input: string | URL | Request) => {
    const url = new URL(String(input));
    paths.push(url.pathname);
    const key = url.pathname.endsWith("/departures")
      ? "departures"
      : "scheduled_departures";
    return Promise.resolve(
      new Response(JSON.stringify({ [key]: [], links: null })),
    );
  }) as typeof fetch;
  const aero = new AeroApi("k", fetchFn, usageCounter(db));
  try {
    const res = await handler(
      get(user, "airport=KAUS&kind=departures"),
      deps(aero as never),
    );
    assertEquals(res.status, 200);
    assertEquals(paths.length, 2);
    const after = await read();
    for (const ep of ["departures", "scheduled_departures"]) {
      const key = `/airports/{id}/flights/${ep}`;
      assertEquals(
        (after.get(key)?.calls ?? 0) - (before.get(key)?.calls ?? 0),
        1,
      );
      assertEquals(
        Number(after.get(key)?.estimated_cost ?? 0) -
          Number(before.get(key)?.estimated_cost ?? 0),
        ENDPOINT_COST[key],
      );
    }
  } finally {
    // Put the counters back so the test leaves no trace.
    for (const [endpoint, row] of await read()) {
      const prev = before.get(endpoint);
      if (prev) {
        await db.from("usage_counters").update({
          calls: prev.calls,
          estimated_cost: prev.estimated_cost,
        }).eq("day", day).eq("endpoint", endpoint);
      } else {
        await db.from("usage_counters").delete().eq("day", day).eq(
          "endpoint",
          row.endpoint,
        );
      }
    }
  }
});

// --- Contract files: what App Task 9 decodes in Swift ---

const CONTRACT_NOW = new Date("2026-11-03T16:00:00Z");
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

test("contract examples match the handler's answers", async () => {
  const user = await makeUser(db);
  // Arrivals board: the same flights, seen from the other end.
  const arrivals = board.map((f) => ({
    ...f,
    origin: f.destination,
    destination: f.origin,
  }));
  const aero = {
    boardFlights(_icao: string, kind: "departures" | "arrivals") {
      return Promise.resolve(kind === "departures" ? board : arrivals);
    },
  };
  const d = deps(aero as never, { now: () => CONTRACT_NOW });
  const ask = async (kind: string, extra: Record<string, unknown> = {}) =>
    await (await handler(get(user, `airport=AUS&kind=${kind}`), {
      ...d,
      ...extra,
    })).json();
  await checkContract("departures", await ask("departures"));
  await checkContract("arrivals", await ask("arrivals"));
  await checkContract("stats", await ask("stats"));
  await checkContract(
    "weather",
    await ask("weather", { fetchFn: weatherFetch([]) }),
  );
});
