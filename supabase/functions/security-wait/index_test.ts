import { assert, assertEquals } from "jsr:@std/assert@1";
import {
  fakeVerifier,
  loadIndexHandler,
  makeUser,
  test as baseTest,
  testDb,
} from "../_shared/test_util.ts";
import {
  type Answer,
  CACHE_TTL_MS,
  type Checkpoint,
  handler,
  type LiveProvider,
  THROUGHPUT_SOURCE,
  TYPICAL_SOURCE,
} from "./handler.ts";
import {
  loadAt,
  localTime,
  MAX_MINUTES,
  roundToFive,
  typicalWeek,
  waitForLoad,
  weekFromRows,
} from "./model.ts";

// Tuesday 3 November 2026, 07:30 in San Francisco (PST) and 09:30 in Austin (CST): the morning rush.
const NOW = new Date("2026-11-03T15:30:00Z");
const at = (ms: number) => () => new Date(NOW.getTime() + ms);

interface FixtureCheckpoint {
  id: string;
  name: string;
  terminal: string | null;
  precheck: boolean | null;
  hours: number[];
}
const fixture: {
  airport: string;
  weekdays: number[];
  checkpoints: FixtureCheckpoint[];
} = JSON.parse(
  Deno.readTextFileSync(
    new URL(
      "../_shared/fixtures/security_throughput_ksfo.json",
      import.meta.url,
    ),
  ),
);

const db = await testDb();
/** Airports whose cached answers and checkpoints every test clears, before and after. */
const TOUCHED = ["KSFO", "KAUS", "LFPG", "KJFK"];

