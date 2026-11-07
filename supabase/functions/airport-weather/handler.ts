// GET /airport-weather?airports=SFO,JFK,LHR -> { fetched_at, airports: [{ icao, iata, weather, faa }] }
// The free half of the Airports list and the airport card's status: the latest METAR of each airport,
// decoded (flight category from ceiling and visibility, wind, gusts, temperature, the sky or weather in
// plain words), and the FAA's live programs at US airports. Both sources are free and public:
// aviationweather.gov (NOAA) and the FAA NAS status feed (faa-status shares its cache).
//
// One request to aviationweather.gov covers every airport not in the cache (`ids=KSFO,KJFK`). Answers
// are kept per airport for CACHE_TTL_MS in the isolate, airports without a METAR too, so a list
// refreshing every few minutes asks NOAA at most once per airport per 10 minutes per isolate. When NOAA
// fails, a kept answer up to STALE_MAX_MS old is served (stale: true); older, weather is null. The
// answer carries Cache-Control so the app's URL cache can reuse it for a few minutes.
//
// With `forecast=1` each airport also carries its TAF (any airport worldwide that has one) decoded into
// periods with plain words, read from aviationweather.gov in the same kind of one batch request and kept
// the same way (10 minutes, stale up to an hour). The list leaves it out.
//
// 1 to MAX_AIRPORTS codes, IATA or ICAO; unknown codes are left out of the answer. Signed in only,
// WEATHER_MAX_PER_HOUR calls per user per hour.
import type { SupabaseClient } from "npm:@supabase/supabase-js@2";
import {
  type AirportRow,
  airportRows,
  inAskedOrder,
  parseCodes,
} from "../_shared/airport_codes.ts";
import { requireUser, type TokenVerifier } from "../_shared/auth.ts";
import { ApiError, errorResponse } from "../_shared/errors.ts";
import type { Program } from "../_shared/faa_nas.ts";
import { checkRate } from "../_shared/limits.ts";
import { FAA_COUNTRIES, sameAirport } from "../faa-status/handler.ts";
import { conditionWords, weatherSentence } from "../_shared/metar_words.ts";
import { periodWords } from "../_shared/taf_words.ts";
import {
  type CloudLayer,
  type Forecast,
  type ForecastPeriod,
  toForecast,
  toWeather,
  WEATHER_BASE,
  WEATHER_TIMEOUT_MS,
  WEATHER_USER_AGENT,
} from "../_shared/weather.ts";
import type { FlightCategory } from "../_shared/flightcore.ts";

export const MAX_AIRPORTS = 40;
export const CACHE_TTL_MS = 10 * 60_000;
export const STALE_MAX_MS = 60 * 60_000;
export const WEATHER_MAX_PER_HOUR = 120;
/** What the app's URL cache may reuse. Private: the answer follows a signed-in request. */
export const CACHE_CONTROL = "private, max-age=300";

/** Wire shape of one airport's weather: FlightKit `AirportConditions`. */
export interface Conditions {
  category: FlightCategory;
  ceiling_ft: number | null;
  visibility_sm: number | null;
  wind_dir_deg: number | null;
  wind_kt: number | null;
  gust_kt: number | null;
  temp_c: number | null;
  /** Present weather groups ("-RA BR"), null when none. */
  wx: string | null;
  /** "Light rain", "Partly cloudy". */
  condition: string;
  /** "Partly cloudy with light winds." */
  summary: string;
  observed_at: string;
  metar_raw: string;
  /** True when NOAA did not answer and this is an older read (at most an hour). */
  stale: boolean;
}

/** One TAF period in the answer, with its words: FlightKit-style fields in snake_case. */
export interface ForecastItem {
  from: string;
  to: string;
  category: FlightCategory;
  wind_dir_deg: number | null;
  wind_kt: number | null;
  gust_kt: number | null;
  visibility_sm: number | null;
  ceiling_ft: number | null;
  /** FM, BECMG, TEMPO or PROB; null for the base forecast. */
  change: ForecastPeriod["change"];
  probability: number | null;
  wx: string | null;
  /** "Light rain, wind 12 kt gusting 25 kt, visibility 3 mi" in plain words. */
  summary: string;
}

/** The terminal forecast (TAF) of an airport, asked for with `forecast=1`. */
export interface ForecastPart {
  issued_at: string | null;
  taf_raw: string | null;
  periods: ForecastItem[];
  /** True when NOAA did not answer and this is an older read (at most an hour). */
  stale: boolean;
}

export interface FaaPart {
  stale: boolean;
  fetched_at: string;
  programs: Program[];
}

export interface AirportAnswer {
  icao: string;
  iata: string | null;
  /** Null when the airport has no recent METAR, or NOAA is down with nothing kept. */
  weather: Conditions | null;
  /** Null outside the US, or when the FAA feed is down with nothing kept. */
  faa: FaaPart | null;
  /**
   * The TAF, only when the request said `forecast=1` (the list leaves it out). Null when the airport has
   * no TAF (many small ones have none), or NOAA is down with nothing kept.
   */
  forecast?: ForecastPart | null;
}

