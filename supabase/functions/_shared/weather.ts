// METAR and TAF from aviationweather.gov (free, public JSON). The flight category comes
// from the Rust core through flightcore.ts; nothing here reimplements it.
import { ApiError } from "./errors.ts";
import { type FlightCategory, flightCategory } from "./flightcore.ts";

export const WEATHER_BASE = "https://aviationweather.gov/api/data";
export const WEATHER_USER_AGENT =
  "SomaFlight/1.0 (+https://somalabs.me; flight board weather)";
export const WEATHER_TIMEOUT_MS = 8_000;

export interface CloudLayer {
  cover: string;
  baseFt: number | null;
}

export interface MetarObservation {
  raw: string;
  /** ISO 8601 observation time. */
  observedAt: string | null;
  /** Degrees, "VRB" for variable, null when not reported. */
  windDirection: number | "VRB" | null;
  windKt: number | null;
  gustKt: number | null;
  /** Statute miles; "10+" is 10. Null when not reported. */
  visibilitySm: number | null;
  /** Lowest BKN, OVC or VV layer in feet, null when there is none. */
  ceilingFt: number | null;
  clouds: CloudLayer[];
  weather: string | null;
  tempC: number | null;
  dewpointC: number | null;
  altimeterHpa: number | null;
  /** From the core (FAA thresholds). Null when visibility is not reported. */
  category: FlightCategory | null;
}

export interface TafPeriod {
  from: string;
  to: string;
  /** FM, BECMG, TEMPO or PROB when the period is a change group, null for the base period. */
  change: string | null;
  probability: number | null;
  windDirection: number | "VRB" | null;
  windKt: number | null;
  gustKt: number | null;
  visibilitySm: number | null;
  ceilingFt: number | null;
  clouds: CloudLayer[];
  weather: string | null;
  category: FlightCategory | null;
}

export interface Taf {
  raw: string;
  issuedAt: string | null;
  validFrom: string | null;
  validTo: string | null;
  periods: TafPeriod[];
}

export interface Weather {
  icao: string;
  metar: MetarObservation | null;
  taf: Taf | null;
}

type Json = Record<string, unknown>;

function num(v: unknown): number | null {
  if (typeof v === "number" && Number.isFinite(v)) return v;
  if (typeof v === "string" && v.trim() !== "" && Number.isFinite(Number(v))) {
    return Number(v);
  }
  return null;
}

/** Statute miles from 10, "10+", "6+", "1/2", "1 1/2". */
export function parseVisibility(v: unknown): number | null {
  if (typeof v === "number") return Number.isFinite(v) ? v : null;
  if (typeof v !== "string") return null;
  const s = v.trim().replace(/^[PM]/, "").replace(/\+$/, "").replace(/SM$/, "");
  if (s === "") return null;
  let total = 0;
  for (const part of s.split(/\s+/)) {
    const frac = /^(\d+)\/(\d+)$/.exec(part);
    if (frac) {
      if (Number(frac[2]) === 0) return null;
      total += Number(frac[1]) / Number(frac[2]);
    } else if (/^\d+(\.\d+)?$/.test(part)) {
      total += Number(part);
    } else {
      return null;
    }
  }
  return total;
}

function layers(v: unknown): CloudLayer[] {
  if (!Array.isArray(v)) return [];
  return v.map((c: Json) => ({
    cover: String(c.cover ?? ""),
    baseFt: num(c.base),
  }));
}

/** Lowest BKN, OVC or VV layer (OVX counts as VV). Vertical visibility is a ceiling too. */
export function ceilingOf(
  clouds: CloudLayer[],
  verticalVisibilityFt: number | null = null,
): number | null {
  const bases: number[] = [];
  for (const c of clouds) {
    if (
      ["BKN", "OVC", "VV", "OVX"].includes(c.cover) && c.baseFt !== null
    ) bases.push(c.baseFt);
  }
  if (verticalVisibilityFt !== null) bases.push(verticalVisibilityFt);
  return bases.length ? Math.min(...bases) : null;
}

function windDirection(v: unknown): number | "VRB" | null {
  if (v === "VRB") return "VRB";
  return num(v);
}

