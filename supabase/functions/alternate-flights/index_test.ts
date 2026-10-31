import { assertEquals } from "jsr:@std/assert@1";
import { AeroApi, type AeroScheduledFlight } from "../_shared/aeroapi.ts";
import { ApiError } from "../_shared/errors.ts";
import {
  fakeVerifier,
  loadIndexHandler,
  makeUser,
  test as baseTest,
  testDb,
  trackProviderIds,
} from "../_shared/test_util.ts";
import {
  CACHE_TTL_MS,
  cacheKey,
  handler,
  hourOf,
  toAlternate,
  WINDOW_HOURS,
} from "./handler.ts";

// The fixture is a hand-written schedules answer for SFO to Chicago O'Hare on 3 Nov 2026.
const NOW = new Date("2026-11-03T15:20:00Z");
const at = (ms: number) => () => new Date(NOW.getTime() + ms);
const schedule: AeroScheduledFlight[] = JSON.parse(
  Deno.readTextFileSync(
    new URL("../_shared/fixtures/schedules_ksfo_kord.json", import.meta.url),
  ),
).scheduled;

const db = await testDb();
const keys: string[] = [];

/** Every test removes the cache rows of the routes it asked about. */
function test(name: string, fn: () => Promise<void>) {
  baseTest(db, name, async () => {
    try {
      await fn();
    } finally {
      const done = keys.splice(0);
      if (done.length) {
        const r = await db.from("alternates_cache").delete().in("key", done);
        if (r.error) console.error("alternates_cache cleanup failed", r.error);
      }
    }
  });
}

/** Clears and tracks the cache row of a route for NOW's hour. */
async function freshRoute(origin: string, destination: string) {
  const key = cacheKey(origin, destination, hourOf(NOW));
  keys.push(key);
  const r = await db.from("alternates_cache").delete().eq("key", key);
  if (r.error) throw r.error;
}

function get(token: string | null, query: string): Request {
  return new Request(`http://localhost/alternate-flights?${query}`, {
    headers: token ? { authorization: `Bearer ${token}` } : {},
  });
}

/** The schedules endpoint over the fixture, through the real client: the windows it was asked for. */
function fakeSchedules(fail?: ApiError) {
  const windows: { origin: string; start: Date; end: Date }[] = [];
  const fetchFn = (() =>
    Promise.resolve(
      new Response(JSON.stringify({ scheduled: schedule, links: null })),
    )) as typeof fetch;
  const api = new AeroApi("k", fetchFn);
  return {
    windows,
    schedules(origin: string, destination: string, start: Date, end: Date) {
      windows.push({ origin, start, end });
      if (fail) return Promise.reject(fail);
      return api.schedules(origin, destination, start, end);
    },
  };
}

// MARK: Pure

Deno.test("a schedule entry maps to an answer row", () => {
  const ua = schedule.find((s) => s.ident_iata === "UA1958")!;
  assertEquals(toAlternate(ua), {
    id: "UAL1958-1793563200-schedule-0000",
    ident: "UA1958",
    operator: "UAL",
    origin_iata: "SFO",
    destination_iata: "ORD",
    scheduled_out: "2026-11-03T20:00:00.000Z",
    scheduled_in: "2026-11-04T00:15:00.000Z",
    estimated_out: null,
    estimated_in: null,
    status: "scheduled",
    aircraft_type: "B772",
  });
  // No provider id yet: one made of the designator and the departure.
  const as = schedule.find((s) => s.ident_iata === "AS1314")!;
  assertEquals(toAlternate(as)?.id, "ASA1314-2026-11-03T21:50:00.000Z");
  // No IATA codes: the ICAO ones stand in.
  assertEquals(
    toAlternate({ ...ua, ident_iata: null, origin_iata: null })?.ident,
    "UAL1958",
  );
  assertEquals(
    toAlternate({ ...ua, origin_iata: null })?.origin_iata,
    "KSFO",
  );
  assertEquals(toAlternate({ ...ua, scheduled_out: "soon" }), null);
});

