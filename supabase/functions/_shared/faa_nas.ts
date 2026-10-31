// The FAA's National Airspace System status (nasstatus.faa.gov), read and put into the app's words:
// ground stops, ground delay programs, departure and arrival delays, airport closures and deicing at
// US airports. Public and free: a work of the US government, no key, no terms beyond fair use.
//
// Source: GET https://nasstatus.faa.gov/api/airport-events, the JSON the FAA's own status page draws
// from (one entry per airport with something going on). The older XML feed at
// /api/airport-status-information carries the same programs with text times ("Oct 31 at 03:00 UTC.")
// and no ids, so the JSON is the one read here. Neither is formally documented: the field names come
// from real answers (fixtures/nas_airport_events_20261031.json) and from the status page's own code;
// anything this parser does not recognise is skipped, never guessed.
//
// Pure functions apart from fetchNas. faa-status caches the parsed programs; push-sender words the
// alert (alert_copy.ts) and faa-status decides which flights get one (relevantFor, programKey).

/** What a program is, most serious first in SEVERITY. */
export type ProgramKind =
  | "closure"
  | "ground_stop"
  | "ground_delay"
  | "departure_delay"
  | "arrival_delay"
  | "deicing";

/** Most serious first: the order the app lists programs and the order of `sortPrograms`. */
export const SEVERITY: readonly ProgramKind[] = [
  "closure",
  "ground_stop",
  "ground_delay",
  "departure_delay",
  "arrival_delay",
  "deicing",
];

/** The kinds worth a push when they start: the ones that hold or stop flights outright. */
export const ALERT_KINDS = new Set<ProgramKind>([
  "closure",
  "ground_stop",
  "ground_delay",
]);

export type Trend = "increasing" | "decreasing" | "steady";
export type Extension = "low" | "medium" | "high";

/** One program at one airport, as faa-status answers it. Times are ISO 8601 UTC. */
export interface Program {
  /** The FAA's code for the airport (its IATA code for every airline airport, e.g. SFO). */
  airport: string;
  kind: ProgramKind;
  /** The cause in plain words ("low clouds", "heavy traffic"); null when the FAA gave none. */
  reason: string | null;
  /** The cause as the FAA wrote it ("WEATHER / LOW CEILINGS"). */
  reason_raw: string | null;
  /** Average delay in minutes: ground delay programs and departure or arrival delays. */
  average_minutes: number | null;
  /** Departure and arrival delays: which way they are going. */
  trend: Trend | null;
  /** Ground stops: how likely the FAA thinks it is to run past its end time. */
  extension: Extension | null;
  starts_at: string | null;
  /** The planned end (ground stop, ground delay program, closure); null when open ended. */
  ends_at: string | null;
  /** When the FAA last changed it. */
  updated_at: string | null;
  /** The ATCSCC advisory that announced it, when there is one. */
  advisory_url: string | null;
}

export const NAS_URL = "https://nasstatus.faa.gov/api/airport-events";
export const NAS_USER_AGENT = "SomaFlight/1.0 (+https://somalabs.me)";
export const NAS_TIMEOUT_MS = 10_000;

type Obj = Record<string, unknown>;

const obj = (v: unknown): Obj | null =>
  v && typeof v === "object" && !Array.isArray(v) ? v as Obj : null;

const str = (v: unknown): string | null =>
  typeof v === "string" && v.trim() !== "" ? v.trim() : null;

/** A time the feed wrote, as ISO 8601; null when absent or unreadable. */
function iso(v: unknown): string | null {
  const s = str(v);
  if (!s) return null;
  const t = Date.parse(s);
  return Number.isFinite(t) ? new Date(t).toISOString() : null;
}

/** Whole minutes from a number or a numeric string, 0 to 24 hours; else null. */
function minutes(v: unknown): number | null {
  const n = typeof v === "number" ? v : typeof v === "string" ? Number(v) : NaN;
  return Number.isFinite(n) && n >= 0 && n <= 1440 ? Math.round(n) : null;
}

function trendOf(v: unknown): Trend | null {
  const s = str(v)?.toLowerCase();
  if (s === "increasing" || s === "decreasing") return s;
  return s ? "steady" : null;
}

