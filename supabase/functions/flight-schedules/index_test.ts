import { assertEquals } from "jsr:@std/assert@1";
import { AeroApi, type AeroScheduledFlight } from "../_shared/aeroapi.ts";
import { ApiError } from "../_shared/errors.ts";
import {
  fakeVerifier,
  loadIndexHandler,
  makeUser,
  test as baseTest,
  testDb,
} from "../_shared/test_util.ts";
import {
  CACHE_TTL_MS,
  cacheKey,
  handler,
  SCHEDULES_MAX_PER_HOUR,
  toScheduledFlight,
} from "./handler.ts";

// The fixture is a hand-written schedules answer for SFO to Chicago O'Hare on 3 Nov 2026.
const NOW = new Date("2026-11-01T12:00:00Z");
const DATE = "2026-11-03";
const at = (ms: number) => () => new Date(NOW.getTime() + ms);
const schedule: AeroScheduledFlight[] = JSON.parse(
  Deno.readTextFileSync(
    new URL("../_shared/fixtures/schedules_ksfo_kord.json", import.meta.url),
  ),
).scheduled;

const db = await testDb();
const keys: string[] = [];

/** Every test removes the cache rows of the searches it asked about. */
function test(name: string, fn: () => Promise<void>) {
  baseTest(db, name, async () => {
    try {
      await fn();
    } finally {
      const done = keys.splice(0);
      if (done.length) {
        const r = await db.from("schedules_cache").delete().in("key", done);
        if (r.error) console.error("schedules_cache cleanup failed", r.error);
      }
    }
  });
}

/** Clears and tracks the cache row of a search. */
async function fresh(
  q: {
    origin?: string;
    destination?: string;
    airline?: string;
    ident?: string;
    time?: number;
  },
  date = DATE,
) {
  const key = cacheKey(q, date);
  keys.push(key);
  const r = await db.from("schedules_cache").delete().eq("key", key);
  if (r.error) throw r.error;
}

function post(token: string | null, body: unknown): Request {
  return new Request("http://localhost/flight-schedules", {
    method: "POST",
    headers: token ? { authorization: `Bearer ${token}` } : {},
    body: JSON.stringify(body),
  });
}

/**
 * The schedules endpoint over the fixture (or `rows`), through the real client: what it was asked for.
 * `more` makes every page point at another, as a busy airport's day does.
 */
function fakeSchedules(
  fail?: ApiError,
  opts: { rows?: AeroScheduledFlight[]; more?: boolean } = {},
) {
  const calls: {
    start: string;
    end: string;
    query: Record<string, string>;
  }[] = [];
  const fetchFn = ((input: Request | string | URL) => {
    const url = new URL(input instanceof Request ? input.url : String(input));
    const [start, end] = decodeURIComponent(url.pathname).split("/").slice(-2);
    calls.push({
      start,
      end,
      query: Object.fromEntries(url.searchParams),
    });
    if (fail) return Promise.reject(fail);
    return Promise.resolve(
      new Response(JSON.stringify({
        scheduled: opts.rows ?? schedule,
        links: opts.more ? { next: "/schedules/a/b?cursor=next" } : null,
      })),
    );
  }) as typeof fetch;
  const api = new AeroApi("k", fetchFn);
  return {
    calls,
    scheduleWindow: api.scheduleWindow.bind(api) as AeroApi["scheduleWindow"],
  };
}

const IDENTS = ["UA2306", "AA1781", "UA1958", "AS1314"];
const identsOf = (b: { flights: { ident: string }[] }) =>
  b.flights.map((f) => f.ident);

// MARK: Pure

Deno.test("a schedule entry maps to an answer row", () => {
  const ua = schedule.find((s) => s.ident_iata === "UA1958")!;
  assertEquals(toScheduledFlight(ua), {
    ident: "UA1958",
    airline: "UAL",
    origin: "KSFO",
    destination: "KORD",
    scheduled_out: "2026-11-03T20:00:00.000Z",
    scheduled_in: "2026-11-04T00:15:00.000Z",
    aircraft_type: "B772",
  });
  assertEquals(
    toScheduledFlight({ ...ua, ident_iata: null })?.ident,
    "UAL1958",
  );
  assertEquals(toScheduledFlight({ ...ua, scheduled_in: "soon" }), null);
});

Deno.test("searches are cached by what was asked and the day", () => {
  assertEquals(
    cacheKey({ origin: "KSFO", destination: "KORD" }, DATE),
    "KSFO-KORD-*-*-2026-11-03",
  );
  assertEquals(
    cacheKey({ airline: "UA", ident: "UA1958" }, DATE),
    "*-*-UA-UA1958-2026-11-03",
  );
});

// MARK: Handler