function isoOfEpoch(v: unknown): string | null {
  const n = num(v);
  return n === null ? null : new Date(n * 1000).toISOString();
}

function categoryOf(
  ceilingFt: number | null,
  visibilitySm: number | null,
): FlightCategory | null {
  if (visibilitySm === null) return null;
  return flightCategory(
    ceilingFt === null ? null : Math.round(ceilingFt),
    visibilitySm,
  );
}

export function parseMetar(o: Json): MetarObservation {
  const clouds = layers(o.clouds);
  const ceilingFt = ceilingOf(clouds, num(o.vertVis));
  const visibilitySm = parseVisibility(o.visib);
  return {
    raw: String(o.rawOb ?? ""),
    observedAt: isoOfEpoch(o.obsTime) ??
      (typeof o.reportTime === "string" ? o.reportTime : null),
    windDirection: windDirection(o.wdir),
    windKt: num(o.wspd),
    gustKt: num(o.wgst),
    visibilitySm,
    ceilingFt,
    clouds,
    weather: typeof o.wxString === "string" && o.wxString ? o.wxString : null,
    tempC: num(o.temp),
    dewpointC: num(o.dewp),
    altimeterHpa: num(o.altim),
    category: categoryOf(ceilingFt, visibilitySm),
  };
}

export function parseTaf(t: Json): Taf {
  const fcsts = Array.isArray(t.fcsts) ? t.fcsts as Json[] : [];
  return {
    raw: String(t.rawTAF ?? ""),
    issuedAt: typeof t.issueTime === "string" ? t.issueTime : null,
    validFrom: isoOfEpoch(t.validTimeFrom),
    validTo: isoOfEpoch(t.validTimeTo),
    periods: fcsts.map((f) => {
      const clouds = layers(f.clouds);
      const ceilingFt = ceilingOf(clouds, num(f.vertVis));
      const visibilitySm = parseVisibility(f.visib);
      return {
        from: isoOfEpoch(f.timeFrom) ?? "",
        to: isoOfEpoch(f.timeTo) ?? "",
        change: typeof f.fcstChange === "string" ? f.fcstChange : null,
        probability: num(f.probability),
        windDirection: windDirection(f.wdir),
        windKt: num(f.wspd),
        gustKt: num(f.wgst),
        visibilitySm,
        ceilingFt,
        clouds,
        weather: typeof f.wxString === "string" && f.wxString
          ? f.wxString
          : null,
        category: categoryOf(ceilingFt, visibilitySm),
      };
    }),
  };
}

async function getJson(
  kind: "metar" | "taf",
  icao: string,
  fetchFn: typeof fetch,
): Promise<Json[]> {
  const url = `${WEATHER_BASE}/${kind}?ids=${
    encodeURIComponent(icao)
  }&format=json`;
  const res = await fetchFn(url, {
    headers: { "user-agent": WEATHER_USER_AGENT, accept: "application/json" },
    signal: AbortSignal.timeout(WEATHER_TIMEOUT_MS),
  });
  if (res.status === 204) return [];
  if (!res.ok) {
    await res.body?.cancel();
    throw new Error(`${kind} responded ${res.status}`);
  }
  const body = await res.json();
  if (!Array.isArray(body)) throw new Error(`${kind} body is not a list`);
  return body as Json[];
}

/**
 * Current METAR and TAF. A missing report is null (many airports have no TAF).
 * Throws provider_unavailable only when both requests fail.
 */
export async function fetchWeather(
  icao: string,
  fetchFn: typeof fetch = fetch,
): Promise<Weather> {
  const [m, t] = await Promise.allSettled([
    getJson("metar", icao, fetchFn),
    getJson("taf", icao, fetchFn),
  ]);
  if (m.status === "rejected" && t.status === "rejected") {
    throw new ApiError(
      "provider_unavailable",
      503,
      "Weather provider unavailable",
    );
  }
  return {
    icao,
    metar: m.status === "fulfilled" && m.value[0]
      ? parseMetar(m.value[0])
      : null,
    taf: t.status === "fulfilled" && t.value[0] ? parseTaf(t.value[0]) : null,
  };
}
