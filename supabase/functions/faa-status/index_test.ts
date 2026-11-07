// faa-status on the local stack: the answer per airport, the shared 5 minute cache, the stale and
// down cases, and the sweep that hands program alerts to push-sender. The FAA is never called: the
// feed is the fixtures in _shared/fixtures (a real answer and the same shape with every program kind).
import { assertEquals } from "jsr:@std/assert@1";
import {
  fakeVerifier,
  loadIndexHandler,
  makeUser,
  test as baseTest,
  testDb,
  trackFlightId,
} from "../_shared/test_util.ts";
import type { ProgramAlert } from "../_shared/faa_nas.ts";
import {
  type Answer,
  CACHE_TTL_MS,
  handler,
  programMatters,
  sameAirport,
} from "./handler.ts";

const fixture = (name: string) =>
  Deno.readTextFileSync(
    new URL(`../_shared/fixtures/${name}`, import.meta.url),
  );
const PROGRAMS = fixture("nas_airport_events_programs.json");
const REAL = fixture("nas_airport_events_20261031.json");

// 31 October 2026, 20:10 UTC: the SFO program runs (16:00 to 03:59), the EWR ground stop runs
// (20:00 to 21:15), SBY reopened at 10:00.
const NOW = new Date("2026-10-31T20:10:00Z");
const at = (ms: number) => () => new Date(NOW.getTime() + ms);

const db = await testDb();

async function clear() {
  const r = await db.from("faa_status_cache").delete().eq("id", "nas");
  if (r.error) throw r.error;
}

function test(name: string, fn: () => Promise<void>) {
  baseTest(db, name, async () => {
    await clear();
    try {
      await fn();
    } finally {
      await clear();
    }
  });
}

/** A fake FAA: answers `body` (null: a 503) and counts the calls. */
function feed(body: string | null) {
  const f = {
    calls: 0,
    body,
    fn: (() => {
      f.calls++;
      return Promise.resolve(
        f.body === null
          ? new Response("down", { status: 503 })
          : new Response(f.body, {
            headers: { "content-type": "application/json" },
          }),
      );
    }) as typeof fetch,
  };
  return f;
}

function get(token: string | null, query: string): Request {
  return new Request(`http://localhost/faa-status?${query}`, {
    headers: token ? { authorization: `Bearer ${token}` } : {},
  });
}

async function ask(
  query: string,
  deps: Partial<Parameters<typeof handler>[1]> = {},
): Promise<{ status: number; body: Answer & { error?: { code: string } } }> {
  const user = await makeUser(db);
  const res = await handler(get(user, query), {
    db,
    verifier: fakeVerifier,
    now: at(0),
    ...deps,
  });
  return { status: res.status, body: await res.json() };
}

test("a US airport gets its programs, in plain words", async () => {
  const faa = feed(PROGRAMS);
  const { status, body } = await ask("airport=SFO", { fetchFn: faa.fn });
  assertEquals(status, 200);
  assertEquals(body.airport, "KSFO");
  assertEquals(body.iata, "SFO");
  assertEquals(body.available, true);
  assertEquals(body.stale, false);
  assertEquals(body.fetched_at, NOW.toISOString());
  assertEquals(
    body.programs.map((p) => [p.kind, p.average_minutes, p.reason]),
    [
      ["ground_delay", 47, "low clouds"],
    ],
  );
  const ewr = await ask("airport=KEWR", { fetchFn: faa.fn });
  assertEquals(ewr.body.programs.map((p) => [p.kind, p.extension]), [[
    "ground_stop",
    "medium",
  ]]);
  // A calm airport: available, nothing going on.
  const aus = await ask("airport=AUS", { fetchFn: faa.fn });
  assertEquals([aus.body.available, aus.body.programs], [true, []]);
  // One read for all three airports.
  assertEquals(faa.calls, 1);
});