export interface Answer {
  fetched_at: string;
  airports: AirportAnswer[];
}

type Json = Record<string, unknown>;

/** The FAA feed as faa-status serves it (cached 5 minutes for everyone). */
export type FaaFeed = (
  now: Date,
) => Promise<{ programs: Program[]; fetched_at: string; stale: boolean }>;

export interface Deps {
  verifier?: TokenVerifier;
  now?: () => Date;
  fetchFn?: typeof fetch;
  /** Rows for the asked codes. */
  airports: (codes: string[]) => Promise<AirportRow[]>;
  /** The FAA feed; nil answers faa: null everywhere. */
  faa?: FaaFeed;
  /** Per-user rate limit; throws rate_limited. */
  rate?: (userId: string) => Promise<void>;
  cache?: WeatherCache;
  /** Kept TAFs, for `forecast=1`. */
  forecastCache?: ForecastCache;
}

/** Kept answers per ICAO: a decoded METAR (or TAF), or null for an airport with none. */
export class KeptCache<T> {
  private entries = new Map<string, { at: number; value: T | null }>();

  get(icao: string) {
    return this.entries.get(icao);
  }

  set(icao: string, at: number, value: T | null) {
    this.entries.set(icao, { at, value });
    // A long-lived isolate keeps at most a few thousand airports.
    if (this.entries.size > 5000) {
      const oldest = [...this.entries.entries()].sort((a, b) =>
        a[1].at - b[1].at
      )[0];
      if (oldest) this.entries.delete(oldest[0]);
    }
  }
}

export class WeatherCache extends KeptCache<Conditions> {}
export class ForecastCache extends KeptCache<ForecastPart> {}

const shared = new WeatherCache();
const sharedForecasts = new ForecastCache();

/** One METAR observation decoded into the wire shape; null when it cannot fill the required fields. */
export function toConditions(o: Json): Conditions | null {
  const w = toWeather([o], []);
  if (!w) return null;
  const clouds: CloudLayer[] = w.clouds;
  return {
    category: w.category,
    ceiling_ft: w.ceilingFt,
    visibility_sm: w.visibilitySm,
    wind_dir_deg: w.windDirDeg,
    wind_kt: w.windKt,
    gust_kt: w.gustKt,
    temp_c: w.tempC,
    wx: w.wx,
    condition: conditionWords(w.wx, clouds),
    summary: weatherSentence(w.wx, clouds, w.windKt, w.gustKt),
    observed_at: w.observedAt,
    metar_raw: w.metarRaw,
    stale: false,
  };
}

/** The newest observation per station from one batch answer. */
export function newestByStation(list: Json[]): Map<string, Json> {
  const out = new Map<string, Json>();
  for (const o of list) {
    const id = typeof o.icaoId === "string" ? o.icaoId.toUpperCase() : null;
    if (!id) continue;
    const prev = out.get(id);
    if (!prev || Number(o.obsTime ?? 0) > Number(prev.obsTime ?? 0)) {
      out.set(id, o);
    }
  }
  return out;
}

