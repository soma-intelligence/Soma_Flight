import { assertEquals } from "jsr:@std/assert@1";
import { AeroApi, ENDPOINT_COST } from "../_shared/aeroapi.ts";
import type { AeroFlight } from "../_shared/aeroapi_types.ts";
import { usageCounter } from "../_shared/limits.ts";
import {
  fakeVerifier,
  loadIndexHandler,
  makeUser,
  test as baseTest,
  testDb,
  trackFlightId,
} from "../_shared/test_util.ts";
import {
  arrivalOf,
  bucketOfMinutes,
  buildForecast,
  FORECAST_MAX_DAYS,
  handler,
  INBOUND_TTL_MS,
  percentages,
  toLeg,
} from "./handler.ts";

// The fixtures are recorded around this instant: AF84 leaves CDG at 12:10Z every day.
const NOW = new Date("2026-11-03T10:00:00Z");
const DAY_MS = 86_400_000;
const at = (ms: number) => () => new Date(NOW.getTime() + ms);
const fixture = (name: string): { flights: AeroFlight[] } =>
  JSON.parse(
    Deno.readTextFileSync(
      new URL(`../_shared/fixtures/${name}`, import.meta.url),
    ),
  );
const history = fixture("history_af84.json").flights;
/** The aircraft's chain before AF84 of 3 Nov, by fa_flight_id. */
const chain = new Map(
  [
    "inbound_af84.json",
    "inbound_leg1_afr1145.json",
    "inbound_leg2_afr1144.json",
    "inbound_leg3_afr11.json",
    "inbound_leg4_afr10.json",
  ].map((name) => {
    const f = fixture(name).flights[0];
    return [f.fa_flight_id, f] as const;
  }),
);
const AF84 = chain.get("AFR84-1793707800-schedule-0001p")!;

const db = await testDb();
const idents: string[] = [];

/** A flight number no other test uses, so the shared forecast cache never leaks between tests. */
function freshIdent(): string {
  const ident = `AF${1000 + Math.floor(Math.random() * 9000)}`;
  idents.push(ident);
  return ident;
}

/** Every test removes the forecasts it cached (inbound rows go with their flight). */
function test(name: string, fn: () => Promise<void>) {
  baseTest(db, name, async () => {
    try {
      await fn();
    } finally {
      const done = idents.splice(0);
      if (done.length) {
        const r = await db.from("forecast_cache").delete().in("ident", done);
        if (r.error) console.error("forecast_cache cleanup failed", r.error);
      }
    }
  });
}

function get(token: string | null, query: string): Request {
  return new Request(`http://localhost/flight-insights?${query}`, {
    headers: token ? { authorization: `Bearer ${token}` } : {},
  });
}

/** The history endpoint over the fixture: the flights whose departure is in [start, end). */
function fakeHistory(source: AeroFlight[] = history) {
  const windows: { start: Date; end: Date }[] = [];
  return {
    windows,
    flightHistory(_ident: string, start: Date, end: Date) {
      windows.push({ start, end });
      return Promise.resolve(source.filter((f) => {
        const t = Date.parse(f.scheduled_out!);
        return t >= start.getTime() && t < end.getTime();
      }));
    },
    flightById(_id: string): Promise<AeroFlight | null> {
      throw new Error("not used");
    },
  };
}

/** A recorded provider: /flights/{fa_flight_id} answers from the chain fixtures, 404 otherwise. */
function chainFetch(byId: Map<string, AeroFlight>, calls: string[] = []) {
  return ((input: string | URL | Request) => {
    const url = new URL(String(input));
    const id = decodeURIComponent(url.pathname.split("/").pop()!);
    calls.push(id);
    const f = byId.get(id);
    return Promise.resolve(
      f
        ? new Response(
          JSON.stringify({ flights: [f], links: null, num_pages: 1 }),
        )
        : new Response("{}", { status: 404 }),
    );
  }) as typeof fetch;
}

/** A row in flights for AF84 of 3 Nov, under a provider id of its own (the chain starts there). */
async function af84Row(): Promise<{ id: string; providerId: string }> {
  const providerId = `INS${crypto.randomUUID().slice(0, 8)}-1-schedule-1p`;
  const { data, error } = await db.from("flights").insert({
    provider_id: providerId,
    ident: "AF84",
    origin_icao: "LFPG",
    destination_icao: "KSFO",
    status: "scheduled",
    scheduled_out: AF84.scheduled_out,
  }).select("id").single();
  if (error) throw error;
  trackFlightId(data.id);
  return { id: data.id as string, providerId };
}

