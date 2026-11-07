import { assertEquals, assertRejects, assertThrows } from "jsr:@std/assert@1";
import {
  credentialsFromEnv,
  decodeNotam,
  fetchNotams,
  NOTAM_URL,
  noticeBody,
  parseNotamApi,
} from "./notam.ts";

const API = JSON.parse(
  Deno.readTextFileSync(
    new URL("./fixtures/notam_api_ksfo.json", import.meta.url),
  ),
);
// 31 October 2026, 08:00 UTC (01:00 in San Francisco).
const NOW = new Date("2026-10-31T08:00:00Z");

const d = (text: string) => {
  const x = decodeNotam(text);
  return [x.kind, x.title, x.detail, x.relevance];
};

Deno.test("notice bodies: domestic, bare and ICAO", () => {
  assertEquals(
    noticeBody("!SFO 10/101 SFO RWY 10L/28R CLSD 2610310500-2610311300"),
    "RWY 10L/28R CLSD",
  );
  assertEquals(
    noticeBody("!SFO 10/103 SFO TWY C CLSD 2610300800-2611152359EST"),
    "TWY C CLSD",
  );
  assertEquals(
    noticeBody("!LAX 05/277 LAX AD AP CLSD TO NON SKED 2605271826-PERM"),
    "AD AP CLSD TO NON SKED",
  );
  assertEquals(
    noticeBody(
      "A1234/26 NOTAMN Q) EGTT/QMRLC/IV/NBO/A/000/999/5129N00028W005 A) EGLL B) 2610300000 C) 2610310500 E) RWY 09L/27R CLSD DUE WIP.",
    ),
    "RWY 09L/27R CLSD DUE WIP",
  );
  assertEquals(noticeBody("rwy 10l/28r clsd"), "RWY 10L/28R CLSD");
});

Deno.test("airport closures, from real notices", () => {
  // Real: Salisbury, 31 October 2026 (nasstatus fixture).
  assertEquals(d("!SBY 10/069 SBY AD AP CLSD 2610310300-2610311000"), [
    "airport_closed",
    "Airport closed",
    null,
    100,
  ]);
  // Real: Los Angeles and San Diego, closed to general aviation only.
  assertEquals(
    d(
      "!LAX 05/277 LAX AD AP CLSD TO NON SKED TRANSIENT GA ACFT EXC 24HR PPR CTC ATLANTIC AVIATION 310-258-9884 OR SIGNATURE AVIATION 310-410-9605 2605271826-2705281600",
    ),
    [
      "airport_closed",
      "Closed to private and charter flights",
      "Airline flights are not affected.",
      2,
    ],
  );
  assertEquals(
    d("!SAN 10/004 SAN AD AP CLSD TO NON SKED TRANSIENT GA ACFT EXC PPR 619-298-7704 2610011633-2701010800")[
      1
    ],
    "Closed to private and charter flights",
  );
  assertEquals(
    d("AD AP CLSD EXC MEDEVAC")[1],
    "Airport closed, with exceptions",
  );
});

Deno.test("runways", () => {
  assertEquals(d("RWY 10L/28R CLSD"), [
    "runway_closed",
    "Runway 10L/28R closed",
    null,
    80,
  ]);
  assertEquals(d("RWY 01R/19L CLSD EXC XNG"), [
    "runway_closed",
    "Runway 01R/19L closed in part",
    null,
    50,
  ]);
  assertEquals(d("E) RWY 09L/27R CLSD DUE WIP."), [
    "runway_closed",
    "Runway 09L/27R closed",
    "For construction work.",
    80,
  ]);
  assertEquals(d("RWY 4 CLSD")[1], "Runway 4 closed");
});

Deno.test("taxiways", () => {
  assertEquals(d("TWY C BTN TWY A AND TWY B CLSD"), [
    "taxiway_closed",
    "Taxiway C closed in part",
    "Between A and B.",
    25,
  ]);
  assertEquals(d("TWY F CLSD")[1], "Taxiway F closed");
  assertEquals(d("TWY A, B AND K CLSD")[1], "Taxiways A, B and K closed");
});

Deno.test("instrument landing systems", () => {
  assertEquals(d("NAV ILS RWY 28L GP U/S"), [
    "ils_out",
    "ILS glide slope for runway 28L out of service",
    "Landings in low cloud or fog may be slower.",
    60,
  ]);
  assertEquals(
    d("NAV ILS RWY 04R LOC U/S")[1],
    "ILS localizer for runway 04R out of service",
  );
  assertEquals(d("NAV ILS RWY 31 U/S")[1], "ILS for runway 31 out of service");
  assertEquals(
    d("ILS RWY 22L DME OTS")[1],
    "ILS distance equipment for runway 22L out of service",
  );
});

Deno.test("unlit obstacles", () => {
  assertEquals(
    d("OBST TOWER LGT (ASR 1234567) 373712.00N1222248.00W (1.6NM NW SFO) 412FT (296FT AGL) U/S"),
    [
      "obstacle_light",
      "Unlit tower",
      "1.6 NM NW of the airport, 296 ft tall.",
      5,
    ],
  );
  assertEquals(d("OBST CRANE LGT U/S"), [
    "obstacle_light",
    "Unlit crane",
    null,
    5,
  ]);
});