/** One batch request for these stations. Throws on a failed request. */
async function fetchBatch(
  kind: "metar" | "taf",
  icaos: string[],
  fetchFn: typeof fetch,
): Promise<Json[]> {
  const url = `${WEATHER_BASE}/${kind}?ids=${
    encodeURIComponent(icaos.join(","))
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
 * The shared read-through: fresh kept answers as they are, the rest in one request (`load`). A failed
 * request serves what is kept (up to STALE_MAX_MS, marked stale by `stale`) and null for the rest.
 */
async function keptBatch<T>(
  label: string,
  icaos: string[],
  now: Date,
  cache: KeptCache<T>,
  load: (missing: string[]) => Promise<Map<string, T | null>>,
  stale: (v: T) => T,
): Promise<Map<string, T | null>> {
  const t = now.getTime();
  const out = new Map<string, T | null>();
  const missing: string[] = [];
  for (const icao of icaos) {
    const hit = cache.get(icao);
    if (hit && t - hit.at < CACHE_TTL_MS) out.set(icao, hit.value);
    else missing.push(icao);
  }
  if (missing.length === 0) return out;
  try {
    const loaded = await load(missing);
    for (const icao of missing) {
      const value = loaded.get(icao) ?? null;
      cache.set(icao, t, value);
      out.set(icao, value);
    }
  } catch (e) {
    console.error(
      `airport-weather: ${label} read failed`,
      e instanceof Error ? e.message : e,
    );
    for (const icao of missing) {
      const hit = cache.get(icao);
      out.set(
        icao,
        hit?.value && t - hit.at < STALE_MAX_MS ? stale(hit.value) : null,
      );
    }
  }
  return out;
}

/**
 * Weather for each ICAO: fresh kept answers as they are, the rest in one request. A failed request
 * serves what is kept (up to STALE_MAX_MS, marked stale) and null for the rest.
 */
export function weatherFor(
  icaos: string[],
  now: Date,
  fetchFn: typeof fetch,
  cache: WeatherCache,
): Promise<Map<string, Conditions | null>> {
  return keptBatch(
    "METAR",
    icaos,
    now,
    cache,
    async (missing) => {
      const byStation = newestByStation(
        await fetchBatch("metar", missing, fetchFn),
      );
      const m = new Map<string, Conditions | null>();
      for (const icao of missing) {
        const o = byStation.get(icao);
        m.set(icao, o ? toConditions(o) : null);
      }
      return m;
    },
    (v) => ({ ...v, stale: true }),
  );
}

/** One station's TAF decoded into the answer's shape, with plain words per period. */
export function toForecastPart(f: Forecast): ForecastPart {
  return {
    issued_at: f.issuedAt,
    taf_raw: f.tafRaw,
    periods: f.periods.map((p) => ({
      from: p.from,
      to: p.to,
      category: p.category,
      wind_dir_deg: p.windDirDeg,
      wind_kt: p.windKt,
      gust_kt: p.gustKt,
      visibility_sm: p.visibilitySm,
      ceiling_ft: p.ceilingFt,
      change: p.change,
      probability: p.probability,
      wx: p.wx,
      summary: periodWords(p),
    })),
    stale: false,
  };
}

/** The TAF of each ICAO (any airport worldwide that has one), read and kept like the METAR. */
export function forecastFor(
  icaos: string[],
  now: Date,
  fetchFn: typeof fetch,
  cache: ForecastCache,
): Promise<Map<string, ForecastPart | null>> {
  return keptBatch(
    "TAF",
    icaos,
    now,
    cache,
    async (missing) => {
      const list = await fetchBatch("taf", missing, fetchFn);
      const m = new Map<string, ForecastPart | null>();
      for (const icao of missing) {
        const mine = list.filter((x) =>
          typeof x.icaoId === "string" && x.icaoId.toUpperCase() === icao
        );
        const f = toForecast(mine);
        m.set(icao, f ? toForecastPart(f) : null);
      }
      return m;
    },
    (v) => ({ ...v, stale: true }),
  );
}

export async function handler(req: Request, deps: Deps): Promise<Response> {
  try {
    if (req.method !== "GET") {
      throw new ApiError("invalid_request", 405, "GET only");
    }
    const { userId } = await requireUser(req, deps.verifier);
    await deps.rate?.(userId);
    const now = (deps.now ?? (() => new Date()))();
    const url = new URL(req.url);
    const codes = parseCodes(
      url.searchParams.get("airports") ?? url.searchParams.get("airport"),
      MAX_AIRPORTS,
    );
    const rows = inAskedOrder(codes, await deps.airports(codes));
    const weather = await weatherFor(
      rows.map((r) => r.icao),
      now,
      deps.fetchFn ?? fetch,
      deps.cache ?? shared,
    );
    const wantsForecast = ["1", "true"].includes(
      url.searchParams.get("forecast") ?? "",
    );
    const forecasts = wantsForecast
      ? await forecastFor(
        rows.map((r) => r.icao),
        now,
        deps.fetchFn ?? fetch,
        deps.forecastCache ?? sharedForecasts,
      )
      : null;
    const us = rows.some((r) => FAA_COUNTRIES.has(r.country ?? ""));
    let feed: Awaited<ReturnType<FaaFeed>> | null = null;
    if (us && deps.faa) {
      try {
        feed = await deps.faa(now);
      } catch (e) {
        // The list still shows the weather when the FAA is down.
        console.error(
          "airport-weather: FAA feed failed",
          e instanceof Error ? e.message : e,
        );
      }
    }
    const answer: Answer = {
      fetched_at: now.toISOString(),
      airports: rows.map((r) => ({
        icao: r.icao,
        iata: r.iata,
        weather: weather.get(r.icao) ?? null,
        ...(forecasts ? { forecast: forecasts.get(r.icao) ?? null } : {}),
        faa: feed && FAA_COUNTRIES.has(r.country ?? "")
          ? {
            stale: feed.stale,
            fetched_at: feed.fetched_at,
            programs: feed.programs.filter((p) => sameAirport(p.airport, r)),
          }
          : null,
      })),
    };
    return new Response(JSON.stringify(answer), {
      headers: {
        "content-type": "application/json",
        "cache-control": CACHE_CONTROL,
      },
    });
  } catch (e) {
    return errorResponse(e);
  }
}

/** The production wiring: the airports table, the shared FAA cache, the rate limit. */
export function liveDeps(db: SupabaseClient, faa: FaaFeed): Deps {
  return {
    airports: (codes) => airportRows(db, codes),
    faa,
    rate: (userId) =>
      checkRate(userId, "airport-weather", WEATHER_MAX_PER_HOUR, 60, db),
  };
}
