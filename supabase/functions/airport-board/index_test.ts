import { assert, assertEquals } from "jsr:@std/assert@1";
import type { AeroFlight } from "../_shared/aeroapi_types.ts";
import { ApiError } from "../_shared/errors.ts";
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

function fakeAero(opts: { fail?: boolean; delayMs?: number } = {}) {
  const calls: unknown[][] = [];
  return {
    calls,
    async boardFlights(...a: unknown[]) {
      calls.push(a);
      if (opts.delayMs) await new Promise((r) => setTimeout(r, opts.delayMs));
      if (opts.fail) throw new ApiError("provider_unavailable", 503);
      return board;
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
  assertEquals(body.fetchedAt, NOW.toISOString());
  assertEquals(body.payload.flights.length, 4);
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
  assertEquals(body.fetchedAt, minAgo(1));
  assertEquals(body.payload.flights, [{ ident: "XX1" }]);
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
  assertEquals(body.fetchedAt, NOW.toISOString());
  assertEquals(body.payload.flights.length, 4);
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
  assertEquals(body.fetchedAt, minAgo(30));
  assertEquals(body.payload.flights, [{ ident: "OLD1" }]);
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
  assert(results.every((r) => r.payload.flights.length >= 1));
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
  assertEquals(body.payload.flights, [{ ident: "NEW1" }]);
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
  assertEquals(body.payload.departures.total, 4);
  assertEquals(body.payload.departures.canceled, 1);
  assertEquals(body.payload.arrivals.total, 4);
  assertEquals(body.payload.severity, "major"); // 1 of 4 canceled
  assert(await snapshot("departures"));
  assert(await snapshot("arrivals"));
  // A second read inside the TTL needs no provider call.
  const again = await handler(get(user, "airport=KAUS&kind=stats"), deps(aero));
  assertEquals((await again.json()).payload.departures.total, 4);
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
  assertEquals(body.fetchedAt, minAgo(20));
  assertEquals(body.payload.departures.total, 0);
  assertEquals(body.payload.severity, "normal");
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
  assertEquals(body.payload.metar.category, "IFR");
  assertEquals(body.payload.metar.ceilingFt, 900);
  assertEquals(body.payload.taf.periods.length, 5);
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
  await seed("weather", minAgo(10), { icao: "KAUS", metar: null, taf: null });
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
