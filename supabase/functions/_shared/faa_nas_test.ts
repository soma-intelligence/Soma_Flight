import { assertEquals, assertRejects, assertThrows } from "jsr:@std/assert@1";
import {
  fetchNas,
  mattersAt,
  NAS_URL,
  NAS_USER_AGENT,
  parseAirportEvents,
  plainReason,
  programKey,
  readProgramAlert,
} from "./faa_nas.ts";

const fixture = (name: string) =>
  JSON.parse(
    Deno.readTextFileSync(new URL(`./fixtures/${name}`, import.meta.url)),
  );
// A real answer, fetched on 31 October 2026 at 06:56 UTC: one full closure (SBY) and three free-form
// restrictions to general aviation (LAS, LAX, SAN).
const REAL = fixture("nas_airport_events_20261031.json");
// The same shape with every program kind: SFO ground delay program, EWR ground stop, LGA departure
// delays, BOS arrival delays, ORD deicing, plus the real SBY and LAS entries. The program objects
// follow the field names of the FAA status page's own code; no program was active when the real
// answer was fetched.
const PROGRAMS = fixture("nas_airport_events_programs.json");

const NIGHT = new Date("2026-10-31T06:56:00Z");
const AFTERNOON = new Date("2026-10-31T20:10:00Z");

Deno.test("the real answer: the SBY closure counts, general aviation restrictions do not", () => {
  const ps = parseAirportEvents(REAL, NIGHT);
  assertEquals(ps, [{
    airport: "SBY",
    kind: "closure",
    reason: null,
    reason_raw: null,
    average_minutes: null,
    trend: null,
    extension: null,
    starts_at: "2026-10-31T03:00:00.000Z",
    ends_at: "2026-10-31T10:00:00.000Z",
    updated_at: "2026-10-31T02:07:28.000Z",
    advisory_url: null,
  }]);
});

Deno.test("every program kind, most serious first, in plain words", () => {
  const ps = parseAirportEvents(PROGRAMS, AFTERNOON);
  // SBY reopened at 10:00, so it is gone by the afternoon.
  assertEquals(ps.map((p) => `${p.kind}:${p.airport}`), [
    "ground_stop:EWR",
    "ground_delay:SFO",
    "departure_delay:LGA",
    "arrival_delay:BOS",
    "deicing:ORD",
  ]);
  const [gs, gdp, dep, arr, ice] = ps;
  assertEquals(gs.reason, "thunderstorms");
  assertEquals(gs.extension, "medium");
  assertEquals(gs.ends_at, "2026-10-31T21:15:00.000Z");
  assertEquals(
    gs.advisory_url?.startsWith("https://www.fly.faa.gov/adv/"),
    true,
  );
  assertEquals(gdp.reason, "low clouds");
  assertEquals(gdp.reason_raw, "WEATHER / LOW CEILINGS");
  assertEquals(gdp.average_minutes, 47);
  assertEquals(gdp.starts_at, "2026-10-31T16:00:00.000Z");
  assertEquals(dep.reason, "heavy traffic");
  assertEquals(dep.trend, "increasing");
  assertEquals(dep.average_minutes, 31);
  assertEquals(arr.reason, "strong wind");
  assertEquals(arr.trend, "decreasing");
  assertEquals(ice.starts_at, "2026-10-31T11:20:00.000Z");
});

Deno.test("odd entries are skipped, a non-list answer throws", () => {
  assertEquals(
    parseAirportEvents([
      null,
      "SFO",
      { airportId: "not a code" },
      { airportId: "JFK", groundDelay: { avgDelay: "nope" } },
      { airportId: "BOS", departureDelay: { averageDelay: "25", trend: "" } },
    ], NIGHT).map((p) => [p.kind, p.airport, p.average_minutes, p.trend]),
    [["ground_delay", "JFK", null, null], [
      "departure_delay",
      "BOS",
      25,
      null,
    ]],
  );
  assertThrows(() => parseAirportEvents({ error: "down" }, NIGHT));
});