test("the origin's local day is the provider's window, filters go through", async () => {
  const user = await makeUser(db);
  const q = { origin: "KSFO", destination: "KORD" };
  await fresh(q);
  const aero = fakeSchedules();
  const d = { db, aero, verifier: fakeVerifier, now: at(0) };
  const res = await handler(
    post(user, { origin: "sfo", destination: "KORD", date: DATE }),
    d,
  );
  assertEquals(res.status, 200);
  const body = await res.json();
  assertEquals(body.date, DATE);
  assertEquals(body.fetched_at, NOW.toISOString());
  assertEquals(body.stale, false);
  assertEquals(identsOf(body), IDENTS);
  // 3 Nov in San Francisco is 08:00Z to 08:00Z (PST); UA 640 the next afternoon is outside.
  assertEquals(aero.calls.length, 1);
  assertEquals(aero.calls[0].start, "2026-11-03T08:00:00.000Z");
  assertEquals(aero.calls[0].end, "2026-11-04T08:00:00.000Z");
  assertEquals(aero.calls[0].query.origin, "KSFO");
  assertEquals(aero.calls[0].query.destination, "KORD");
  assertEquals(aero.calls[0].query.airline, undefined);

  // An ident becomes the provider's airline and flight number.
  const byIdent = { ident: "UA1958" };
  await fresh(byIdent);
  const idRes = await handler(post(user, { ...byIdent, date: DATE }), d);
  assertEquals(idRes.status, 200);
  // No place: noon UTC the day before to noon UTC the day after, which holds the day anywhere.
  assertEquals(aero.calls[1].start, "2026-11-02T12:00:00.000Z");
  assertEquals(aero.calls[1].end, "2026-11-04T12:00:00.000Z");
  assertEquals(aero.calls[1].query.airline, "UA");
  assertEquals(aero.calls[1].query.flight_number, "1958");
  assertEquals(aero.calls[1].query.origin, undefined);

  // Only a destination: its own day (Chicago, CST, 06:00Z).
  const toOnly = { destination: "KORD", airline: "AA" };
  await fresh(toOnly);
  await handler(post(user, { ...toOnly, date: DATE }), d);
  assertEquals(aero.calls[2].start, "2026-11-03T06:00:00.000Z");
  assertEquals(aero.calls[2].query.airline, "AA");
});

/** A schedule entry for the ident tests: `out` and `in` as UTC instants. */
function entry(
  ident: string,
  origin: string,
  destination: string,
  out: string,
  arrive: string,
): AeroScheduledFlight {
  const icao = ident.replace(/^AF/, "AFR").replace(/^NH/, "ANA");
  return {
    ident: icao,
    ident_icao: icao,
    ident_iata: ident,
    aircraft_type: "B77W",
    scheduled_out: out,
    scheduled_in: arrive,
    origin,
    origin_icao: origin,
    origin_iata: null,
    destination,
    destination_icao: destination,
    destination_iata: null,
    fa_flight_id: null,
  };
}

test("a flight number alone keeps the flights leaving on the day at their origin", async () => {
  const user = await makeUser(db);
  const d = "2026-12-12";
  // AF 7 leaves New York at 20:00 (EST): 01:00Z the next day. The 11 Dec one leaves at 01:00Z on 12 Dec.
  const af = [
    entry(
      "AF7",
      "KJFK",
      "LFPG",
      "2026-12-12T01:00:00Z",
      "2026-12-12T08:30:00Z",
    ),
    entry(
      "AF7",
      "KJFK",
      "LFPG",
      "2026-12-13T01:00:00Z",
      "2026-12-13T08:30:00Z",
    ),
  ];
  await fresh({ ident: "AF7" }, d);
  const aero = fakeSchedules(undefined, { rows: af });
  const deps = { db, aero, verifier: fakeVerifier, now: at(0) };
  const body =
    await (await handler(post(user, { ident: "AF7", date: d }), deps))
      .json();
  assertEquals(
    body.flights.map((f: { scheduled_out: string }) => f.scheduled_out),
    [
      "2026-12-13T01:00:00.000Z",
    ],
  );
  assertEquals(aero.calls[0].start, "2026-12-11T12:00:00.000Z");
  assertEquals(aero.calls[0].end, "2026-12-13T12:00:00.000Z");

  // NH 10 leaves Tokyo at 06:00 (JST): 21:00Z the day before. The 13 Dec one is 21:00Z on 12 Dec.
  const nh = [
    entry(
      "NH10",
      "RJTT",
      "KJFK",
      "2026-12-11T21:00:00Z",
      "2026-12-12T08:00:00Z",
    ),
    entry(
      "NH10",
      "RJTT",
      "KJFK",
      "2026-12-12T21:00:00Z",
      "2026-12-13T08:00:00Z",
    ),
  ];
  await fresh({ ident: "NH10" }, d);
  const tokyo = await (await handler(post(user, { ident: "NH10", date: d }), {
    ...deps,
    aero: fakeSchedules(undefined, { rows: nh }),
  })).json();
  assertEquals(
    tokyo.flights.map((f: { scheduled_out: string }) => f.scheduled_out),
    [
      "2026-12-11T21:00:00.000Z",
    ],
  );
});

