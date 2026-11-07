// GET /nearby-flights?lat=37.62&lon=-122.38&radius_km=100
//   -> { box, fetched_at, stale, truncated, flights }
// The app's radar: flights in the air around a place (the user, or a chosen airport). OFF unless the
// function env RADAR_ENABLED is "true", and it needs AEROAPI_KEY: either missing answers 503
// provider_unavailable before anything else (no auth, no database, no provider call).
//
// The box around the point is clamped (MAX_RADIUS_KM) and snapped outward to a GRID_DEG grid, so one
// call is bounded and everyone looking at the same area shares one paid /flights/search read, cached
// 60 s per box in radar_cache. The call goes through the AeroApi client and its usage counter, so it
// counts in usage_counters and stops at the daily spend cap. When the provider refuses (the cap, an
// outage, its rate limit) a cached answer of any age is served with stale: true; with nothing cached
// the call fails with provider_unavailable.
import type { SupabaseClient } from "npm:@supabase/supabase-js@2";
import type { AeroApi, AeroSearchFlight } from "../_shared/aeroapi.ts";
import { requireUser, type TokenVerifier } from "../_shared/auth.ts";
import { ApiError, errorResponse, json } from "../_shared/errors.ts";
import { checkRate } from "../_shared/limits.ts";

export const CACHE_TTL_MS = 60_000;
/** Largest radius a caller can ask for: one call stays cheap and the box small. */
export const MAX_RADIUS_KM = 150;
export const MIN_RADIUS_KM = 10;
export const DEFAULT_RADIUS_KM = 100;
/** The box is snapped outward to this grid, so nearby callers share a cache row. */
export const GRID_DEG = 0.25;
/** Result sets read per refresh ($0.05 each): the most one box can cost. */
export const MAX_PAGES = 2;
/** Flights returned at most. */
export const MAX_FLIGHTS = 80;
/** Below this ground speed (knots) a position is a plane on the ground, not on the radar. */
export const MIN_AIRBORNE_KT = 40;
/** One refresh a minute while the radar is open, with room for a few area changes. */
export const RADAR_MAX_PER_HOUR = 90;

const KM_PER_DEG = 111.2;

export interface Box {
  south: number;
  west: number;
  north: number;
  east: number;
}

export interface RadarFlight {
  id: string;
  ident: string;
  operator: string | null;
  type: string | null;
  lat: number;
  lon: number;
  /** Feet. */
  altitude: number | null;
  /** Knots. */
  groundspeed: number | null;
  /** Degrees true, 0 to 359. */
  heading: number | null;
  origin: string | null;
  destination: string | null;
}

export interface Cached {
  flights: RadarFlight[];
  truncated: boolean;
  fetched_at: string;
}

export interface RadarCache {
  get(key: string): Promise<Cached | null>;
  put(key: string, value: Cached): Promise<void>;
}

export interface Deps {
  db?: SupabaseClient;
  aero: Pick<AeroApi, "searchArea">;
  cache: RadarCache;
  /** RADAR_ENABLED is "true". */
  enabled: () => boolean;
  /** AEROAPI_KEY is set. */
  hasKey: () => boolean;
  verifier?: TokenVerifier;
  /** Per-user rate limit; defaults to check_rate (RADAR_MAX_PER_HOUR). */
  rate?: (userId: string) => Promise<void>;
  now?: () => Date;
}

const snapDown = (v: number) => Math.floor(v / GRID_DEG) * GRID_DEG;
const snapUp = (v: number) => Math.ceil(v / GRID_DEG) * GRID_DEG;
const round = (v: number) => Math.round(v * 1e4) / 1e4;
const clamp = (v: number, lo: number, hi: number) =>
  Math.min(hi, Math.max(lo, v));

/**
 * The snapped box around a point: `radiusKm` is clamped to [MIN_RADIUS_KM, MAX_RADIUS_KM], the box is
 * the radius's square, snapped outward to the grid and cut at the poles and the date line. Longitude
 * degrees grow near the poles, so the half width is held to 3 degrees.
 */
export function boxAround(lat: number, lon: number, radiusKm: number): Box {
  const r = clamp(radiusKm, MIN_RADIUS_KM, MAX_RADIUS_KM);
  const dLat = r / KM_PER_DEG;
  const cos = Math.max(0.2, Math.cos((lat * Math.PI) / 180));
  const dLon = Math.min(3, r / (KM_PER_DEG * cos));
  return {
    south: round(clamp(snapDown(lat - dLat), -90, 90)),
    north: round(clamp(snapUp(lat + dLat), -90, 90)),
    west: round(clamp(snapDown(lon - dLon), -180, 180)),
    east: round(clamp(snapUp(lon + dLon), -180, 180)),
  };
}

/** "37.25_-122.5_38_-121.5": the cache key of a snapped box. */
export function cacheKey(b: Box): string {
  return `${b.south}_${b.west}_${b.north}_${b.east}`;
}