/** usage_counters of a day no real call ever uses, so a test can charge and clean up freely. */
const COUNTER_DAY = new Date("2099-01-01T12:00:00Z");
async function clearCounters() {
  const r = await db.from("usage_counters").delete().eq("day", "2099-01-01");
  if (r.error) throw r.error;
}

// MARK: Bucketing

Deno.test("arrivals fall in the app's buckets", () => {
  assertEquals(
    [-1, 0, 14, 15, 29, 30, 44, 45, 300].map(bucketOfMinutes),
    [
      "early",
      "on_time",
      "on_time",
      "late15",
      "late15",
      "late30",
      "late30",
      "late45",
      "late45",
    ],
  );
  const base = history[0];
  assertEquals(arrivalOf(base), { bucket: "early", lateMinutes: -5 });
  assertEquals(arrivalOf({ ...base, cancelled: true })?.bucket, "canceled");
  assertEquals(arrivalOf({ ...base, diverted: true })?.bucket, "diverted");
  // No gate arrival: the runway times stand in.
  assertEquals(arrivalOf({ ...base, actual_in: null })?.lateMinutes, -5);
  // Still in the air, or no schedule: not counted.
  assertEquals(
    arrivalOf({ ...base, actual_in: null, actual_on: null }),
    null,
  );
  assertEquals(
    arrivalOf({ ...base, scheduled_in: null, scheduled_on: null }),
    null,
  );
  // 20 seconds early rounds to on time.
  assertEquals(
    arrivalOf({ ...base, actual_in: "2026-11-02T23:04:40Z" })?.bucket,
    "on_time",
  );
});

Deno.test("percents add up to 100 by largest remainder", () => {
  const zero = {
    early: 0,
    on_time: 0,
    late15: 0,
    late30: 0,
    late45: 0,
    canceled: 0,
    diverted: 0,
  };
  const thirds = percentages({ ...zero, early: 1, on_time: 1, late15: 1 });
  assertEquals(thirds, { ...zero, early: 34, on_time: 33, late15: 33 });
  assertEquals(percentages(zero), zero);
  assertEquals(
    Object.values(percentages({ ...zero, late45: 7, canceled: 3 })),
    [0, 0, 0, 0, 70, 30, 0],
  );
});

Deno.test("the recorded history makes the expected forecast", () => {
  const f = buildForecast("AF84", history, 60)!;
  // 13 finished flights (the diverted one has two rows, one en route is left out).
  const deduped = [...new Map(history.map((f) => [f.fa_flight_id, f]))
    .values()];
  assertEquals(buildForecast("AF84", deduped, 60)?.observed, 13);
  assertEquals(f.percents, {
    early: 16,
    on_time: 23,
    late15: 15,
    late30: 15,
    late45: 15,
    canceled: 8,
    diverted: 8,
  });
  assertEquals(f.late_percent, 45);
  // 15, 29, 30, 44, 45 and 90 minutes late.
  assertEquals(f.average_late_minutes, 42);
  assertEquals(buildForecast("AF84", [], 60), null);
});

// MARK: Inbound legs

Deno.test("a provider flight maps to an inbound leg", () => {
  const leg1 = chain.get("AFR1145-1793689200-schedule-0001p")!;
  assertEquals(toLeg(leg1), {
    id: "AFR1145-1793689200-schedule-0001p",
    ident: "AF1145",
    origin_iata: "LHR",
    destination_iata: "CDG",
    scheduled_out: "2026-11-03T07:00:00.000Z",
    scheduled_in: "2026-11-03T08:15:00.000Z",
    status: "arrived",
    delay_minutes: 12,
  });
  // An early arrival is no delay; an estimate counts before the flight lands.
  assertEquals(
    toLeg({ ...leg1, actual_in: "2026-11-03T08:05:00Z" })?.delay_minutes,
    0,
  );
  assertEquals(
    toLeg({
      ...leg1,
      actual_in: null,
      actual_on: null,
      estimated_in: "2026-11-03T08:40:00Z",
    })?.delay_minutes,
    25,
  );
  // No code to show: dropped.
  assertEquals(toLeg({ ...leg1, origin: null }), null);
});

// MARK: Handler, arrival forecast