test("conditions ride along at every airport; a failing summary never fails the answer", async () => {
  const faa = feed(PROGRAMS);
  const summary = {
    level: "minor" as const,
    summary: "Runway 09L/27R closed",
    reasons: [{
      source: "notam" as const,
      level: "minor" as const,
      text: "Runway 09L/27R closed",
      starts_at: null,
      ends_at: null,
    }],
    sources: { metar: true, taf: true, notam: true },
  };
  const seen: string[] = [];
  const conditions = (icao: string) => {
    seen.push(icao);
    return Promise.resolve(summary);
  };
  const cdg = await ask("airport=CDG", { fetchFn: faa.fn, conditions });
  assertEquals([cdg.body.available, cdg.body.conditions?.level], [
    false,
    "minor",
  ]);
  assertEquals(faa.calls, 0);
  const sfo = await ask("airport=SFO", { fetchFn: faa.fn, conditions });
  assertEquals([sfo.body.available, sfo.body.conditions?.summary], [
    true,
    "Runway 09L/27R closed",
  ]);
  assertEquals(seen, ["LFPG", "KSFO"]);
  const broken = await ask("airport=CDG", {
    fetchFn: faa.fn,
    conditions: () => Promise.reject(new Error("boom")),
  });
  assertEquals([broken.status, broken.body.conditions], [200, null]);
  // Without the dep the key is absent, as in every example file.
  const plain = await ask("airport=CDG", { fetchFn: faa.fn });
  assertEquals("conditions" in plain.body, false);
});

test("outside the US: not available, and the feed is not read", async () => {
  const faa = feed(PROGRAMS);
  const { status, body } = await ask("airport=CDG", { fetchFn: faa.fn });
  assertEquals(status, 200);
  assertEquals([body.available, body.reason, body.programs], [
    false,
    "outside_us",
    [],
  ]);
  assertEquals(faa.calls, 0);
});

test("the feed is shared for 5 minutes, then stale for 30 when the FAA is down", async () => {
  const faa = feed(PROGRAMS);
  await ask("airport=SFO", { fetchFn: faa.fn });
  await ask("airport=SFO", { fetchFn: faa.fn, now: at(CACHE_TTL_MS - 1000) });
  assertEquals(faa.calls, 1);

  faa.body = null;
  const stale = await ask("airport=SFO", {
    fetchFn: faa.fn,
    now: at(10 * 60_000),
  });
  assertEquals(faa.calls, 2);
  assertEquals(stale.status, 200);
  assertEquals(stale.body.stale, true);
  assertEquals(stale.body.fetched_at, NOW.toISOString());
  assertEquals(stale.body.programs.length, 1);

  const gone = await ask("airport=SFO", {
    fetchFn: faa.fn,
    now: at(31 * 60_000),
  });
  assertEquals(gone.status, 503);
  assertEquals(gone.body.error?.code, "provider_unavailable");
});

test("programs that ended since the read drop out of the cached feed", async () => {
  const faa = feed(PROGRAMS);
  assertEquals(
    (await ask("airport=EWR", {
      fetchFn: faa.fn,
      now: () => new Date("2026-10-31T21:00:00Z"),
    })).body.programs.length,
    1,
  );
  // The EWR ground stop ends at 21:15; the feed is down at 21:20, so the stale copy answers.
  faa.body = null;
  const later = await ask("airport=EWR", {
    fetchFn: faa.fn,
    now: () => new Date("2026-10-31T21:20:00Z"),
  });
  assertEquals([later.body.stale, later.body.programs], [true, []]);
});

test("the real answer: SBY closed at night, general aviation notices left out", async () => {
  const faa = feed(REAL);
  const night = () => new Date("2026-10-31T06:56:00Z");
  const sby = await ask("airport=SBY", { fetchFn: faa.fn, now: night });
  assertEquals(sby.body.programs.map((p) => [p.kind, p.ends_at]), [[
    "closure",
    "2026-10-31T10:00:00.000Z",
  ]]);
  const lax = await ask("airport=LAX", { fetchFn: faa.fn, now: night });
  assertEquals(lax.body.programs, []);
});

test("bad requests", async () => {
  assertEquals((await ask("airport=ZZZZ")).status, 400);
  assertEquals((await ask("airport=")).status, 400);
  const res = await handler(get("bad", "airport=SFO"), {
    db,
    verifier: fakeVerifier,
  });
  assertEquals(res.status, 401);
});