Deno.test("construction", () => {
  assertEquals(d("APRON TERMINAL 2 RAMP WIP"), [
    "construction",
    "Construction on the apron",
    null,
    20,
  ]);
  assertEquals(
    d("RWY 16L/34R WIP 200FT N OF THR")[1],
    "Construction on runway 16L/34R",
  );
  assertEquals(d("RWY 16L/34R WIP 200FT N OF THR")[3], 35);
  assertEquals(
    d("OBST CRANE 1.2NM SE AP 250FT AGL")[2],
    "Cranes are up near the field.",
  );
});

Deno.test("everything else is other", () => {
  for (
    const t of ["SVC TWR OPN 0600-2300", "COM ATIS FREQ 118.85 U/S", "BIRD ACT"]
  ) {
    assertEquals(decodeNotam(t).kind, "other");
  }
});

Deno.test("an API answer: decoded, in effect or soon, ranked, raw kept", () => {
  const ns = parseNotamApi(API, NOW);
  assertEquals(ns.map((n) => [n.number, n.kind, n.relevance]), [
    ["10/101", "runway_closed", 80],
    ["10/104", "ils_out", 60],
    ["10/102", "runway_closed", 50],
    ["10/103", "taxiway_closed", 25],
    ["10/107", "construction", 20],
    ["10/105", "obstacle_light", 5],
    ["10/106", "airport_closed", 2],
  ]);
  const [first] = ns;
  assertEquals(
    first.raw,
    "!SFO 10/101 SFO RWY 10L/28R CLSD 2610310500-2610311300",
  );
  assertEquals(first.starts_at, "2026-10-31T05:00:00.000Z");
  assertEquals(first.ends_at, "2026-10-31T13:00:00.000Z");
  const twy = ns.find((n) => n.number === "10/103")!;
  assertEquals(twy.ends_estimated, true);
  const perm = ns.find((n) => n.number === "10/106")!;
  assertEquals(perm.ends_at, null);
  assertThrows(() => parseNotamApi({ message: "error" }, NOW));
});

Deno.test("credentials come from the env, both or nothing", () => {
  const env = (o: Record<string, string>) => (n: string) => o[n];
  assertEquals(credentialsFromEnv(env({})), undefined);
  assertEquals(
    credentialsFromEnv(env({ FAA_NOTAM_CLIENT_ID: "id" })),
    undefined,
  );
  assertEquals(
    credentialsFromEnv(
      env({ FAA_NOTAM_CLIENT_ID: "id", FAA_NOTAM_CLIENT_SECRET: " s " }),
    ),
    { clientId: "id", clientSecret: "s", url: NOTAM_URL },
  );
});

Deno.test("fetchNotams sends the key in headers, never in the URL", async () => {
  const seen: { url: string; id: string | null; secret: string | null }[] = [];
  const ok = ((input: string | URL | Request, init?: RequestInit) => {
    const h = new Headers(init?.headers);
    seen.push({
      url: String(input),
      id: h.get("client_id"),
      secret: h.get("client_secret"),
    });
    return Promise.resolve(new Response(JSON.stringify(API)));
  }) as typeof fetch;
  const creds = { clientId: "id-1", clientSecret: "secret-1", url: NOTAM_URL };
  assertEquals((await fetchNotams(creds, "KSFO", ok, NOW)).length, 7);
  assertEquals(seen, [{
    url: `${NOTAM_URL}?icaoLocation=KSFO&pageSize=1000`,
    id: "id-1",
    secret: "secret-1",
  }]);
  const refused =
    (() =>
      Promise.resolve(new Response("no", { status: 401 }))) as typeof fetch;
  await assertRejects(() => fetchNotams(creds, "KSFO", refused, NOW));
});

Deno.test("international notices: ICAO wording for closures and instrument landing systems", () => {
  const icao = (e: string) =>
    `A1234/26 NOTAMN Q) LFFF/QMRLC/IV/NBO/A/000/999/4900N00232E005 A) LFPG B) 2610300000 C) 2610310500 E) ${e}`;
  assertEquals(d(icao("RWY 09L/27R CLOSED DUE WIP")), [
    "runway_closed",
    "Runway 09L/27R closed",
    "For construction work.",
    80,
  ]);
  assertEquals(d(icao("RUNWAY 08/26 CLSD")).slice(0, 2), [
    "runway_closed",
    "Runway 08/26 closed",
  ]);
  assertEquals(d(icao("AERODROME CLOSED")), [
    "airport_closed",
    "Airport closed",
    null,
    100,
  ]);
  assertEquals(d(icao("ILS RWY 27L UNSERVICEABLE")), [
    "ils_out",
    "ILS for runway 27L out of service",
    "Landings in low cloud or fog may be slower.",
    60,
  ]);
  assertEquals(d(icao("ILS/DME RWY 09 U/S"))[0], "ils_out");
  // Not a passenger matter: left out.
  assertEquals(d(icao("VOR ABC FREQ CHANGED"))[0], "other");
});