test("the forecast walks the history back in 7 day windows and is cached for 12 hours", async () => {
  const user = await makeUser(db);
  const ident = freshIdent();
  const aero = fakeHistory();
  const d = { db, aero, verifier: fakeVerifier, now: at(0) };
  const res = await handler(
    get(user, `mode=arrival_forecast&ident=${ident}`),
    d,
  );
  assertEquals(res.status, 200);
  const body = await res.json();
  assertEquals(body.ident, ident);
  assertEquals(body.stale, false);
  assertEquals(body.fetched_at, NOW.toISOString());
  assertEquals(body.forecast.observed, 13);
  assertEquals(body.forecast.days, FORECAST_MAX_DAYS);
  assertEquals(body.forecast.late_percent, 45);
  // Fewer than 30 finished flights: all 60 days, newest window first, back to back.
  assertEquals(aero.windows.length, 9);
  assertEquals(aero.windows[0].end, NOW);
  for (let i = 1; i < aero.windows.length; i++) {
    assertEquals(aero.windows[i].end, aero.windows[i - 1].start);
  }
  assertEquals(
    aero.windows.at(-1)!.start,
    new Date(NOW.getTime() - FORECAST_MAX_DAYS * DAY_MS),
  );

  // Another open, by anyone, within 12 hours: the cached answer, no provider call.
  const other = await makeUser(db);
  for (const ms of [60_000, 11 * 3_600_000]) {
    const again = await handler(
      get(other, `mode=arrival_forecast&ident=${ident.toLowerCase()}`),
      { ...d, now: at(ms) },
    );
    const b = await again.json();
    assertEquals(b.forecast, body.forecast);
    assertEquals(b.fetched_at, NOW.toISOString());
  }
  assertEquals(aero.windows.length, 9);

  // After 12 hours it is read again.
  await handler(get(user, `mode=arrival_forecast&ident=${ident}`), {
    ...d,
    now: at(13 * 3_600_000),
  });
  assertEquals(aero.windows.length, 18);
});

test("the walk stops once it has enough finished flights", async () => {
  const user = await makeUser(db);
  const ident = freshIdent();
  const aero = fakeHistory();
  const res = await handler(get(user, `mode=arrival_forecast&ident=${ident}`), {
    db,
    aero,
    verifier: fakeVerifier,
    now: at(0),
    forecastTarget: 5,
  });
  const f = (await res.json()).forecast;
  // The first week holds six finished flights (1 to 6 days ago).
  assertEquals(aero.windows.length, 1);
  assertEquals([f.days, f.observed], [7, 6]);
});

test("a flight number with no finished flight caches a null forecast", async () => {
  const user = await makeUser(db);
  const ident = freshIdent();
  const aero = fakeHistory([]);
  const d = { db, aero, verifier: fakeVerifier, now: at(0) };
  for (let i = 0; i < 2; i++) {
    const res = await handler(
      get(user, `mode=arrival_forecast&ident=${ident}`),
      d,
    );
    assertEquals(res.status, 200);
    assertEquals((await res.json()).forecast, null);
  }
  assertEquals(aero.windows.length, 9);
});

// MARK: Handler, inbound chain