Deno.test("plain reasons", () => {
  assertEquals(plainReason("WEATHER / THUNDERSTORMS"), "thunderstorms");
  assertEquals(plainReason("WEATHER / LOW CEILINGS"), "low clouds");
  assertEquals(plainReason("WEATHER / FOG"), "low visibility");
  assertEquals(plainReason("VOLUME / VOLUME"), "heavy traffic");
  assertEquals(plainReason("TM Initiatives:MIT:VOL"), "heavy traffic");
  assertEquals(
    plainReason("RWY-TAXI / CONSTRUCTION"),
    "runway or taxiway work",
  );
  assertEquals(plainReason("EQUIPMENT / OUTAGE"), "an equipment outage");
  assertEquals(plainReason("OTHER / VIP MOVEMENT"), "a VIP movement");
  assertEquals(
    plainReason("RUNWAY / RUNWAY CONFIGURATION"),
    "the runways in use",
  );
  assertEquals(plainReason("OTHER / AIRSHOW"), "airshow");
  assertEquals(plainReason("OTHER / OTHER"), null);
  assertEquals(plainReason(""), null);
  assertEquals(plainReason(null), null);
});

Deno.test("which end a program matters at", () => {
  assertEquals(mattersAt("departure_delay", "origin"), true);
  assertEquals(mattersAt("departure_delay", "destination"), false);
  assertEquals(mattersAt("arrival_delay", "destination"), true);
  assertEquals(mattersAt("arrival_delay", "origin"), false);
  assertEquals(mattersAt("deicing", "destination"), false);
  for (const k of ["closure", "ground_stop", "ground_delay"] as const) {
    assertEquals(mattersAt(k, "origin"), true);
    assertEquals(mattersAt(k, "destination"), true);
  }
});

Deno.test("alert keys follow the program's start, not its revisions", () => {
  const [, gdp] = parseAirportEvents(PROGRAMS, AFTERNOON);
  const key = programKey("KSFO", gdp);
  assertEquals(key, "airport_program:KSFO:ground_delay:2026-10-31T16:00");
  assertEquals(
    programKey("KSFO", {
      ...gdp,
      average_minutes: 90,
      ends_at: "2026-11-01T06:00:00Z",
    }),
    key,
  );
  assertEquals(
    programKey("KSFO", { ...gdp, starts_at: null }),
    "airport_program:KSFO:ground_delay:open",
  );
});

Deno.test("program alerts from the network are checked", () => {
  const good = {
    key: "airport_program:KSFO:ground_delay:2026-10-31T16:00",
    kind: "ground_delay",
    end: "destination",
    code: "SFO",
    reason: "low clouds",
    average_minutes: 47,
    ends_at: "2026-11-01T03:59:00Z",
  };
  assertEquals(readProgramAlert(good), {
    ...good,
    kind: "ground_delay",
    end: "destination",
    ends_at: "2026-11-01T03:59:00.000Z",
  });
  assertEquals(readProgramAlert({ ...good, kind: "deicing" }), null);
  assertEquals(readProgramAlert({ ...good, key: "takeoff" }), null);
  assertEquals(readProgramAlert({ ...good, end: "middle" }), null);
  assertEquals(readProgramAlert({ ...good, code: "sf o" }), null);
  assertEquals(readProgramAlert(null), null);
});

Deno.test("fetchNas asks the public feed and fails loudly", async () => {
  const seen: { url: string; ua: string | null }[] = [];
  const ok = ((input: string | URL | Request, init?: RequestInit) => {
    seen.push({
      url: String(input),
      ua: new Headers(init?.headers).get("user-agent"),
    });
    return Promise.resolve(new Response(JSON.stringify(PROGRAMS)));
  }) as typeof fetch;
  assertEquals((await fetchNas(ok, AFTERNOON)).length, 5);
  assertEquals(seen, [{ url: NAS_URL, ua: NAS_USER_AGENT }]);

  const down =
    (() =>
      Promise.resolve(new Response("busy", { status: 503 }))) as typeof fetch;
  await assertRejects(() => fetchNas(down, AFTERNOON));
  const html =
    (() => Promise.resolve(new Response("<html></html>"))) as typeof fetch;
  await assertRejects(() => fetchNas(html, AFTERNOON));
});