Deno.test("routes are cached by hour", () => {
  assertEquals(hourOf(NOW), new Date("2026-11-03T15:00:00Z"));
  assertEquals(
    cacheKey("KSFO", "KORD", hourOf(NOW)),
    "KSFO-KORD-2026-11-03T15",
  );
});

// MARK: Handler

test("the route's schedule is read once per hour and cached for 30 minutes", async () => {
  const user = await makeUser(db);
  await freshRoute("KSFO", "KORD");
  const aero = fakeSchedules();
  const d = { db, aero, verifier: fakeVerifier, now: at(0) };
  const q = `origin=ksfo&destination=KORD&after=${NOW.toISOString()}`;
  const res = await handler(get(user, q), d);
  assertEquals(res.status, 200);
  const body = await res.json();
  assertEquals(body.origin, "KSFO");
  assertEquals(body.destination, "KORD");
  assertEquals(body.after, "2026-11-03T15:00:00.000Z");
  assertEquals(body.fetched_at, NOW.toISOString());
  assertEquals(body.stale, false);
  // The window is the hour's 24 hours; UA 640 the next afternoon is outside, UA 2306 once.
  assertEquals(aero.windows, [{
    origin: "KSFO",
    start: new Date("2026-11-03T15:00:00Z"),
    end: new Date(
      new Date("2026-11-03T15:00:00Z").getTime() + WINDOW_HOURS * 3_600_000,
    ),
  }]);
  assertEquals(
    body.flights.map((f: { ident: string }) => f.ident),
    ["UA2306", "AA1781", "UA1958", "AS1314"],
  );

  // Anyone asking later the same hour, within 30 minutes: the cache, and only flights after their time.
  const other = await makeUser(db);
  const later = new Date(NOW.getTime() + 20 * 60_000);
  const again = await (await handler(
    get(other, `origin=KSFO&destination=KORD&after=${later.toISOString()}`),
    { ...d, now: at(20 * 60_000) },
  )).json();
  assertEquals(aero.windows.length, 1);
  assertEquals(again.fetched_at, NOW.toISOString());
  assertEquals(
    again.flights.map((f: { ident: string }) => f.ident),
    ["UA2306", "AA1781", "UA1958", "AS1314"],
  );
  const night = await (await handler(
    get(other, `origin=KSFO&destination=KORD&after=2026-11-03T15:00:00Z`),
    { ...d, now: at(CACHE_TTL_MS + 60_000) },
  )).json();
  // Past 30 minutes: read again.
  assertEquals(aero.windows.length, 2);
  assertEquals(night.fetched_at, at(CACHE_TTL_MS + 60_000)().toISOString());
});

test("only flights leaving from `after` on are answered", async () => {
  const user = await makeUser(db);
  const key = cacheKey("KSFO", "KORD", new Date("2026-11-03T16:00:00Z"));
  keys.push(key);
  await db.from("alternates_cache").delete().eq("key", key);
  const body = await (await handler(
    get(user, "origin=KSFO&destination=KORD&after=2026-11-03T16:40:00Z"),
    { db, aero: fakeSchedules(), verifier: fakeVerifier, now: at(0) },
  )).json();
  assertEquals(body.after, "2026-11-03T16:00:00.000Z");
  // UA 2306 left at 16:35; the hour's 24 hours now reach UA 640 the next morning.
  assertEquals(
    body.flights.map((f: { ident: string }) => f.ident),
    ["AA1781", "UA1958", "AS1314", "UA640"],
  );
});