test("a time of day narrows the window to 4 hours either side, within the day", async () => {
  const user = await makeUser(db);
  const d = { db, verifier: fakeVerifier, now: at(0) };
  // 19:00 in San Francisco on 3 Nov (PST) is 03:00Z on 4 Nov: 23:00Z to the end of the local day.
  await fresh({ origin: "KSFO", time: 1140 });
  const evening = fakeSchedules();
  const res = await handler(
    post(user, { origin: "KSFO", date: DATE, time: 1140 }),
    { ...d, aero: evening },
  );
  assertEquals(res.status, 200);
  assertEquals(evening.calls[0].start, "2026-11-03T23:00:00.000Z");
  assertEquals(evening.calls[0].end, "2026-11-04T07:00:00.000Z");
  // 08:00 is 16:00Z: 12:00Z to 20:00Z, the local day's start not before 08:00Z.
  await fresh({ origin: "KSFO", time: 480 });
  const morning = fakeSchedules();
  await handler(post(user, { origin: "KSFO", date: DATE, time: 480 }), {
    ...d,
    aero: morning,
  });
  assertEquals(morning.calls[0].start, "2026-11-03T12:00:00.000Z");
  assertEquals(morning.calls[0].end, "2026-11-03T20:00:00.000Z");
  // 01:00: clipped to the day's start (08:00Z), up to 13:00Z.
  await fresh({ origin: "KSFO", time: 60 });
  const night = fakeSchedules();
  await handler(post(user, { origin: "KSFO", date: DATE, time: 60 }), {
    ...d,
    aero: night,
  });
  assertEquals(night.calls[0].start, "2026-11-03T08:00:00.000Z");
  assertEquals(night.calls[0].end, "2026-11-03T13:00:00.000Z");
  // A time is its own search: the whole day is not served from it.
  assertEquals(
    cacheKey({ origin: "KSFO", time: 1140 }, DATE),
    "KSFO-*-*-*-2026-11-03-t1140",
  );
  // Not a minute of the day.
  for (const time of [-1, 1440, 12.5, "19:00"]) {
    assertEquals(
      (await handler(post(user, { origin: "KSFO", date: DATE, time }), {
        ...d,
        aero: fakeSchedules(),
      })).status,
      400,
    );
  }
});

test("an answer cut at the page limit says so, cached or not", async () => {
  const user = await makeUser(db);
  const q = { origin: "KSFO" };
  await fresh(q);
  const busy = fakeSchedules(undefined, { more: true });
  const d = { db, aero: busy, verifier: fakeVerifier, now: at(0) };
  const first = await (await handler(post(user, { ...q, date: DATE }), d))
    .json();
  assertEquals(busy.calls.length, 3);
  assertEquals(first.truncated, true);
  const again = await (await handler(post(user, { ...q, date: DATE }), d))
    .json();
  assertEquals(busy.calls.length, 3);
  assertEquals(again.truncated, true);
  // A route fits in its pages.
  const route = { origin: "KSFO", destination: "KORD" };
  await fresh(route);
  const whole = await (await handler(post(user, { ...route, date: DATE }), {
    ...d,
    aero: fakeSchedules(),
  })).json();
  assertEquals(whole.truncated, false);
});

test("a second call within 6 hours reads the cache and makes no provider call", async () => {
  const user = await makeUser(db);
  const q = { origin: "KSFO", destination: "KORD" };
  await fresh(q);
  const aero = fakeSchedules();
  const d = { db, aero, verifier: fakeVerifier, now: at(0) };
  const ask = { origin: "KSFO", destination: "KORD", date: DATE };
  await handler(post(user, ask), d);
  const other = await makeUser(db);
  const again = await (await handler(post(other, ask), {
    ...d,
    now: at(CACHE_TTL_MS - 60_000),
  })).json();
  assertEquals(aero.calls.length, 1);
  assertEquals(again.fetched_at, NOW.toISOString());
  assertEquals(again.stale, false);
  assertEquals(identsOf(again), IDENTS);
  // Past 6 hours: read again.
  const later = await (await handler(post(other, ask), {
    ...d,
    now: at(CACHE_TTL_MS + 60_000),
  })).json();
  assertEquals(aero.calls.length, 2);
  assertEquals(later.fetched_at, at(CACHE_TTL_MS + 60_000)().toISOString());
});