function extensionOf(v: unknown): Extension | null {
  const s = str(v)?.toLowerCase();
  return s === "low" || s === "medium" || s === "high" ? s : null;
}

/**
 * The cause in plain words, from the FAA's codes ("WEATHER / LOW CEILINGS", "TM Initiatives:MIT:VOL",
 * "WIND"). Weather words win over the category; an unknown cause keeps its own words in lower case,
 * without the category before the slash. null for nothing.
 */
export function plainReason(raw: string | null | undefined): string | null {
  const s = str(raw);
  if (!s) return null;
  const u = s.toUpperCase();
  const rules: [RegExp, string][] = [
    [/THUNDER|TSTM|\bTS\b/, "thunderstorms"],
    [/CEILING/, "low clouds"],
    [/FOG|LOW VIS|VISIBILITY/, "low visibility"],
    [/SNOW|ICE|ICING|FREEZING/, "snow and ice"],
    [/WIND/, "strong wind"],
    [/RAIN/, "rain"],
    [/CONSTRUCT|\bWIP\b|MAINT/, "runway or taxiway work"],
    [/EQUIP|OUTAGE/, "an equipment outage"],
    [/STAFF/, "air traffic control staffing"],
    [/VIP/, "a VIP movement"],
    [/SECURITY/, "a security event"],
    [/RWY|RUNWAY|CONFIG/, "the runways in use"],
    [/VOL|TM INIT|\bMIT\b|COMPACTED|TRAFFIC/, "heavy traffic"],
  ];
  for (const [re, words] of rules) if (re.test(u)) return words;
  const tail = s.includes("/") ? s.slice(s.lastIndexOf("/") + 1) : s;
  const words = tail.replace(/[_:]+/g, " ").replace(/\s+/g, " ").trim()
    .toLowerCase();
  return words === "" || words === "other" ? null : words;
}

function program(
  airport: string,
  kind: ProgramKind,
  fields: Partial<Program>,
): Program {
  return {
    airport,
    kind,
    reason: plainReason(fields.reason_raw),
    reason_raw: fields.reason_raw ?? null,
    average_minutes: fields.average_minutes ?? null,
    trend: fields.trend ?? null,
    extension: fields.extension ?? null,
    starts_at: fields.starts_at ?? null,
    ends_at: fields.ends_at ?? null,
    updated_at: fields.updated_at ?? null,
    advisory_url: fields.advisory_url ?? null,
  };
}

/** The programs of one airport entry of the feed. */
function programsOf(entry: Obj): Program[] {
  const airport = str(entry.airportId)?.toUpperCase();
  if (!airport || !/^[A-Z0-9]{3,4}$/.test(airport)) return [];
  const out: Program[] = [];

  // A closure with words after CLSD is a restriction (closed to transient general aviation, to
  // unscheduled flights): nothing for an airline passenger. Free-form notices are the same kind of
  // restriction (see the LAS, LAX and SAN entries of the real fixture) and are skipped too.
  const closure = obj(entry.airportClosure);
  if (closure && !str(closure.text)) {
    out.push(program(airport, "closure", {
      starts_at: iso(closure.startTime),
      ends_at: iso(closure.endTime),
      updated_at: iso(closure.updatedAt),
      reason_raw: null,
    }));
  }
  const gs = obj(entry.groundStop);
  if (gs) {
    out.push(program(airport, "ground_stop", {
      reason_raw: str(gs.impactingCondition),
      extension: extensionOf(gs.probabilityOfExtension),
      starts_at: iso(gs.startTime),
      ends_at: iso(gs.endTime),
      updated_at: iso(gs.updatedAt),
      advisory_url: str(gs.advisoryUrl),
    }));
  }
  const gdp = obj(entry.groundDelay);
  if (gdp) {
    out.push(program(airport, "ground_delay", {
      reason_raw: str(gdp.impactingCondition),
      average_minutes: minutes(gdp.avgDelay),
      starts_at: iso(gdp.startTime),
      ends_at: iso(gdp.endTime),
      updated_at: iso(gdp.updatedAt),
      advisory_url: str(gdp.advisoryUrl),
    }));
  }
  for (
    const [key, kind] of [
      ["departureDelay", "departure_delay"],
      ["arrivalDelay", "arrival_delay"],
    ] as const
  ) {
    const d = obj(entry[key]);
    if (!d) continue;
    out.push(program(airport, kind, {
      reason_raw: str(d.reason),
      average_minutes: minutes(d.averageDelay),
      trend: trendOf(d.trend),
      updated_at: iso(d.updateTime),
    }));
  }
  const deicing = obj(entry.deicing);
  if (deicing) {
    out.push(program(airport, "deicing", {
      starts_at: iso(deicing.eventTime),
      updated_at: iso(deicing.eventTime),
    }));
  }
  return out;
}

