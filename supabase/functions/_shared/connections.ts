// The Connection Assistant's pairing and verdict, as the app's (FlightKit Models/Connection.swift), for
// the "connection at risk" push alert. Pure functions over the rules file the app ships too
// (connection_rules.json; a FlightKit test fails when the two copies differ), so the alert and the
// card never disagree.
//
// Two flights connect when the first lands where the second leaves from and the second is scheduled
// to leave after the first lands, within 24 hours; a flight back to where the first came from is a
// return trip. The layover runs from the first flight's best arrival (actual gate time, else estimate,
// else landing plus 5 minutes, else schedule) to the second's best departure, and is measured against
// the airport's typical minimum connection time (MCT) for the kind of connection.
import rules from "./connection_rules.json" with { type: "json" };
import { type Alert, type AlertFlight, CATEGORY } from "./alerts.ts";

export type Verdict = "comfortable" | "tight" | "at_risk" | "missed";
/** dd domestic to domestic, di domestic to international, id and ii likewise. */
export type Kind = "dd" | "di" | "id" | "ii";
/** Why a connection is missed when time on the ground is not the reason. */
export type Broken =
  | "arriving_canceled"
  | "departing_canceled"
  | "arriving_diverted"
  | "departed";

/** The flights columns pairing and the verdict read. */
export type ConnFlight = AlertFlight & { id: string };

const VERDICTS: Verdict[] = ["comfortable", "tight", "at_risk", "missed"];
/** Longest scheduled gap between landing and leaving that still reads as a connection. */
export const PAIR_WINDOW_MS = 24 * 3_600_000;

const ms = (v: string | null | undefined): number | null => {
  if (!v) return null;
  const t = Date.parse(v);
  return Number.isFinite(t) ? t : null;
};

/** The scheduled gap when `b` connects from `a`, in ms; null when it does not. */
export function gapMs(a: ConnFlight, b: ConnFlight): number | null {
  if (
    a.id === b.id || !a.destination_icao ||
    a.destination_icao !== b.origin_icao ||
    b.destination_icao === a.origin_icao
  ) return null;
  const landing = ms(a.scheduled_in) ?? ms(a.estimated_in);
  const leaving = ms(b.scheduled_out) ?? ms(b.estimated_out);
  if (landing === null || leaving === null) return null;
  const gap = leaving - landing;
  return gap > 0 && gap <= PAIR_WINDOW_MS ? gap : null;
}

/**
 * Every connection among one user's flights. Each flight arrives into at most one connection and
 * leaves from at most one: the shortest gaps win (ties by the onward flight's id), as in the app.
 */
export function pairs<F extends ConnFlight>(flights: F[]): [F, F][] {
  const cands: { gap: number; a: F; b: F }[] = [];
  for (const a of flights) {
    for (const b of flights) {
      const g = gapMs(a, b);
      if (g !== null) cands.push({ gap: g, a, b });
    }
  }
  const order = (f: F) => f.id.toUpperCase();
  cands.sort((x, y) =>
    x.gap - y.gap ||
    (order(x.b) < order(y.b) ? -1 : order(x.b) > order(y.b) ? 1 : 0)
  );
  const arriving = new Set<string>(), departing = new Set<string>();
  const out: [F, F][] = [];
  for (const c of cands) {
    if (arriving.has(c.a.id) || departing.has(c.b.id)) continue;
    arriving.add(c.a.id);
    departing.add(c.b.id);
    out.push([c.a, c.b]);
  }
  return out;
}

export function bestArrival(f: ConnFlight): number | null {
  const on = ms(f.actual_on);
  return ms(f.actual_in) ?? ms(f.estimated_in) ??
    (on !== null ? on + 5 * 60_000 : null) ?? ms(f.scheduled_in);
}

export function bestDeparture(f: ConnFlight): number | null {
  return ms(f.actual_out) ?? ms(f.estimated_out) ?? ms(f.scheduled_out);
}