test("a refused provider serves the cached answer as stale, or 503 with none", async () => {
  const user = await makeUser(db);
  const q = { origin: "KSFO", destination: "KORD" };
  await fresh(q);
  const ask = { origin: "KSFO", destination: "KORD", date: DATE };
  const capped = new ApiError("provider_unavailable", 503, "cap");
  const none = await handler(post(user, ask), {
    db,
    aero: fakeSchedules(capped),
    verifier: fakeVerifier,
    now: at(0),
  });
  assertEquals(none.status, 503);
  assertEquals((await none.json()).error.code, "provider_unavailable");

  await handler(post(user, ask), {
    db,
    aero: fakeSchedules(),
    verifier: fakeVerifier,
    now: at(0),
  });
  const stale = await (await handler(post(user, ask), {
    db,
    aero: fakeSchedules(capped),
    verifier: fakeVerifier,
    now: at(CACHE_TTL_MS + 1),
  })).json();
  assertEquals(stale.stale, true);
  assertEquals(stale.fetched_at, NOW.toISOString());
  assertEquals(stale.flights.length, 4);
});

test("the 31st call in an hour is rate limited", async () => {
  const user = await makeUser(db);
  const q = { origin: "KSFO", destination: "KORD" };
  await fresh(q);
  const aero = fakeSchedules();
  const d = { db, aero, verifier: fakeVerifier, now: at(0) };
  const ask = { origin: "KSFO", destination: "KORD", date: DATE };
  for (let i = 0; i < SCHEDULES_MAX_PER_HOUR; i++) {
    assertEquals((await handler(post(user, ask), d)).status, 200);
  }
  const res = await handler(post(user, ask), d);
  assertEquals(res.status, 429);
  assertEquals((await res.json()).error.code, "rate_limited");
  assertEquals(aero.calls.length, 1);
});

test("bad requests are refused before any provider call", async () => {
  const user = await makeUser(db);
  const aero = fakeSchedules();
  const d = { db, aero, verifier: fakeVerifier, now: at(0) };
  const status = async (b: unknown) => (await handler(post(user, b), d)).status;
  const route = { origin: "KSFO", destination: "KORD" };
  // Nothing to search by.
  assertEquals(await status({ date: DATE }), 400);
  assertEquals(await status({ airline: "UA", date: DATE }), 400);
  // Bad dates.
  assertEquals(await status({ ...route, date: "soon" }), 400);
  assertEquals(await status({ ...route, date: "2026-02-30" }), 400);
  assertEquals(await status({ ...route }), 400);
  // 330 days ahead is the last day (from 1 Nov 2026: 27 Sep 2027).
  assertEquals(await status({ ...route, date: "2027-09-30" }), 400);
  const far = await handler(post(user, { ...route, date: "2027-12-01" }), d);
  assertEquals((await far.json()).error.code, "out_of_window");
  // Bad parts.
  assertEquals(await status({ ident: "UA", date: DATE }), 400);
  assertEquals(await status({ ...route, airline: "UNITED", date: DATE }), 400);
  assertEquals(
    await status({ origin: "KSFO", destination: "KSFO", date: DATE }),
    400,
  );
  assertEquals(await status({ origin: "QQQQ", date: DATE }), 400);
  assertEquals(
    (await handler(new Request("http://localhost/flight-schedules"), d)).status,
    405,
  );
  assertEquals(
    (await handler(post(null, { ...route, date: DATE }), d)).status,
    401,
  );
  assertEquals(aero.calls.length, 0);
});

test("the function starts with no AeroAPI key", async () => {
  const serve = await loadIndexHandler(
    new URL("./index.ts", import.meta.url).href,
  );
  assertEquals(
    (await serve(post(null, { origin: "KSFO", date: DATE }))).status,
    401,
  );
});

// MARK: Contract file: what the Swift flight-schedules service decodes

const CONTRACT = new URL("./contract/schedules.json", import.meta.url);

test("the contract example matches the handler's answer", async () => {
  const user = await makeUser(db);
  const q = { origin: "KSFO", destination: "KORD" };
  await fresh(q);
  const answer = await (await handler(
    post(user, { origin: "KSFO", destination: "KORD", date: DATE }),
    { db, aero: fakeSchedules(), verifier: fakeVerifier, now: at(0) },
  )).json();
  const text = JSON.stringify(answer, null, 2) + "\n";
  if (Deno.env.get("UPDATE_CONTRACT") === "1") {
    await Deno.mkdir(new URL("./contract/", import.meta.url), {
      recursive: true,
    });
    await Deno.writeTextFile(CONTRACT, text);
    return;
  }
  assertEquals(
    JSON.parse(await Deno.readTextFile(CONTRACT)),
    JSON.parse(text),
    "contract/schedules.json is out of date: run with UPDATE_CONTRACT=1",
  );
});
