// The pairing and verdict behind the "connection at risk" alert, on the same cases as FlightKit's
// ConnectionTests, so the app's card and the push agree.
import { assertEquals } from "jsr:@std/assert@1";
import { alertText } from "./alert_copy.ts";
import { emptyHistory } from "./alerts.ts";
import {
  assess,
  bestArrival,
  connectionAlert,
  type ConnFlight,
  mctFor,
  pairs,
  sameRegion,
  verdictOf,
} from "./connections.ts";

const T0 = Date.parse("2026-11-03T12:00:00Z");
const at = (min: number) => new Date(T0 + min * 60_000).toISOString();

function flight(
  ident: string,
  o: string,
  d: string,
  out: number,
  inn: number,
  over: Partial<ConnFlight> = {},
): ConnFlight {
  return {
    id: crypto.randomUUID(),
    ident,
    status: "scheduled",
    origin_icao: o,
    origin_iata: o.slice(1),
    destination_icao: d,
    destination_iata: d.slice(1),
    scheduled_out: at(out),
    scheduled_in: at(inn),
    estimated_out: null,
    estimated_in: null,
    actual_out: null,
    actual_in: null,
    ...over,
  };
}

const COUNTRIES: Record<string, string> = {
  KSFO: "US",
  KORD: "US",
  KLAX: "US",
  KJFK: "US",
  KATL: "US",
  KMIA: "US",
  TJSJ: "PR",
  LFPG: "FR",
  LEMD: "ES",
  EGLL: "GB",
  OMDB: "AE",
};
const country = (icao: string) => COUNTRIES[icao] ?? null;

Deno.test("the rules: MCT lookup, defaults and regions", () => {
  assertEquals(mctFor("KSFO", "id"), 90);
  assertEquals(mctFor("ksfo", "dd"), 45);
  assertEquals(mctFor("EDDM", "dd"), 30);
  assertEquals(mctFor("LFBO", "dd"), 45); // not in the table: the defaults
  assertEquals(sameRegion("US", "PR"), true);
  assertEquals(sameRegion("FR", "ES"), true);
  assertEquals(sameRegion("FR", "GB"), false);
});

Deno.test("pairing: same airport, onward within 24 hours, nearest wins, no return trips", () => {
  const a = flight("AF84", "LFPG", "KSFO", 0, 660);
  const near = flight("UA1", "KSFO", "KORD", 760, 1000);
  const far = flight("UA2", "KSFO", "KJFK", 900, 1200);
  const tooLate = flight("UA3", "KSFO", "KORD", 660 + 1441, 660 + 1500);
  const before = flight("UA4", "KSFO", "KORD", 600, 800);
  const back = flight("AF85", "KSFO", "LFPG", 800, 1400);
  const got = pairs([a, far, tooLate, before, back, near]);
  assertEquals(got.map(([x, y]) => [x.ident, y.ident]), [["AF84", "UA1"]]);
  // A three-leg trip: two connections.
  const b = flight("IB1", "LEMD", "LFPG", -200, -80);
  assertEquals(
    pairs([near, a, b]).map(([x, y]) => `${x.ident}>${y.ident}`).sort(),
    ["AF84>UA1", "IB1>AF84"],
  );
});

Deno.test("kinds and verdicts follow the app", () => {
  const a = flight("AF84", "LFPG", "KSFO", 0, 660);
  const b = flight("UA1958", "KSFO", "KORD", 780, 1035);
  const x = assess(a, b, country);
  assertEquals([x.kind, x.mct, x.layover, x.verdict], [
    "id",
    90,
    120,
    "comfortable",
  ]);
  const late = (min: number) =>
    assess({ ...a, estimated_in: at(min) }, b, country);
  assertEquals(late(680).verdict, "tight"); // 100
  assertEquals(late(720).verdict, "at_risk"); // 60
  assertEquals(late(770).verdict, "missed"); // 10
  // Schengen to non-Schengen at CDG; Puerto Rico is domestic from the mainland; unknown is international.
  assertEquals(
    assess(
      flight("IB1", "LEMD", "LFPG", 0, 120),
      flight("AF84", "LFPG", "KSFO", 240, 900),
      country,
    ).kind,
    "di",
  );
  assertEquals(
    assess(
      flight("AA1", "TJSJ", "KMIA", 0, 150),
      flight("AA2", "KMIA", "KATL", 240, 360),
      country,
    ).kind,
    "dd",
  );
  assertEquals(
    assess(
      flight("ZZ1", "ZZZZ", "KSFO", 0, 120),
      flight("UA2", "KSFO", "KORD", 300, 500),
      country,
    ).kind,
    "id",
  );
  assertEquals(
    [59, 60, 89, 90, 14, 15].map((m) => verdictOf(m, 60, null)),
    ["at_risk", "tight", "tight", "comfortable", "missed", "at_risk"],
  );
  assertEquals(verdictOf(300, 60, "departing_canceled"), "missed");
  assertEquals(
    bestArrival({ ...a, actual_on: at(650) }),
    Date.parse(at(655)),
  );
});

Deno.test("broken connections", () => {
  const a = flight("AF84", "LFPG", "KSFO", 0, 660);
  const b = flight("UA1958", "KSFO", "KORD", 780, 1035);
  assertEquals(
    assess({ ...a, status: "canceled" }, b, country).broken,
    "arriving_canceled",
  );
  assertEquals(
    assess(a, { ...b, status: "canceled" }, country).broken,
    "departing_canceled",
  );
  assertEquals(
    assess({ ...a, status: "diverted" }, b, country).broken,
    "arriving_diverted",
  );
  const left = { ...b, actual_out: at(700), status: "departed" };
  assertEquals(assess(a, left, country).broken, "departed");
  assertEquals(
    assess({ ...a, actual_in: at(650) }, left, country).broken,
    null,
  );
});

Deno.test("the alert: once, At risk or Missed only, never for a broken connection", () => {
  const a = flight("AF84", "LFPG", "KSFO", 0, 660, {
    estimated_in: at(735),
  });
  const b = flight("UA1958", "KSFO", "KORD", 780, 1035);
  const x = assess(a, b, country);
  assertEquals(x.verdict, "at_risk");
  const alert = connectionAlert(b, x, new Set())!;
  assertEquals(alert.kind, "connection_at_risk");
  assertEquals(alert.category, "delays");
  assertEquals(alert.key, `connection_at_risk:${b.id}`);
  assertEquals(alert.minutes, 45);
  assertEquals(connectionAlert(b, x, new Set([alert.key])), null);
  assertEquals(
    connectionAlert(
      b,
      assess({ ...a, estimated_in: at(680) }, b, country),
      new Set(),
    ),
    null,
  );
  assertEquals(
    connectionAlert(
      b,
      assess(a, { ...b, status: "canceled" }, country),
      new Set(),
    ),
    null,
  );

  const text = alertText(alert, a, { onward: b });
  assertEquals(text.title, "AF 84 connection at risk");
  assertEquals(
    text.body,
    "Only 45m to make UA 1958 at SFO, where it usually takes 1h 30m. Tell the crew you are connecting.",
  );
  const gone = connectionAlert(
    b,
    assess({ ...a, estimated_in: at(770) }, b, country),
    emptyHistory().keys,
  )!;
  assertEquals(alertText(gone, a, { onward: b }), {
    title: "AF 84 connection may be missed",
    body:
      "AF 84 now lands too late to make UA 1958 at SFO. Open the app for other flights.",
  });
});