/** True when a flight between the two countries needs no passport check. */
export function sameRegion(a: string, b: string): boolean {
  const x = a.toUpperCase(), y = b.toUpperCase();
  if (x === y) return true;
  if (rules.country_groups.some((g) => g.includes(x) && g.includes(y))) {
    return true;
  }
  return rules.schengen.includes(x) && rules.schengen.includes(y);
}

/** The airport's MCT for a kind, or the defaults' for an airport outside the table. */
export function mctFor(icao: string, kind: Kind): number {
  const table = rules.airports as Record<
    string,
    { mct: Record<Kind, number> }
  >;
  return (table[icao.toUpperCase()] ?? rules.defaults).mct[kind];
}

export function broken(a: ConnFlight, b: ConnFlight): Broken | null {
  if (a.status === "canceled") return "arriving_canceled";
  if (b.status === "canceled") return "departing_canceled";
  if (a.status === "diverted") return "arriving_diverted";
  const left = ms(b.actual_out);
  if (left !== null) {
    const landed = ms(a.actual_in) ?? ms(a.actual_on);
    if (landed === null || landed > left) return "departed";
  }
  return null;
}

/** The verdict for a layover against an MCT, as ConnectionAssistant.verdict in the app. */
export function verdictOf(
  layover: number | null,
  mct: number,
  why: Broken | null,
): Verdict {
  if (why) return "missed";
  if (layover === null) return "comfortable";
  if (layover < rules.verdict.gate_close_minutes) return "missed";
  if (layover < mct) return "at_risk";
  if (layover < mct + rules.verdict.tight_margin_minutes) return "tight";
  return "comfortable";
}

export interface Assessment {
  kind: Kind;
  mct: number;
  /** Minutes on the ground (negative when the onward flight leaves first); null when unknown. */
  layover: number | null;
  verdict: Verdict;
  broken: Broken | null;
}

/**
 * The verdict of `a` connecting into `b`. `country` gives an airport's ISO country by ICAO code; an
 * airport it does not know counts as international (the longer connection).
 */
export function assess(
  a: ConnFlight,
  b: ConnFlight,
  country: (icao: string) => string | null,
): Assessment {
  const hub = b.origin_icao ?? "";
  const hubCountry = country(hub);
  const international = (other: string | null | undefined) => {
    const o = other ? country(other) : null;
    return !hubCountry || !o || !sameRegion(hubCountry, o);
  };
  const kind = `${international(a.origin_icao) ? "i" : "d"}${
    international(b.destination_icao) ? "i" : "d"
  }` as Kind;
  const mct = mctFor(hub, kind);
  const i = bestArrival(a), o = bestDeparture(b);
  const layover = i !== null && o !== null
    ? Math.floor((o - i) / 60_000)
    : null;
  const why = broken(a, b);
  return {
    kind,
    mct,
    layover,
    verdict: verdictOf(layover, mct, why),
    broken: why,
  };
}

export function worse(x: Verdict, y: Verdict): boolean {
  return VERDICTS.indexOf(x) > VERDICTS.indexOf(y);
}

/**
 * The "connection at risk" alert for `a` connecting into `b`: once the layover falls under the MCT
 * (At risk) or under the time boarding closes (Missed). Cancellations, diversions and an onward
 * flight that already left have alerts of their own and send none. Once per pair: the key names the
 * onward flight and is claimed on the arriving one, which carries the alert.
 */
export function connectionAlert(
  b: ConnFlight,
  x: Assessment,
  sent: Set<string>,
): Alert | null {
  if (x.broken || !worse(x.verdict, "tight")) return null;
  const key = `connection_at_risk:${b.id}`;
  if (sent.has(key)) return null;
  return {
    kind: "connection_at_risk",
    category: CATEGORY.connection_at_risk,
    key,
    minutes: x.layover ?? undefined,
    from: String(x.mct),
    to: b.id,
  };
}
