// What is likely wrong at an airport right now or in the next hours, from rules over the notices
// (NOTAMs) and the weather (METAR now, TAF ahead). No language model, no national feed: this is the
// disruption read for airports outside the US, and it adds the weather and notice reasons at US airports
// next to the FAA's own programs.
//
// The weather reading is the Rust core's (weatherImpact): this file maps its levels and adds the notice
// rules. Levels: normal (nothing to say), minor (some slowing likely), major (closures or severe weather).
import { type Hazard, weatherImpact } from "./flightcore.ts";
import type { Notam } from "./notam.ts";
import type { ForecastPeriod, Weather } from "./weather.ts";

export type ConditionsLevel = "normal" | "minor" | "major";
export type ReasonSource = "notam" | "metar" | "forecast";

export interface ConditionsReason {
  source: ReasonSource;
  level: Exclude<ConditionsLevel, "normal">;
  /** Plain English, no times: "Thunderstorms nearby in the forecast". */
  text: string;
  /** When it starts and ends (ISO 8601 UTC), for the app to show in the airport's time zone. */
  starts_at: string | null;
  ends_at: string | null;
}

/** Wire shape of the airport conditions summary: FlightKit `AirportAssessment`. */
export interface Conditions {
  level: ConditionsLevel;
  /** The first (most serious) reason, null on a normal day. */
  summary: string | null;
  /** Most serious first, at most MAX_REASONS. */
  reasons: ConditionsReason[];
  /** What the read was made from. A source that failed is false, never a silent "all clear". */
  sources: { metar: boolean; taf: boolean; notam: boolean };
}

export interface ConditionsInput {
  /** The METAR and TAF snapshot; null when the weather could not be read. */
  weather: Weather | null;
  /** The decoded notices; null when NOTAMs are not configured or could not be read. */
  notams: Notam[] | null;
  now: Date;
}

/** How far ahead the forecast is read. */
export const FORECAST_HOURS = 12;
/** A notice starting later than this is not yet news. */
export const NOTAM_AHEAD_HOURS = 6;
export const MAX_REASONS = 5;

const RANK = { normal: 0, minor: 1, major: 2 } as const;

const capitalized = (s: string) =>
  s.length ? s[0].toUpperCase() + s.slice(1) : s;

/** The notice rules. Cancelled and expired notices are already out (parseNotamApi). */
export function notamReasons(notams: Notam[], now: Date): ConditionsReason[] {
  const t = now.getTime();
  const out: ConditionsReason[] = [];
  const active = notams.filter((n) => {
    const from = n.starts_at ? Date.parse(n.starts_at) : -Infinity;
    const to = n.ends_at ? Date.parse(n.ends_at) : Infinity;
    return from <= t + NOTAM_AHEAD_HOURS * 3600_000 && to > t;
  });
  const times = (n: Notam) => ({ starts_at: n.starts_at, ends_at: n.ends_at });

  // A closed airport (relevance 100) is major; closed with exceptions (50) is minor. A closure to
  // private flights only (2) does not touch an airline passenger.
  for (const n of active) {
    if (n.kind !== "airport_closed" || n.relevance < 50) continue;
    out.push({
      source: "notam",
      level: n.relevance >= 100 ? "major" : "minor",
      text: n.relevance >= 100
        ? "Airport closed by notice"
        : "Airport closed with exceptions",
      ...times(n),
    });
  }

  // Whole runway closures: one is minor, two or more is major.
  const runways = active.filter((n) =>
    n.kind === "runway_closed" && n.relevance >= 80
  );
  if (runways.length) {
    out.push({
      source: "notam",
      level: runways.length >= 2 ? "major" : "minor",
      text: runways.length === 1
        ? `${runways[0].title}`
        : `${runways.length} runways closed`,
      ...times(runways[0]),
    });
  }
  // A runway closed in part restricts it without shutting it.
  const partial = active.filter((n) =>
    n.kind === "runway_closed" && n.relevance >= 50 && n.relevance < 80
  );
  if (partial.length) {
    out.push({
      source: "notam",
      level: "minor",
      text: partial.length === 1
        ? partial[0].title
        : `${partial.length} runways closed in part`,
      ...times(partial[0]),
    });
  }
  // An instrument landing system out slows arrivals in low cloud or fog.
  const ils = active.filter((n) => n.kind === "ils_out");
  if (ils.length) {
    out.push({
      source: "notam",
      level: "minor",
      text: ils.length === 1
        ? ils[0].title
        : `${ils.length} instrument landing systems out of service`,
      ...times(ils[0]),
    });
  }
  return out;
}