/**
 * Every program of an airport-events answer, most serious first, without the ones whose planned end
 * has passed at `now`. Throws when the answer is not the feed's list (a changed or broken source must
 * not read as "nothing going on").
 */
export function parseAirportEvents(body: unknown, now: Date): Program[] {
  if (!Array.isArray(body)) {
    throw new Error("airport-events answer is not a list");
  }
  const t = now.getTime();
  const out = body.flatMap((e) => (obj(e) ? programsOf(e as Obj) : []))
    .filter((p) => p.ends_at === null || Date.parse(p.ends_at) > t);
  return sortPrograms(out);
}

/** Most serious first, then by airport. */
export function sortPrograms(ps: Program[]): Program[] {
  return [...ps].sort((a, b) =>
    SEVERITY.indexOf(a.kind) - SEVERITY.indexOf(b.kind) ||
    a.airport.localeCompare(b.airport)
  );
}

/** Fetches and parses the feed. Throws on a network failure, a non-200 or an answer it cannot read. */
export async function fetchNas(
  fetchFn: typeof fetch,
  now: Date,
): Promise<Program[]> {
  const res = await fetchFn(NAS_URL, {
    headers: { accept: "application/json", "user-agent": NAS_USER_AGENT },
    signal: AbortSignal.timeout(NAS_TIMEOUT_MS),
  });
  if (!res.ok) {
    await res.body?.cancel();
    throw new Error(`nasstatus answered ${res.status}`);
  }
  return parseAirportEvents(await res.json(), now);
}

/** Which end of a flight an airport is. */
export type End = "origin" | "destination";

/**
 * Whether a program at one end matters to a passenger of a flight: departure delays and deicing only
 * at the origin, arrival delays only at the destination; closures, ground stops and ground delay
 * programs at either end (a ground stop or program at the destination holds the flight before it
 * leaves; at the origin it says the airport is struggling).
 */
export function mattersAt(kind: ProgramKind, end: End): boolean {
  switch (kind) {
    case "departure_delay":
    case "deicing":
      return end === "origin";
    case "arrival_delay":
      return end === "destination";
    default:
      return true;
  }
}

/**
 * The alert_log key of a program alert: unique per flight, airport, kind and the program's start, so
 * a program announced once is never announced again as it is revised (a new average, a later end),
 * and a new program at the same airport later in the day is.
 */
export function programKey(icao: string, p: Program): string {
  const start = p.starts_at ? p.starts_at.slice(0, 16) : "open";
  return `airport_program:${icao}:${p.kind}:${start}`;
}

/** The program details an airport_program alert carries to push-sender. */
export interface ProgramAlert {
  key: string;
  kind: ProgramKind;
  end: End;
  /** The airport's code as the app shows it (IATA, else ICAO). */
  code: string;
  reason: string | null;
  average_minutes: number | null;
  ends_at: string | null;
}

/** The fields push-sender needs, or null when `body` is not one (it came over the network). */
export function readProgramAlert(body: unknown): ProgramAlert | null {
  const o = obj(body);
  if (!o) return null;
  const kind = o.kind as ProgramKind;
  const key = str(o.key), code = str(o.code);
  if (!key || !key.startsWith("airport_program:") || key.length > 120) {
    return null;
  }
  if (!ALERT_KINDS.has(kind) || !code || !/^[A-Z0-9]{3,4}$/.test(code)) {
    return null;
  }
  if (o.end !== "origin" && o.end !== "destination") return null;
  return {
    key,
    kind,
    end: o.end,
    code,
    reason: str(o.reason),
    average_minutes: minutes(o.average_minutes),
    ends_at: iso(o.ends_at),
  };
}