async function clear() {
  for (const t of ["security_wait_cache", "security_checkpoints"]) {
    const r = await db.from(t).delete().in("airport_icao", TOUCHED);
    if (r.error) throw r.error;
  }
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

/** Loads the fixture's checkpoints and their typical week into the tables for KSFO. */
async function seedKsfo() {
  const cps = await db.from("security_checkpoints").insert(
    fixture.checkpoints.map((c) => ({
      airport_icao: fixture.airport,
      id: c.id,
      name: c.name,
      terminal: c.terminal,
      precheck: c.precheck,
    })),
  );
  if (cps.error) throw cps.error;
  const rows = fixture.checkpoints.flatMap((c) =>
    fixture.weekdays.flatMap((f, weekday) =>
      c.hours.map((p, hour) => ({
        airport_icao: fixture.airport,
        checkpoint_id: c.id,
        weekday,
        hour,
        passengers: Math.round(p * f),
      }))
    )
  );
  const r = await db.from("security_throughput").insert(rows);
  if (r.error) throw r.error;
}

function get(token: string | null, query: string): Request {
  return new Request(`http://localhost/security-wait?${query}`, {
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
    live: [],
    ...deps,
  });
  return { status: res.status, body: await res.json() };
}

/** A live source for SFO that answers `checkpoints`, or throws when given an error. */
function fakeLive(
  checkpoints: Checkpoint[] | Error,
  calls: string[] = [],
): LiveProvider {
  return {
    source: {
      id: "test_live",
      name: "Test airport feed",
      url: "https://example.test/waits",
    },
    covers: (icao) => icao === "KSFO",
    fetch(icao) {
      calls.push(icao);
      return checkpoints instanceof Error
        ? Promise.reject(checkpoints)
        : Promise.resolve(checkpoints);
    },
  };
}

// MARK: The model

Deno.test("waits round to five minutes and grow with the load", () => {
  assertEquals([0, 2, 2.4, 2.5, 7.4, 7.6, 31].map(roundToFive), [
    5,
    5,
    5,
    5,
    5,
    10,
    30,
  ]);
  assertEquals(waitForLoad(0), { standard: 5, precheck: 5 });
  assertEquals(waitForLoad(1).standard, roundToFive(MAX_MINUTES));
  assertEquals(waitForLoad(1), { standard: 30, precheck: 10 });
  // Out of range or nonsense loads are clamped.
  assertEquals(waitForLoad(4), waitForLoad(1));
  assertEquals(waitForLoad(-1), waitForLoad(0));
  assertEquals(waitForLoad(Number.NaN), waitForLoad(0));
  let last = 0;
  for (let l = 0; l <= 1; l += 0.05) {
    const w = waitForLoad(l);
    assert(w.standard >= last, `standard never drops (load ${l})`);
    assert(w.precheck <= w.standard, "PreCheck is never longer");
    last = w.standard;
  }
});

Deno.test("local time follows the airport's clock", () => {
  assertEquals(localTime(NOW, "America/Los_Angeles"), {
    weekday: 2,
    hour: 7,
    minute: 30,
  });
  assertEquals(localTime(NOW, "America/Chicago").hour, 9);
  // Saturday 23:30 in Los Angeles is Sunday in UTC.
  assertEquals(
    localTime(new Date("2026-11-08T07:30:00Z"), "America/Los_Angeles"),
    { weekday: 6, hour: 23, minute: 30 },
  );
  assertEquals(localTime(NOW, null), { weekday: 2, hour: 15, minute: 30 });
});

Deno.test("the load blends the hour with the next, against the week's peak", () => {
  const week = weekFromRows([
    { weekday: 2, hour: 7, passengers: 400 },
    { weekday: 2, hour: 8, passengers: 800 },
    { weekday: 0, hour: 6, passengers: 1000 },
    // Out of range rows are ignored.
    { weekday: 9, hour: 7, passengers: 5000 },
  ]);
  assertEquals(loadAt(week, { weekday: 2, hour: 7, minute: 0 }), 0.4);
  assertEquals(loadAt(week, { weekday: 2, hour: 7, minute: 30 }), 0.6);
  // Saturday 23:00 blends into Sunday 00:00.
  assertEquals(loadAt(week, { weekday: 6, hour: 23, minute: 30 }), 0);
  assertEquals(loadAt(weekFromRows([]), { weekday: 0, hour: 0, minute: 0 }), 0);
  // The typical week peaks on Sunday at 06:00.
  assertEquals(loadAt(typicalWeek(), { weekday: 0, hour: 6, minute: 0 }), 1);
});

// MARK: Answers

test("an airport with throughput answers an estimate per checkpoint", async () => {
  await seedKsfo();
  const { status, body } = await ask("airport=sfo");
  assertEquals(status, 200);
  assertEquals(body.airport, "KSFO");
  assertEquals(body.iata, "SFO");
  assertEquals(body.available, true);
  assertEquals(body.live, false);
  assertEquals(body.source, THROUGHPUT_SOURCE);
  assertEquals(body.fetched_at, NOW.toISOString());
  // The closed checkpoint has no traffic on record and is left out; sorted by terminal then name.
  assertEquals(body.checkpoints.map((c) => c.id), [
    "t1",
    "t2",
    "t3-e",
    "t3-f",
    "intl-g",
  ]);
  const t3f = body.checkpoints.find((c) => c.id === "t3-f")!;
  // Tuesday 07:30: (1150 + 900) / 2 * 0.8 against the Sunday 06:00 peak of 1350.
  const load = ((1150 + 900) / 2 * 0.8) / 1350;
  assertEquals(t3f.standard_minutes, waitForLoad(load).standard);
  assertEquals(t3f.precheck_minutes, waitForLoad(load).precheck);
  assertEquals(t3f.terminal, "3");
  assertEquals(t3f.precheck, true);
  // No PreCheck lanes: no PreCheck figure.
  const t3e = body.checkpoints.find((c) => c.id === "t3-e")!;
  assertEquals(t3e.precheck, false);
  assertEquals(t3e.precheck_minutes, null);
  assert(t3e.standard_minutes! >= 5);
});

test("an airport with no throughput answers a typical day", async () => {
  const { status, body } = await ask("airport=KAUS");
  assertEquals(status, 200);
  assertEquals(body.available, true);
  assertEquals(body.live, false);
  assertEquals(body.source, TYPICAL_SOURCE);
  // Tuesday 09:30 in Austin: halfway from 0.6 to 0.6, times Tuesday's 0.8.
  const w = waitForLoad(0.6 * 0.8);
  assertEquals(body.checkpoints, [{
    id: "all",
    name: "All checkpoints",
    terminal: null,
    precheck: null,
    standard_minutes: w.standard,
    precheck_minutes: w.precheck,
  }]);
});

test("airports outside the US are not available", async () => {
  const { status, body } = await ask("airport=CDG");
  assertEquals(status, 200);
  assertEquals(body.airport, "LFPG");
  assertEquals(body.available, false);
  assertEquals(body.reason, "outside_us");
  assertEquals(body.live, false);
  assertEquals(body.source, null);
  assertEquals(body.checkpoints, []);
});

test("unknown and malformed airports are refused", async () => {
  assertEquals((await ask("airport=ZZZ")).status, 400);
  assertEquals((await ask("airport=S F")).status, 400);
  const missing = await ask("");
  assertEquals(missing.status, 400);
  assertEquals(missing.body.error?.code, "invalid_request");
});

test("a live source wins, and its figures are kept sane", async () => {
  await seedKsfo();
  const calls: string[] = [];
  const live = fakeLive([
    {
      id: "b",
      name: "Checkpoint B",
      terminal: "1",
      precheck: true,
      standard_minutes: 12.4,
      precheck_minutes: 3,
    },
    {
      id: "a",
      name: "Checkpoint A",
      terminal: "1",
      precheck: false,
      standard_minutes: 7,
      precheck_minutes: null,
    },
    // No usable standard figure: left out.
    {
      id: "x",
      name: "Broken",
      terminal: null,
      precheck: null,
      standard_minutes: -4,
      precheck_minutes: 9999,
    },
  ], calls);
  const { body } = await ask("airport=SFO", { live: [live] });
  assertEquals(calls, ["KSFO"]);
  assertEquals(body.live, true);
  assertEquals(body.source?.id, "test_live");
  assertEquals(body.checkpoints.map((c) => [c.id, c.standard_minutes]), [
    ["a", 7],
    ["b", 12],
  ]);
  // Other airports never ask it.
  const aus = await ask("airport=AUS", { live: [live] });
  assertEquals(calls, ["KSFO"]);
  assertEquals(aus.body.live, false);
});

test("a failing or empty live source falls back to the estimate", async () => {
  await seedKsfo();
  const down = await ask("airport=SFO", {
    live: [fakeLive(new Error("down"))],
  });
  assertEquals(down.status, 200);
  assertEquals(down.body.live, false);
  assertEquals(down.body.source, THROUGHPUT_SOURCE);
  await db.from("security_wait_cache").delete().eq("airport_icao", "KSFO");
  const empty = await ask("airport=SFO", { live: [fakeLive([])] });
  assertEquals(empty.body.live, false);
  assertEquals(empty.body.checkpoints.length, 5);
});

test("answers are cached for a few minutes per airport", async () => {
  const calls: string[] = [];
  const live = fakeLive([{
    id: "a",
    name: "Checkpoint A",
    terminal: null,
    precheck: null,
    standard_minutes: 10,
    precheck_minutes: 5,
  }], calls);
  const first = await ask("airport=SFO", { live: [live] });
  const again = await ask("airport=KSFO", {
    live: [live],
    now: at(CACHE_TTL_MS - 1000),
  });
  assertEquals(calls.length, 1);
  assertEquals(again.body, first.body);
  const later = await ask("airport=SFO", {
    live: [live],
    now: at(CACHE_TTL_MS + 1000),
  });
  assertEquals(calls.length, 2);
  assertEquals(later.body.fetched_at, at(CACHE_TTL_MS + 1000)().toISOString());
});

test("callers must sign in, use GET and stay under the rate limit", async () => {
  const deps = { db, verifier: fakeVerifier, now: at(0), live: [] };
  assertEquals((await handler(get(null, "airport=SFO"), deps)).status, 401);
  const user = await makeUser(db);
  const post = new Request("http://localhost/security-wait?airport=SFO", {
    method: "POST",
    headers: { authorization: `Bearer ${user}` },
  });
  assertEquals((await handler(post, deps)).status, 405);
  const { data, error } = await db.rpc("check_rate", {
    p_user: user,
    p_endpoint: "security-wait",
    p_max: 120,
    p_window_minutes: 60,
  });
  assertEquals([data, error], [true, null]);
  for (let i = 0; i < 119; i++) {
    await db.rpc("check_rate", {
      p_user: user,
      p_endpoint: "security-wait",
      p_max: 120,
      p_window_minutes: 60,
    });
  }
  const res = await handler(get(user, "airport=SFO"), deps);
  assertEquals(res.status, 429);
});

test("the deployed entry point starts and answers", async () => {
  const serve = await loadIndexHandler(
    new URL("./index.ts", import.meta.url).href,
  );
  // No token: refused before any work.
  assertEquals((await serve(get(null, "airport=SFO"))).status, 401);
});

// MARK: Contract files: what SupabaseSecurityWaitService decodes in Swift

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
  await seedKsfo();
  await checkContract("estimate", (await ask("airport=SFO")).body);
  await checkContract("typical", (await ask("airport=AUS")).body);
  await checkContract("not_available", (await ask("airport=CDG")).body);
  await db.from("security_wait_cache").delete().eq("airport_icao", "KSFO");
  const live = fakeLive([
    {
      id: "t1",
      name: "Harvey Milk Terminal 1",
      terminal: "1",
      precheck: true,
      standard_minutes: 14,
      precheck_minutes: 4,
    },
    {
      id: "intl-g",
      name: "International G",
      terminal: "International",
      precheck: true,
      standard_minutes: 22,
      precheck_minutes: 8,
    },
  ]);
  await checkContract(
    "live",
    (await ask("airport=SFO", { live: [live] })).body,
  );
});
