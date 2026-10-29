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

/** Wire shape of one forecast period: FlightKit `ForecastPeriod`, camelCase keys, ISO 8601 dates. */
export interface ForecastPeriod {
  from: string;
  to: string;
  category: FlightCategory;
  /** Null for variable or calm wind. */
  windDirDeg: number | null;
  windKt: number | null;
  gustKt: number | null;
  visibilitySm: number | null;
  /** Lowest BKN, OVC or VV layer in feet, null when there is none. */
  ceilingFt: number | null;
}

/** Wire shape of the weather snapshot: FlightKit `Weather`. */
export interface Weather {
  metarRaw: string;
  tafRaw: string | null;
  tempC: number | null;
  windDirDeg: number | null;
  windKt: number | null;
  gustKt: number | null;
  visibilitySm: number | null;
  ceilingFt: number | null;
  category: FlightCategory;
  observedAt: string;
  forecast: ForecastPeriod[];
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

const CATEGORIES: readonly string[] = ["VFR", "MVFR", "IFR", "LIFR"];

/**
 * Vertical visibility from a TAF or METAR period. UNVERIFIED unit: the feed may give feet or
 * hundreds of feet (VV002). VV is never above 10,000 ft, so values up to 100 are read as hundreds.
 */
function verticalVisibilityFt(v: unknown): number | null {
  const n = num(v);
  if (n === null) return null;
  return n <= 100 ? n * 100 : n;
}

function isoOfEpoch(v: unknown): string | null {
  const n = num(v);
  return n === null ? null : new Date(n * 1000).toISOString();
}

const int = (n: number | null) => n === null ? null : Math.round(n);

/** Variable ("VRB") and calm wind have no direction in the app. */
function windDirDeg(dir: unknown, speedKt: number | null): number | null {
  if (dir === "VRB" || speedKt === null || speedKt === 0) return null;
  const n = num(dir);
  return n === null ? null : Math.round(n);
}

function categoryOf(
  ceilingFt: number | null,
  visibilitySm: number | null,
): FlightCategory | null {
  if (visibilitySm === null) return null;
  return flightCategory(int(ceilingFt), visibilitySm);
}

const newest = (list: Json[], key: string) =>
  [...list].sort((a, b) => (num(b[key]) ?? 0) - (num(a[key]) ?? 0))[0];

function parsePeriods(t: Json): ForecastPeriod[] {
  const fcsts = Array.isArray(t.fcsts) ? t.fcsts as Json[] : [];
  const out: ForecastPeriod[] = [];
  for (const f of fcsts) {
    const from = isoOfEpoch(f.timeFrom);
    const to = isoOfEpoch(f.timeTo);
    const clouds = layers(f.clouds);
    const ceilingFt = int(ceilingOf(clouds, verticalVisibilityFt(f.vertVis)));
    const visibilitySm = parseVisibility(f.visib);
    const category = categoryOf(ceilingFt, visibilitySm);
    // The app needs a time range and a category: leave out what cannot be shown.
    if (!from || !to || !category) continue;
    const windKt = int(num(f.wspd));
    out.push({
      from,
      to,
      category,
      windDirDeg: windDirDeg(f.wdir, windKt),
      windKt,
      gustKt: int(num(f.wgst)),
      visibilitySm,
      ceilingFt,
    });
  }
  return out;
}

/** The newest METAR/SPECI becomes the snapshot; null when it cannot fill the app's required fields. */
export function toWeather(metars: Json[], tafs: Json[]): Weather | null {
  if (metars.length === 0) return null;
  const o = newest(metars, "obsTime");
  const observedAt = isoOfEpoch(o.obsTime) ??
    (typeof o.reportTime === "string" ? o.reportTime : null);
  const metarRaw = typeof o.rawOb === "string" ? o.rawOb : "";
  const clouds = layers(o.clouds);
  const ceilingFt = int(ceilingOf(clouds, verticalVisibilityFt(o.vertVis)));
  const visibilitySm = parseVisibility(o.visib);
  // Without visibility fall back to the feed's own category.
  const category = categoryOf(ceilingFt, visibilitySm) ??
    (CATEGORIES.includes(String(o.fltCat)) ? o.fltCat as FlightCategory : null);
  if (!observedAt || !metarRaw || !category) return null;
  const taf = tafs.length ? newestTaf(tafs) : null;
  const windKt = int(num(o.wspd));
  return {
    metarRaw,
    tafRaw: taf && typeof taf.rawTAF === "string" ? taf.rawTAF : null,
    tempC: num(o.temp),
    windDirDeg: windDirDeg(o.wdir, windKt),
    windKt,
    gustKt: int(num(o.wgst)),
    visibilitySm,
    ceilingFt,
    category,
    observedAt,
    forecast: taf ? parsePeriods(taf) : [],
  };
}

/** TAF reports carry issueTime as an ISO string (bulletinTime too): newest first. */
function newestTaf(tafs: Json[]): Json {
  const t = (x: Json) =>
    Date.parse(String(x.issueTime ?? x.bulletinTime ?? "")) || 0;
  return [...tafs].sort((a, b) => t(b) - t(a))[0];
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
 * Current weather for the app. A failed METAR request is a provider failure (503), never an empty
 * snapshot; an airport with no usable METAR is 404. A missing or failed TAF only empties the forecast.
 */
export async function fetchWeather(
  icao: string,
  fetchFn: typeof fetch = fetch,
): Promise<Weather> {
  const [m, t] = await Promise.allSettled([
    getJson("metar", icao, fetchFn),
    getJson("taf", icao, fetchFn),
  ]);
  if (m.status === "rejected") {
    throw new ApiError(
      "provider_unavailable",
      503,
      "Weather provider unavailable",
    );
  }
  const w = toWeather(m.value, t.status === "fulfilled" ? t.value : []);
  if (!w) throw new ApiError("not_found", 404, "No usable METAR for airport");
  return w;
}