test("the inbound chain follows the aircraft back 25 hours, newest first, through the counter", async () => {
  await clearCounters();
  try {
    const user = await makeUser(db);
    const { id, providerId } = await af84Row();
    const byId = new Map(chain);
    byId.set(providerId, { ...AF84, fa_flight_id: providerId });
    const calls: string[] = [];
    const aero = new AeroApi(
      "k",
      chainFetch(byId, calls),
      usageCounter(db, () => COUNTER_DAY, 1000),
    );
    const d = { db, aero, verifier: fakeVerifier, now: at(0) };
    const res = await handler(get(user, `mode=inbound&flight_id=${id}`), d);
    assertEquals(res.status, 200);
    const body = await res.json();
    assertEquals(body.flight_id, id);
    assertEquals(body.stale, false);
    assertEquals(
      body.legs.map((
        l: { ident: string; origin_iata: string; destination_iata: string },
      ) => `${l.ident} ${l.origin_iata}-${l.destination_iata}`),
      ["AF1145 LHR-CDG", "AF1144 CDG-LHR", "AF11 JFK-CDG"],
    );
    assertEquals(
      body.legs.map((l: { delay_minutes: number }) => l.delay_minutes),
      [12, 0, 35],
    );
    // The flight itself, three legs, and the CDG-JFK leg 28 hours back that ends the walk.
    assertEquals(calls, [
      providerId,
      "AFR1145-1793689200-schedule-0001p",
      "AFR1144-1793682000-schedule-0001p",
      "AFR11-1793626200-schedule-0001p",
      "AFR10-1793606400-schedule-0001p",
    ]);
    const counted = await db.from("usage_counters").select(
      "calls, estimated_cost",
    )
      .eq("day", "2099-01-01").eq("endpoint", "/flights/{ident}").single();
    assertEquals(counted.data?.calls, 5);
    assertEquals(
      Number(counted.data?.estimated_cost),
      5 * ENDPOINT_COST["/flights/{ident}"],
    );

    // Within 10 minutes: cached. After: asked again.
    await handler(get(user, `mode=inbound&flight_id=${id}`), {
      ...d,
      now: at(INBOUND_TTL_MS - 1000),
    });
    assertEquals(calls.length, 5);
    await handler(get(user, `mode=inbound&flight_id=${id}`), {
      ...d,
      now: at(INBOUND_TTL_MS + 1000),
    });
    assertEquals(calls.length, 10);
  } finally {
    await clearCounters();
  }
});

test("no inbound flight, an unknown one or a loop end the chain", async () => {
  const user = await makeUser(db);
  const cases: [string, (p: string) => Map<string, AeroFlight>, number][] = [
    // The provider names no inbound flight.
    [
      "none",
      (p) =>
        new Map([[p, {
          ...AF84,
          fa_flight_id: p,
          inbound_fa_flight_id: null,
        }]]),
      0,
    ],
    // The inbound flight is unknown at the provider.
    [
      "unknown",
      (p) =>
        new Map([[p, {
          ...AF84,
          fa_flight_id: p,
          inbound_fa_flight_id: "GONE-1",
        }]]),
      0,
    ],
    // A leg points back at a leg already seen.
    ["loop", (p) => {
      const leg = chain.get("AFR1145-1793689200-schedule-0001p")!;
      return new Map([
        [p, { ...AF84, fa_flight_id: p }],
        [leg.fa_flight_id, { ...leg, inbound_fa_flight_id: leg.fa_flight_id }],
      ]);
    }, 1],
  ];
  for (const [name, make, count] of cases) {
    const { id, providerId } = await af84Row();
    const aero = new AeroApi("k", chainFetch(make(providerId)));
    const res = await handler(get(user, `mode=inbound&flight_id=${id}`), {
      db,
      aero,
      verifier: fakeVerifier,
      now: at(0),
    });
    assertEquals(res.status, 200, name);
    assertEquals((await res.json()).legs.length, count, name);
  }
});

// MARK: Spend cap

test("the spend cap refuses before any provider call and the app is told it is unavailable", async () => {
  const user = await makeUser(db);
  const ident = freshIdent();
  const { id } = await af84Row();
  let fetched = 0;
  const fetchFn = ((..._args: unknown[]) => {
    fetched++;
    return Promise.resolve(new Response("{}"));
  }) as typeof fetch;
  // A cap of 0: every paid call is refused, and nothing is counted.
  const aero = new AeroApi(
    "k",
    fetchFn,
    usageCounter(db, () => COUNTER_DAY, 0),
  );
  const orig = console.error;
  console.error = () => {};
  try {
    const d = { db, aero, verifier: fakeVerifier, now: at(0) };
    for (
      const q of [
        `mode=arrival_forecast&ident=${ident}`,
        `mode=inbound&flight_id=${id}`,
      ]
    ) {
      const res = await handler(get(user, q), d);
      assertEquals(res.status, 503, q);
      assertEquals((await res.json()).error.code, "provider_unavailable", q);
    }
    assertEquals(fetched, 0);
    const counted = await db.from("usage_counters").select("calls").eq(
      "day",
      "2099-01-01",
    );
    assertEquals(counted.data, []);
    // Nothing was cached, so the next open asks again.
    const rows = await db.from("forecast_cache").select("ident").eq(
      "ident",
      ident,
    );
    assertEquals(rows.data, []);

    // With an answer cached earlier, an expired one is served as stale instead.
    const legs = [{
      ...toLeg(chain.get("AFR1145-1793689200-schedule-0001p")!),
    }];
    await db.from("inbound_cache").insert({
      flight_id: id,
      payload: { legs },
      fetched_at: new Date(NOW.getTime() - 3_600_000).toISOString(),
    });
    await db.from("forecast_cache").insert({
      ident,
      payload: { forecast: buildForecast(ident, history, 60) },
      fetched_at: new Date(NOW.getTime() - 2 * DAY_MS).toISOString(),
    });
    const inbound = await (await handler(
      get(user, `mode=inbound&flight_id=${id}`),
      d,
    )).json();
    assertEquals([inbound.stale, inbound.legs], [true, legs]);
    const forecast = await (await handler(
      get(user, `mode=arrival_forecast&ident=${ident}`),
      d,
    )).json();
    assertEquals([forecast.stale, forecast.forecast.observed], [true, 13]);
    assertEquals(fetched, 0);
  } finally {
    console.error = orig;
    await clearCounters();
  }
});