Deno.test("feed codes match IATA, or ICAO without the K", () => {
  assertEquals(
    sameAirport("SFO", { icao: "KSFO", iata: "SFO", country: "US" }),
    true,
  );
  assertEquals(
    sameAirport("X01", { icao: "KX01", iata: null, country: "US" }),
    true,
  );
  assertEquals(
    sameAirport("SFO", { icao: "KOAK", iata: "OAK", country: "US" }),
    false,
  );
});

Deno.test("a program matters at the moment it is about", () => {
  const f = {
    id: "x",
    origin_icao: "KLAX",
    destination_icao: "KSFO",
    scheduled_out: "2026-10-31T22:00:00Z",
    estimated_out: null,
    scheduled_in: "2026-10-31T23:30:00Z",
    estimated_in: null,
  };
  const p = {
    airport: "SFO",
    kind: "ground_stop" as const,
    reason: null,
    reason_raw: null,
    average_minutes: null,
    trend: null,
    extension: null,
    starts_at: "2026-10-31T20:00:00Z",
    ends_at: "2026-10-31T23:00:00Z",
    updated_at: null,
    advisory_url: null,
  };
  assertEquals(programMatters(p, "destination", f), true);
  // Over before the flight leaves.
  assertEquals(
    programMatters({ ...p, ends_at: "2026-10-31T21:30:00Z" }, "destination", f),
    false,
  );
  // A closure of the destination is about the arrival.
  const closure = {
    ...p,
    kind: "closure" as const,
    starts_at: "2026-10-31T23:00:00Z",
    ends_at: null,
  };
  assertEquals(programMatters(closure, "destination", f), true);
  assertEquals(programMatters(closure, "origin", f), false);
  // Arrival delays never matter at the origin.
  assertEquals(
    programMatters({ ...p, kind: "arrival_delay" }, "origin", f),
    false,
  );
});

// MARK: Sweep

const b64 = (o: object) =>
  btoa(JSON.stringify(o)).replace(/=+$/, "").replace(/\+/g, "-").replace(
    /\//g,
    "_",
  );
const SERVICE_KEY = `${b64({ alg: "HS256" })}.${
  b64({ role: "service_role" })
}.sig`;

async function makeFlight(over: Record<string, unknown> = {}) {
  const tag = crypto.randomUUID().slice(0, 8).toUpperCase();
  const { data, error } = await db.from("flights").insert({
    provider_id: `FAA${tag}-1793600000-schedule-1p`,
    ident: "UA1234",
    origin_icao: "KLAX",
    origin_iata: "LAX",
    destination_icao: "KSFO",
    destination_iata: "SFO",
    scheduled_out: "2026-10-31T22:00:00Z",
    scheduled_in: "2026-10-31T23:30:00Z",
    status: "scheduled",
    ...over,
  }).select("id").single();
  if (error) throw error;
  trackFlightId(data.id);
  return data.id as string;
}

async function follow(flightId: string, notify = true) {
  const u = await makeUser(db);
  const r = await db.from("user_flights").insert({
    user_id: u,
    flight_id: flightId,
    notify,
  });
  if (r.error) throw r.error;
}

/** Runs a sweep; the fake push claims in alert_log as push-sender does. */
async function sweep(faa = feed(PROGRAMS), now = at(0)) {
  const pushed: { flightId: string; program: ProgramAlert }[] = [];
  const res = await handler(
    new Request("http://localhost/faa-status?mode=sweep", {
      method: "POST",
      headers: { authorization: `Bearer ${SERVICE_KEY}` },
    }),
    {
      db,
      fetchFn: faa.fn,
      now,
      serviceKey: () => SERVICE_KEY,
      push: async (flightId, program) => {
        pushed.push({ flightId, program });
        const r = await db.from("alert_log").insert({
          flight_id: flightId,
          key: program.key,
          kind: "airport_program",
        });
        if (r.error) throw r.error;
      },
    },
  );
  return { status: res.status, out: await res.json(), pushed };
}