test("a flight the backend tracks shows its status and estimates", async () => {
  const user = await makeUser(db);
  await freshRoute("KSFO", "KORD");
  const providerId = "UAL1958-1793563200-schedule-0000";
  trackProviderIds([providerId]);
  await db.from("flights").delete().eq("provider_id", providerId);
  const ins = await db.from("flights").insert({
    provider_id: providerId,
    ident: "UA1958",
    origin_icao: "KSFO",
    destination_icao: "KORD",
    status: "scheduled",
    scheduled_out: "2026-11-03T20:00:00Z",
    estimated_out: "2026-11-03T20:45:00Z",
    estimated_in: "2026-11-04T01:00:00Z",
  });
  if (ins.error) throw ins.error;
  const res = await handler(
    get(user, `origin=KSFO&destination=KORD&after=${NOW.toISOString()}`),
    { db, aero: fakeSchedules(), verifier: fakeVerifier, now: at(0) },
  );
  const body = await res.json();
  const ua = body.flights.find((f: { ident: string }) => f.ident === "UA1958");
  assertEquals(ua.estimated_out, "2026-11-03T20:45:00.000Z");
  assertEquals(ua.estimated_in, "2026-11-04T01:00:00.000Z");
  assertEquals(ua.status, "scheduled");
  const aa = body.flights.find((f: { ident: string }) => f.ident === "AA1781");
  assertEquals([aa.status, aa.estimated_out], ["scheduled", null]);
});

test("a refused provider serves the cached answer as stale, or 503 with none", async () => {
  const user = await makeUser(db);
  await freshRoute("KSFO", "KORD");
  const q = `origin=KSFO&destination=KORD&after=${NOW.toISOString()}`;
  const capped = new ApiError("provider_unavailable", 503, "cap");
  const none = await handler(get(user, q), {
    db,
    aero: fakeSchedules(capped),
    verifier: fakeVerifier,
    now: at(0),
  });
  assertEquals(none.status, 503);
  assertEquals((await none.json()).error.code, "provider_unavailable");

  await handler(get(user, q), {
    db,
    aero: fakeSchedules(),
    verifier: fakeVerifier,
    now: at(0),
  });
  const stale = await (await handler(get(user, q), {
    db,
    aero: fakeSchedules(capped),
    verifier: fakeVerifier,
    now: at(CACHE_TTL_MS + 1),
  })).json();
  assertEquals(stale.stale, true);
  assertEquals(stale.fetched_at, NOW.toISOString());
  assertEquals(stale.flights.length, 4);
});

test("bad requests are refused before any provider call", async () => {
  const user = await makeUser(db);
  const aero = fakeSchedules();
  const d = { db, aero, verifier: fakeVerifier, now: at(0) };
  const status = async (q: string) => (await handler(get(user, q), d)).status;
  assertEquals(await status("origin=SFO"), 400);
  assertEquals(await status("origin=KSFO&destination=KSFO"), 400);
  assertEquals(await status("origin=K SFO&destination=KORD"), 400);
  assertEquals(await status("origin=KSFO&destination=KORD&after=soon"), 400);
  assertEquals(
    await status("origin=KSFO&destination=KORD&after=2026-11-06T15:00:00Z"),
    400,
  );
  assertEquals(
    await status("origin=KSFO&destination=KORD&after=2026-11-03T10:00:00Z"),
    400,
  );
  assertEquals(
    (await handler(
      new Request("http://localhost/alternate-flights", { method: "POST" }),
      d,
    )).status,
    405,
  );
  assertEquals(
    (await handler(get(null, "origin=KSFO&destination=KORD"), d)).status,
    401,
  );
  assertEquals(aero.windows.length, 0);
});

test("the function starts with no AeroAPI key", async () => {
  const serve = await loadIndexHandler(
    new URL("./index.ts", import.meta.url).href,
  );
  assertEquals(
    (await serve(get(null, "origin=KSFO&destination=KORD"))).status,
    401,
  );
});

// MARK: Contract file: what SupabaseAlternateFlightsService decodes in Swift

const CONTRACT = new URL("./contract/alternates.json", import.meta.url);

test("the contract example matches the handler's answer", async () => {
  const user = await makeUser(db);
  await freshRoute("KSFO", "KORD");
  const answer = await (await handler(
    get(user, `origin=KSFO&destination=KORD&after=${NOW.toISOString()}`),
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
    "contract/alternates.json is out of date: run with UPDATE_CONTRACT=1",
  );
});