test("an unexpected failure is not hidden behind the cache", async () => {
  const user = await makeUser(db);
  const ident = freshIdent();
  const aero = {
    flightHistory: () => Promise.reject(new TypeError("bug")),
    flightById: () => Promise.reject(new TypeError("bug")),
  };
  const orig = console.error;
  console.error = () => {};
  try {
    const res = await handler(
      get(user, `mode=arrival_forecast&ident=${ident}`),
      {
        db,
        aero,
        verifier: fakeVerifier,
        now: at(0),
      },
    );
    assertEquals(res.status, 500);
  } finally {
    console.error = orig;
  }
});

// MARK: Input and auth

test("bad input, unknown flights and missing tokens are typed errors", async () => {
  const user = await makeUser(db);
  const d = { db, aero: fakeHistory(), verifier: fakeVerifier, now: at(0) };
  const code = async (r: Response) => [r.status, (await r.json()).error.code];
  assertEquals(await code(await handler(get(user, "mode=nope"), d)), [
    400,
    "invalid_request",
  ]);
  assertEquals(await code(await handler(get(user, "ident=AF84"), d)), [
    400,
    "invalid_request",
  ]);
  for (const ident of ["", "A", "AF", "AF84123", "AF-84", "'; drop"]) {
    assertEquals(
      await code(
        await handler(
          get(user, `mode=arrival_forecast&ident=${encodeURIComponent(ident)}`),
          d,
        ),
      ),
      [400, "invalid_request"],
      ident,
    );
  }
  assertEquals(
    await code(await handler(get(user, "mode=inbound&flight_id=nope"), d)),
    [400, "invalid_request"],
  );
  assertEquals(
    await code(
      await handler(
        get(user, `mode=inbound&flight_id=${crypto.randomUUID()}`),
        d,
      ),
    ),
    [404, "not_found"],
  );
  assertEquals(
    (await handler(get(null, "mode=arrival_forecast&ident=AF84"), d)).status,
    401,
  );
  const post = new Request("http://localhost/flight-insights?mode=inbound", {
    method: "POST",
    headers: { authorization: `Bearer ${user}` },
  });
  assertEquals((await handler(post, d)).status, 405);
});

test("flight-insights starts without AEROAPI_KEY and answers unavailable", async () => {
  const serve = await loadIndexHandler(
    new URL("./index.ts", import.meta.url).href,
  );
  assertEquals(
    (await serve(get(null, "mode=arrival_forecast&ident=AF84"))).status,
    401,
  );
});

// MARK: Contract files: what SupabaseInsightsService decodes in Swift

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
  const d = { db, aero: fakeHistory(), verifier: fakeVerifier, now: at(0) };
  // A fixed ident: clear what an earlier run of this test cached.
  idents.push("AF84");
  await db.from("forecast_cache").delete().eq("ident", "AF84");
  const forecast = await (await handler(
    get(user, "mode=arrival_forecast&ident=AF84"),
    d,
  )).json();
  await checkContract("arrival_forecast", forecast);

  const { id, providerId } = await af84Row();
  const byId = new Map(chain);
  byId.set(providerId, { ...AF84, fa_flight_id: providerId });
  const inbound =
    await (await handler(get(user, `mode=inbound&flight_id=${id}`), {
      ...d,
      aero: new AeroApi("k", chainFetch(byId)),
    })).json();
  // The flight id is random per run: the contract carries a fixed one.
  await checkContract("inbound", {
    ...inbound,
    flight_id: "c2000000-0000-0000-0000-000000000001",
  });
});