test("the sweep announces a program once to the flights it holds", async () => {
  const held = await makeFlight();
  await follow(held);
  // Not followed with alerts on, left already, or leaving after the EWR stop: nothing.
  const quiet = await makeFlight();
  await follow(quiet, false);
  const gone = await makeFlight({
    actual_out: "2026-10-31T20:00:00Z",
    status: "departed",
  });
  await follow(gone);
  const late = await makeFlight({
    origin_icao: "KBOS",
    origin_iata: "BOS",
    destination_icao: "KEWR",
    destination_iata: "EWR",
    scheduled_out: "2026-10-31T22:00:00Z",
  });
  await follow(late);

  const first = await sweep();
  assertEquals(first.status, 200);
  assertEquals(first.pushed, [{
    flightId: held,
    program: {
      key: "airport_program:KSFO:ground_delay:2026-10-31T16:00",
      kind: "ground_delay",
      end: "destination",
      code: "SFO",
      reason: "low clouds",
      average_minutes: 47,
      ends_at: "2026-11-01T03:59:00.000Z",
    },
  }]);
  assertEquals(first.out.sent, 1);
  assertEquals(first.out.programs, 2);

  // A later sweep (the program revised, same start) sends nothing again.
  const again = await sweep(feed(PROGRAMS), at(CACHE_TTL_MS + 1000));
  assertEquals(again.pushed, []);
});

test("the sweep is service role only and sends nothing from a stale feed", async () => {
  const user = await makeUser(db);
  const res = await handler(
    new Request("http://localhost/faa-status?mode=sweep", {
      method: "POST",
      headers: { authorization: `Bearer ${user}` },
    }),
    { db, serviceKey: () => SERVICE_KEY },
  );
  assertEquals(res.status, 401);

  const f = await makeFlight();
  await follow(f);
  await ask("airport=SFO", { fetchFn: feed(PROGRAMS).fn });
  const stale = await sweep(feed(null), at(10 * 60_000));
  assertEquals([stale.out.stale, stale.pushed], [true, []]);
});

test("the deployed entry point starts and answers", async () => {
  const serve = await loadIndexHandler(
    new URL("./index.ts", import.meta.url).href,
  );
  assertEquals((await serve(get(null, "airport=SFO"))).status, 401);
});

// MARK: Contract files: what SupabaseFAAService decodes in Swift

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
  const faa = feed(PROGRAMS);
  await checkContract(
    "ground_delay",
    (await ask("airport=SFO", { fetchFn: faa.fn })).body,
  );
  await checkContract(
    "ground_stop",
    (await ask("airport=EWR", { fetchFn: faa.fn })).body,
  );
  await checkContract(
    "departure_delay",
    (await ask("airport=LGA", { fetchFn: faa.fn })).body,
  );
  await checkContract(
    "arrival_delay",
    (await ask("airport=BOS", { fetchFn: faa.fn })).body,
  );
  await checkContract(
    "calm",
    (await ask("airport=AUS", { fetchFn: faa.fn })).body,
  );
  await checkContract(
    "not_available",
    (await ask("airport=CDG", { fetchFn: faa.fn })).body,
  );
  // A non-US airport: no program feed, but the conditions the rules read from notices and weather. The
  // summary here is a fixed example, so the file shows the wire shape (the rules have their own tests).
  const conditions = JSON.parse(`{
  "level": "major",
  "summary": "Thunderstorms nearby in the forecast",
  "reasons": [
    {
      "source": "forecast",
      "level": "major",
      "text": "Thunderstorms nearby in the forecast",
      "starts_at": "2026-10-31T22:00:00.000Z",
      "ends_at": "2026-11-01T02:00:00.000Z"
    },
    {
      "source": "notam",
      "level": "minor",
      "text": "Runway 09L/27R closed",
      "starts_at": "2026-10-31T00:00:00.000Z",
      "ends_at": "2026-10-31T23:00:00.000Z"
    },
    {
      "source": "forecast",
      "level": "minor",
      "text": "Strong winds in the forecast at times",
      "starts_at": "2026-11-01T02:00:00.000Z",
      "ends_at": "2026-11-01T07:00:00.000Z"
    }
  ],
  "sources": {
    "metar": true,
    "taf": true,
    "notam": true
  }
}`);
  await checkContract(
    "conditions_outside_us",
    (await ask("airport=CDG", {
      fetchFn: faa.fn,
      conditions: () => Promise.resolve(conditions),
    })).body,
  );
  await clear();
  await checkContract(
    "closure",
    (await ask("airport=SBY", {
      fetchFn: feed(REAL).fn,
      now: () => new Date("2026-10-31T06:56:00Z"),
    })).body,
  );
});