/** One provider flight as a radar flight, or null without an id, a position or a flying speed. */
export function toRadarFlight(f: AeroSearchFlight): RadarFlight | null {
  const p = f.last_position;
  const id = f.fa_flight_id;
  if (!id || !p) return null;
  if (!Number.isFinite(p.latitude) || !Number.isFinite(p.longitude)) {
    return null;
  }
  if (!(p.groundspeed >= MIN_AIRBORNE_KT)) return null;
  const ident = f.ident_iata ?? f.ident ?? f.ident_icao;
  if (!ident) return null;
  const place = (a: AeroSearchFlight["origin"]) =>
    a ? (a.code_iata ?? a.code_icao ?? a.code ?? null) : null;
  return {
    id,
    ident,
    operator: f.operator_iata ?? f.operator_icao ?? f.operator ?? null,
    type: f.aircraft_type ?? null,
    lat: round(p.latitude),
    lon: round(p.longitude),
    // AeroAPI altitude is in hundreds of feet.
    altitude: Number.isFinite(p.altitude) ? Math.round(p.altitude * 100) : null,
    groundspeed: Math.round(p.groundspeed),
    heading: p.heading != null && Number.isFinite(p.heading)
      ? ((Math.round(p.heading) % 360) + 360) % 360
      : null,
    origin: place(f.origin),
    destination: place(f.destination),
  };
}

/** The provider's flights as radar flights: one per id, busiest altitude first is not needed, ident order. */
export function toRadarFlights(rows: AeroSearchFlight[]): RadarFlight[] {
  const byId = new Map<string, RadarFlight>();
  for (const r of rows) {
    const f = toRadarFlight(r);
    if (f && !byId.has(f.id)) byId.set(f.id, f);
  }
  return [...byId.values()].sort((a, b) =>
    a.ident.localeCompare(b.ident) || a.id.localeCompare(b.id)
  ).slice(0, MAX_FLIGHTS);
}

/** radar_cache over the service role client. A failed read is an error; a failed write is logged. */
export function dbCache(db: SupabaseClient): RadarCache {
  return {
    async get(key) {
      const hit = await db.from("radar_cache").select("payload, fetched_at")
        .eq("key", key).maybeSingle();
      if (hit.error) {
        throw new Error(`radar_cache read failed: ${hit.error.message}`);
      }
      if (!hit.data) return null;
      const p = hit.data.payload as {
        flights?: RadarFlight[];
        truncated?: boolean;
      };
      return {
        flights: p.flights ?? [],
        truncated: p.truncated === true,
        fetched_at: new Date(hit.data.fetched_at).toISOString(),
      };
    },
    async put(key, v) {
      const { error } = await db.from("radar_cache").upsert({
        key,
        payload: { flights: v.flights, truncated: v.truncated },
        fetched_at: v.fetched_at,
      });
      if (error) console.error("radar_cache write failed", error.message);
    },
  };
}

const refused = (e: unknown) =>
  e instanceof ApiError &&
  (e.code === "provider_unavailable" || e.code === "rate_limited");

async function cachedRadar(
  deps: Deps,
  box: Box,
  now: Date,
): Promise<Cached & { stale: boolean }> {
  const key = cacheKey(box);
  const cached = await deps.cache.get(key);
  if (cached && now.getTime() - Date.parse(cached.fetched_at) < CACHE_TTL_MS) {
    return { ...cached, stale: false };
  }
  let fresh: Cached;
  try {
    const got = await deps.aero.searchArea(box, MAX_PAGES);
    fresh = {
      flights: toRadarFlights(got.flights),
      truncated: got.more,
      fetched_at: now.toISOString(),
    };
  } catch (e) {
    if (!refused(e)) throw e;
    console.error(
      `radar refresh refused for ${key}`,
      (e as ApiError).code,
      (e as ApiError).message,
    );
    if (cached) return { ...cached, stale: true };
    throw new ApiError(
      "provider_unavailable",
      503,
      "The radar is unavailable right now",
    );
  }
  await deps.cache.put(key, fresh);
  return { ...fresh, stale: false };
}

function number(url: URL, name: string, lo: number, hi: number): number {
  const raw = url.searchParams.get(name);
  const n = raw === null || raw.trim() === "" ? NaN : Number(raw);
  if (!Number.isFinite(n) || n < lo || n > hi) {
    throw new ApiError(
      "invalid_request",
      400,
      `${name} must be a number from ${lo} to ${hi}`,
    );
  }
  return n;
}

export async function handler(req: Request, deps: Deps): Promise<Response> {
  try {
    // Off, or no provider key: nothing else runs.
    if (!deps.enabled() || !deps.hasKey()) {
      throw new ApiError(
        "provider_unavailable",
        503,
        "The radar is not available",
      );
    }
    if (req.method !== "GET") {
      throw new ApiError("invalid_request", 405, "GET only");
    }
    const { userId } = await requireUser(req, deps.verifier);
    const now = (deps.now ?? (() => new Date()))();
    await (deps.rate ??
      ((u: string) =>
        checkRate(u, "nearby-flights", RADAR_MAX_PER_HOUR, 60, deps.db)))(
        userId,
      );

    const url = new URL(req.url);
    const lat = number(url, "lat", -90, 90);
    const lon = number(url, "lon", -180, 180);
    const radiusRaw = url.searchParams.get("radius_km");
    const radius = radiusRaw === null || radiusRaw === ""
      ? DEFAULT_RADIUS_KM
      : number(url, "radius_km", 1, 100_000); // bigger asks are clamped, not refused
    const box = boxAround(lat, lon, radius);
    const got = await cachedRadar(deps, box, now);
    return json({
      box,
      fetched_at: got.fetched_at,
      stale: got.stale,
      truncated: got.truncated,
      flights: got.flights,
    });
  } catch (e) {
    return errorResponse(e);
  }
}
