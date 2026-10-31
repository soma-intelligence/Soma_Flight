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
import { localTime, rounded, typicalWeek, waitAt, weekWaits } from "./model.ts";

// Tuesday 3 November 2026, 07:30 in San Francisco (PST) and 09:30 in Austin (CST): the morning rush.
const NOW = new Date("2026-11-03T15:30:00Z");
const at = (ms: number) => () => new Date(NOW.getTime() + ms);

interface FixtureCheckpoint {
  id: string;
  name: string;
  terminal: string | null;
  precheck: boolean | null;
  /** [weekday][hour] median passengers, Sunday first. */
  week: number[][];
}
/** Real aggregated TSA rows for SFO (supabase/scripts/import_tsa_throughput.py --fixture SFO). */
const fixture: {
  airport: string;
  checkpoints: FixtureCheckpoint[];
} = JSON.parse(
  Deno.readTextFileSync(
    new URL(
      "../_shared/fixtures/security_throughput_ksfo.json",
      import.meta.url,
    ),
  ),
);
/** SFO's checkpoints in the order the answer lists them: by terminal, then name. */
const SFO_ORDER = [
  "security-checkpoint-b",
  "security-checkpoint-t1-b-mezzanine",
  "security-checkpoint-d",
  "security-checkpoint-f-1",
  "security-checkpoint-a",
  "security-checkpoint-g",
];

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

/**
 * Loads the fixture's checkpoints and their typical week into the tables for KSFO, plus a checkpoint
 * with no traffic on record (test-only, as a closed checkpoint would be). `precheck` overrides a
 * checkpoint's PreCheck flag by id.
 */
async function seedKsfo(precheck: Record<string, boolean> = {}) {
  const cps = await db.from("security_checkpoints").insert([
    ...fixture.checkpoints.map((c) => ({
      airport_icao: fixture.airport,
      id: c.id,
      name: c.name,
      terminal: c.terminal,
      precheck: precheck[c.id] ?? c.precheck,
    })),
    {
      airport_icao: fixture.airport,
      id: "closed",
      name: "Closed checkpoint",
      terminal: "1",
      precheck: null,
    },
  ]);
  if (cps.error) throw cps.error;
  const rows = fixture.checkpoints.flatMap((c) =>
    c.week.flatMap((hours, weekday) =>
      hours.flatMap((passengers, hour) =>
        passengers > 0
          ? [{
            airport_icao: fixture.airport,
            checkpoint_id: c.id,
            weekday,
            hour,
            passengers,
          }]
          : []
      )
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

// MARK: Answers

test("an airport with throughput answers an estimate per checkpoint", async () => {
  await seedKsfo({ "security-checkpoint-d": false });
  // Pages of 100 rows: SFO's ~850 rows take several, as a large hub's take several of 1,000.
  const { status, body } = await ask("airport=sfo", { pageSize: 100 });
  assertEquals(status, 200);
  assertEquals(body.airport, "KSFO");
  assertEquals(body.iata, "SFO");
  assertEquals(body.available, true);
  assertEquals(body.live, false);
  assertEquals(body.source, THROUGHPUT_SOURCE);
  assertEquals(body.fetched_at, NOW.toISOString());
  // The closed checkpoint has no traffic on record and is left out; sorted by terminal then name.
  assertEquals(body.checkpoints.map((c) => c.id), SFO_ORDER);
  // Tuesday 07:30 in San Francisco, through the queue model on Terminal 3's real week.
  const f1 = body.checkpoints.find((c) => c.id === "security-checkpoint-f-1")!;
  const week = fixture.checkpoints.find((c) => c.id === f1.id)!.week;
  const expected = rounded(
    waitAt(weekWaits(week), localTime(NOW, "America/Los_Angeles")),
  );
  assertEquals(f1.standard_minutes, expected.standard);
  assertEquals(f1.precheck_minutes, expected.precheck);
  assertEquals(f1.name, "Security Checkpoint F-1");
  assertEquals(f1.terminal, "3");
  // The report does not say which checkpoints have PreCheck: unknown, and a figure is still given.
  assertEquals(f1.precheck, null);
  assert(f1.precheck_minutes! >= 5);
  // No PreCheck lanes: no PreCheck figure.
  const d = body.checkpoints.find((c) => c.id === "security-checkpoint-d")!;
  assertEquals(d.precheck, false);
  assertEquals(d.precheck_minutes, null);
  assert(d.standard_minutes! >= 5);
  // Every figure is a believable estimate: 5 to 30 minutes, in steps of 5.
  for (const c of body.checkpoints) {
    assert(
      c.standard_minutes! >= 5 && c.standard_minutes! <= 30 &&
        c.standard_minutes! % 5 === 0,
      `${c.id}: ${c.standard_minutes}`,
    );
  }
});

Deno.test("the real SFO week gives believable waits through the day", () => {
  // Queue-model plausibility on real rows (no database): the morning rush waits longer than the
  // afternoon at Terminal 3, and no hour of the week passes 30 minutes at any checkpoint.
  const f1 = fixture.checkpoints.find((c) =>
    c.id === "security-checkpoint-f-1"
  )!;
  const w = weekWaits(f1.week);
  const tuesday = (h: number) => rounded(w[2][h]).standard;
  assert(tuesday(7) > tuesday(15), `${tuesday(7)} vs ${tuesday(15)}`);
  for (const c of fixture.checkpoints) {
    assert(weekWaits(c.week).flat().every((m) => rounded(m).standard <= 30));
  }
});

test("an airport with no throughput answers a typical day", async () => {
  const { status, body } = await ask("airport=KAUS");
  assertEquals(status, 200);
  assertEquals(body.available, true);
  assertEquals(body.live, false);
  assertEquals(body.source, TYPICAL_SOURCE);
  // Tuesday 09:30 in Austin, on the typical US week.
  const w = rounded(
    waitAt(weekWaits(typicalWeek()), localTime(NOW, "America/Chicago")),
  );
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
  assertEquals(empty.body.checkpoints.length, SFO_ORDER.length);
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
      id: "security-checkpoint-b",
      name: "Security Checkpoint B",
      terminal: "1",
      precheck: true,
      standard_minutes: 14,
      precheck_minutes: 4,
    },
    {
      id: "security-checkpoint-g",
      name: "Security Checkpoint G",
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