function hazardText(hazards: Hazard[]): string {
  const labels = hazards.filter((h) =>
    h.level !== "none" && h.level !== "minor"
  ).map((h) => h.label);
  const picked = [...new Set(labels)].slice(0, 2);
  return capitalized(picked.join(" and "));
}

/** The weather rules over one set of conditions: null when the weather is not slowing anything. */
function weatherRead(
  c: Parameters<typeof weatherImpact>[0],
  cap: "major" | "minor",
): { level: "minor" | "major"; label: string } | null {
  const i = weatherImpact(c);
  if (i.level !== "moderate" && i.level !== "severe") return null;
  const label = hazardText(i.hazards);
  if (!label) return null;
  const level = i.level === "severe" && cap === "major" ? "major" : "minor";
  return { level, label };
}

/** Present weather now (METAR). */
export function metarReasons(w: Weather): ConditionsReason[] {
  const r = weatherRead({
    ceilingFt: w.ceilingFt,
    visibilitySm: w.visibilitySm,
    windKt: w.windKt,
    gustKt: w.gustKt,
    wx: w.wx ?? "",
  }, "major");
  if (!r) return [];
  return [{
    source: "metar",
    level: r.level,
    text: `${r.label} at the airport now`,
    starts_at: w.observedAt,
    ends_at: null,
  }];
}

/**
 * Forecast periods that reach into the next FORECAST_HOURS. A TEMPO or PROB period is a maybe: it is
 * never read as major. The same hazard in several periods is one reason spanning them.
 */
export function forecastReasons(
  periods: ForecastPeriod[],
  now: Date,
): ConditionsReason[] {
  const t = now.getTime();
  const horizon = t + FORECAST_HOURS * 3600_000;
  const merged = new Map<string, ConditionsReason>();
  for (const p of periods) {
    const from = Date.parse(p.from);
    const to = Date.parse(p.to);
    if (to <= t || from >= horizon) continue;
    const maybe = p.change === "TEMPO" || p.change === "PROB";
    const r = weatherRead({
      ceilingFt: p.ceilingFt,
      visibilitySm: p.visibilitySm,
      windKt: p.windKt,
      gustKt: p.gustKt,
      wx: p.wx ?? "",
    }, maybe ? "minor" : "major");
    if (!r) continue;
    const key = r.label;
    const start = new Date(Math.max(from, t)).toISOString();
    const end = new Date(Math.min(to, horizon)).toISOString();
    const prev = merged.get(key);
    if (!prev) {
      merged.set(key, {
        source: "forecast",
        level: r.level,
        text: `${r.label} in the forecast${maybe ? " at times" : ""}`,
        starts_at: start,
        ends_at: end,
      });
    } else {
      if (RANK[r.level] > RANK[prev.level]) prev.level = r.level;
      if (start < (prev.starts_at ?? start)) prev.starts_at = start;
      if (end > (prev.ends_at ?? end)) prev.ends_at = end;
      if (!maybe) prev.text = `${r.label} in the forecast`;
    }
  }
  return [...merged.values()];
}

/** The summary for an airport from what is known. A source that is null is not read, never "fine". */
export function inferConditions(input: ConditionsInput): Conditions {
  const { weather, notams, now } = input;
  const reasons: ConditionsReason[] = [
    ...(notams ? notamReasons(notams, now) : []),
    ...(weather ? metarReasons(weather) : []),
    ...(weather ? forecastReasons(weather.forecast, now) : []),
  ];
  const order = { notam: 0, metar: 1, forecast: 2 } as const;
  reasons.sort((a, b) =>
    RANK[b.level] - RANK[a.level] || order[a.source] - order[b.source]
  );
  const kept = reasons.slice(0, MAX_REASONS);
  const level = kept.length ? kept[0].level : "normal";
  return {
    level,
    summary: kept.length ? kept[0].text : null,
    reasons: kept,
    sources: {
      metar: weather !== null,
      taf: weather !== null && weather.tafRaw !== null,
      notam: notams !== null,
    },
  };
}
