// GET /flight-insights?mode=arrival_forecast&ident=AF84 -> { ident, fetched_at, stale, forecast }
// GET /flight-insights?mode=inbound&flight_id=<uuid>   -> { flight_id, fetched_at, stale, legs }
// The flight sheet's two paid sections, in the shapes FlightKit decodes (docs/api-contract.md).
//
// arrival_forecast: how the flight number arrived lately. The provider's history is read in 7 day
// windows, newest first, until FORECAST_TARGET_FLIGHTS finished flights are seen or
// FORECAST_MAX_DAYS are covered; each finished flight falls in one bucket (early, on time, 15, 30,
// 45+ minutes late, canceled, diverted). forecast is null when no flight finished in the span.
//
// inbound: the flights the aircraft flies before this one, newest first. The chain follows each
// flight's inbound_fa_flight_id back while the leg left no more than INBOUND_HOURS before this flight's
// departure (at most INBOUND_MAX_LEGS legs). legs is empty when the provider knows no inbound flight.
//
// Every provider call goes through the AeroApi client and its spend cap. Answers are cached whole
// (forecast_cache 12 hours per ident, inbound_cache 10 minutes per flight), empty answers included, so
// repeated opens cost nothing. When the provider refuses (the daily cap, an outage, its rate limit) a
// cached answer of any age is served with stale: true; with nothing cached the call fails with
// provider_unavailable, which the app shows as the section being unavailable.
import type { SupabaseClient } from "npm:@supabase/supabase-js@2";
import {
  type AeroApi,
  HISTORY_WINDOW_DAYS,
  statusOf,
} from "../_shared/aeroapi.ts";
import type { AeroFlight } from "../_shared/aeroapi_types.ts";
import { requireUser, type TokenVerifier } from "../_shared/auth.ts";
import { ApiError, errorResponse, json } from "../_shared/errors.ts";
import { checkRate } from "../_shared/limits.ts";

export const FORECAST_TTL_MS = 12 * 3_600_000;
export const INBOUND_TTL_MS = 10 * 60_000;
export const INSIGHTS_MAX_PER_HOUR = 120;
/** Longest span the forecast reads back, in days. */
export const FORECAST_MAX_DAYS = 60;
/** Finished flights that are enough for a forecast: the walk back stops once it has them. */
export const FORECAST_TARGET_FLIGHTS = 30;
/** How far before this flight's departure the inbound chain reaches. */
export const INBOUND_HOURS = 25;
/** Most legs in a chain, so a provider loop can never run up the bill. */
export const INBOUND_MAX_LEGS = 8;

const DAY_MS = 86_400_000;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
/**
 * A designator: an IATA (two characters) or ICAO (three letters) airline code, then a number of one to
 * four figures and an optional suffix, e.g. AF84, B6417, AFR84. The cache table checks the same.
 */
const IDENT = /^([A-Z]{3}|[A-Z0-9]{2})[0-9]{1,4}[A-Z]?$/;

export interface Deps {
  db: SupabaseClient;
  aero: Pick<AeroApi, "flightHistory" | "flightById">;
  verifier?: TokenVerifier;
  now?: () => Date;
  /** Test hook: finished flights that end the walk back (FORECAST_TARGET_FLIGHTS). */
  forecastTarget?: number;
}

// MARK: Arrival forecast

export type Bucket =
  | "early"
  | "on_time"
  | "late15"
  | "late30"
  | "late45"
  | "canceled"
  | "diverted";
export const BUCKETS: readonly Bucket[] = [
  "early",
  "on_time",
  "late15",
  "late30",
  "late45",
  "canceled",
  "diverted",
];

export interface Forecast {
  ident: string;
  days: number;
  observed: number;
  late_percent: number;
  average_late_minutes: number;
  percents: Record<Bucket, number>;
}

/** The bucket of minutes after the schedule (negative is early), as ForecastBucket.of in the app. */
export function bucketOfMinutes(minutes: number): Bucket {
  if (minutes < 0) return "early";
  if (minutes < 15) return "on_time";
  if (minutes < 30) return "late15";
  if (minutes < 45) return "late30";
  return "late45";
}

/**
 * Where a past flight landed against its schedule: canceled and diverted first, then the gate
 * arrival against the scheduled one (the runway times when the gate ones are missing). Null for a
 * flight that has not finished, or whose times are missing: it is not counted.
 */
export function arrivalOf(
  f: AeroFlight,
): { bucket: Bucket; lateMinutes: number } | null {
  if (f.cancelled) return { bucket: "canceled", lateMinutes: 0 };
  if (f.diverted) return { bucket: "diverted", lateMinutes: 0 };
  const pairs: [string | null, string | null][] = [
    [f.actual_in, f.scheduled_in],
    [f.actual_on, f.scheduled_on],
  ];
  for (const [actual, scheduled] of pairs) {
    if (!actual || !scheduled) continue;
    const ms = Date.parse(actual) - Date.parse(scheduled);
    if (Number.isNaN(ms)) continue;
    const minutes = Math.round(ms / 60_000);
    return { bucket: bucketOfMinutes(minutes), lateMinutes: minutes };
  }
  return null;
}

/** Whole percents that add up to exactly 100 (largest remainder, ties in bucket order). */
export function percentages(
  counts: Record<Bucket, number>,
): Record<Bucket, number> {
  const total = BUCKETS.reduce((n, b) => n + counts[b], 0);
  const out = Object.fromEntries(BUCKETS.map((b) => [b, 0])) as Record<
    Bucket,
    number
  >;
  if (total === 0) return out;
  const rest: { b: Bucket; r: number }[] = [];
  for (const b of BUCKETS) {
    const w = counts[b] * 100;
    out[b] = Math.floor(w / total);
    rest.push({ b, r: w % total });
  }
  let missing = 100 - BUCKETS.reduce((n, b) => n + out[b], 0);
  for (const { b } of rest.sort((x, y) => y.r - x.r)) {
    if (missing <= 0) break;
    out[b] += 1;
    missing -= 1;
  }
  return out;
}

/**
 * The forecast over `flights` (deduped by the caller): null when none of them finished.
 * late_percent is the three late buckets together; average_late_minutes is the mean delay of the
 * flights 15 minutes late or more (0 when there is none).
 */
export function buildForecast(
  ident: string,
  flights: AeroFlight[],
  days: number,
): Forecast | null {
  const counts = Object.fromEntries(BUCKETS.map((b) => [b, 0])) as Record<
    Bucket,
    number
  >;
  const late: number[] = [];
  for (const f of flights) {
    const a = arrivalOf(f);
    if (!a) continue;
    counts[a.bucket] += 1;
    if (a.lateMinutes >= 15) late.push(a.lateMinutes);
  }
  const observed = BUCKETS.reduce((n, b) => n + counts[b], 0);
  if (observed === 0) return null;
  const percents = percentages(counts);
  return {
    ident,
    days,
    observed,
    late_percent: percents.late15 + percents.late30 + percents.late45,
    average_late_minutes: late.length
      ? Math.round(late.reduce((a, b) => a + b, 0) / late.length)
      : 0,
    percents,
  };
}

/**
 * Walks the history back from `now` in 7 day windows (the provider's longest), newest first, and
 * stops at `target` finished flights or `FORECAST_MAX_DAYS`. A flight that appears in two windows
 * is counted once (its diverted row wins, as in dedupeByFaFlightId).
 */
async function fetchForecast(
  aero: Deps["aero"],
  ident: string,
  now: Date,
  target: number,
): Promise<Forecast | null> {
  const seen = new Map<string, AeroFlight>();
  let finished = 0;
  let days = 0;
  while (days < FORECAST_MAX_DAYS && finished < target) {
    const span = Math.min(HISTORY_WINDOW_DAYS, FORECAST_MAX_DAYS - days);
    const end = new Date(now.getTime() - days * DAY_MS);
    const start = new Date(end.getTime() - span * DAY_MS);
    for (const f of await aero.flightHistory(ident, start, end)) {
      const prev = seen.get(f.fa_flight_id);
      if (prev?.diverted && !f.diverted) continue;
      if (!prev && arrivalOf(f)) finished += 1;
      seen.set(f.fa_flight_id, f);
    }
    days += span;
  }
  return buildForecast(ident, [...seen.values()], days);
}

// MARK: Inbound chain

export interface Leg {
  id: string;
  ident: string;
  origin_iata: string;
  destination_iata: string;
  scheduled_out: string;
  scheduled_in: string;
  status: string;
  delay_minutes: number;
}

const codeOf = (a: AeroFlight["origin"]) =>
  a?.code_iata ?? a?.code_icao ?? a?.code ?? null;

/**
 * One provider flight as an inbound leg. delay_minutes is the arrival against the schedule (the actual
 * time, else the estimate; the gate time, else the runway time), never below 0. Null when the
 * provider lacks an airport code or a scheduled time: the app cannot draw such a leg.
 */
export function toLeg(f: AeroFlight): Leg | null {
  const origin = codeOf(f.origin), destination = codeOf(f.destination);
  const out = f.scheduled_out ?? f.scheduled_off;
  const sin = f.scheduled_in ?? f.scheduled_on;
  if (!origin || !destination || !out || !sin) return null;
  const arrival = f.actual_in ?? f.estimated_in;
  const runway = f.actual_on ?? f.estimated_on;
  let delay = 0;
  if (arrival && f.scheduled_in) {
    delay = Date.parse(arrival) - Date.parse(f.scheduled_in);
  } else if (runway && f.scheduled_on) {
    delay = Date.parse(runway) - Date.parse(f.scheduled_on);
  }
  return {
    id: f.fa_flight_id,
    ident: f.ident_iata ?? f.ident,
    origin_iata: origin,
    destination_iata: destination,
    scheduled_out: new Date(out).toISOString(),
    scheduled_in: new Date(sin).toISOString(),
    status: statusOf(f),
    delay_minutes: Number.isNaN(delay)
      ? 0
      : Math.max(0, Math.round(delay / 60_000)),
  };
}

/**
 * Follows inbound_fa_flight_id back from the flight `providerId`. The first call reads the flight
 * itself (its inbound id is not stored); each next call one leg. The walk stops at a leg that left
 * more than INBOUND_HOURS before `departure`, a leg the provider does not know or the app cannot draw,
 * a loop, or INBOUND_MAX_LEGS legs.
 */
async function fetchInbound(
  aero: Deps["aero"],
  providerId: string,
  departure: Date,
): Promise<Leg[]> {
  const self = await aero.flightById(providerId);
  const cutoff = departure.getTime() - INBOUND_HOURS * 3_600_000;
  const legs: Leg[] = [];
  const seen = new Set<string>([providerId]);
  let next = self?.inbound_fa_flight_id ?? null;
  while (next && !seen.has(next) && legs.length < INBOUND_MAX_LEGS) {
    seen.add(next);
    const f = await aero.flightById(next);
    const leg = f ? toLeg(f) : null;
    if (!f || !leg || Date.parse(leg.scheduled_out) < cutoff) break;
    legs.push(leg);
    next = f.inbound_fa_flight_id ?? null;
  }
  return legs;
}

// MARK: Cache

interface Cached {
  payload: Record<string, unknown>;
  fetchedAt: string;
}

async function readCache(
  db: SupabaseClient,
  table: "forecast_cache" | "inbound_cache",
  column: "ident" | "flight_id",
  key: string,
): Promise<Cached | null> {
  const { data, error } = await db.from(table).select("payload, fetched_at")
    .eq(column, key).maybeSingle();
  if (error) throw new Error(`${table} read failed: ${error.message}`);
  return data
    ? {
      payload: data.payload as Record<string, unknown>,
      fetchedAt: new Date(data.fetched_at).toISOString(),
    }
    : null;
}

/** A failed write is logged, never a failed answer: the caller already has what it paid for. */
async function writeCache(
  db: SupabaseClient,
  table: "forecast_cache" | "inbound_cache",
  row: Record<string, unknown>,
) {
  const { error } = await db.from(table).upsert(row);
  if (error) console.error(`${table} write failed`, error.message);
}

/** Provider refusals a stale answer can stand in for. */
const refused = (e: unknown) =>
  e instanceof ApiError &&
  (e.code === "provider_unavailable" || e.code === "rate_limited");

/**
 * The cached payload when fresher than `ttl`; else `fetch` (then cached). A refused fetch serves the
 * cached payload of any age as stale, or throws provider_unavailable with nothing cached.
 */
async function cached(
  deps: Deps,
  table: "forecast_cache" | "inbound_cache",
  column: "ident" | "flight_id",
  key: string,
  ttl: number,
  now: Date,
  fetch: () => Promise<Record<string, unknown>>,
): Promise<
  { payload: Record<string, unknown>; fetched_at: string; stale: boolean }
> {
  const hit = await readCache(deps.db, table, column, key);
  if (hit && now.getTime() - Date.parse(hit.fetchedAt) < ttl) {
    return { payload: hit.payload, fetched_at: hit.fetchedAt, stale: false };
  }
  let payload: Record<string, unknown>;
  try {
    payload = await fetch();
  } catch (e) {
    if (!refused(e)) throw e;
    console.error(
      `${table} refresh refused for ${key}`,
      (e as ApiError).code,
      (e as ApiError).message,
    );
    if (hit) {
      return { payload: hit.payload, fetched_at: hit.fetchedAt, stale: true };
    }
    throw new ApiError(
      "provider_unavailable",
      503,
      "Insights are unavailable right now",
    );
  }
  const fetchedAt = now.toISOString();
  await writeCache(deps.db, table, {
    [column]: key,
    payload,
    fetched_at: fetchedAt,
  });
  return { payload, fetched_at: fetchedAt, stale: false };
}

// MARK: Handler

export async function handler(req: Request, deps: Deps): Promise<Response> {
  try {
    if (req.method !== "GET") {
      throw new ApiError("invalid_request", 405, "GET only");
    }
    const { userId } = await requireUser(req, deps.verifier);
    const { db, aero } = deps;
    const now = (deps.now ?? (() => new Date()))();
    await checkRate(
      userId,
      "flight-insights",
      INSIGHTS_MAX_PER_HOUR,
      60,
      db,
    );

    const url = new URL(req.url);
    const mode = url.searchParams.get("mode");
    if (mode === "arrival_forecast") {
      const ident = (url.searchParams.get("ident") ?? "").replace(/\s+/g, "")
        .toUpperCase();
      if (!IDENT.test(ident)) {
        throw new ApiError(
          "invalid_request",
          400,
          "ident must be a flight number such as AF84",
        );
      }
      const target = deps.forecastTarget ?? FORECAST_TARGET_FLIGHTS;
      const got = await cached(
        deps,
        "forecast_cache",
        "ident",
        ident,
        FORECAST_TTL_MS,
        now,
        async () => ({
          forecast: await fetchForecast(aero, ident, now, target),
        }),
      );
      return json({
        ident,
        fetched_at: got.fetched_at,
        stale: got.stale,
        forecast: got.payload.forecast ?? null,
      });
    }
    if (mode === "inbound") {
      const flightId = url.searchParams.get("flight_id") ?? "";
      if (!UUID.test(flightId)) {
        throw new ApiError("invalid_request", 400, "flight_id must be a uuid");
      }
      const row = await db.from("flights")
        .select("id, provider_id, scheduled_out").eq("id", flightId)
        .maybeSingle();
      if (row.error) {
        throw new Error(`flight read failed: ${row.error.message}`);
      }
      if (!row.data) throw new ApiError("not_found", 404, "Unknown flight");
      const flight = row.data as {
        id: string;
        provider_id: string;
        scheduled_out: string | null;
      };
      const departure = flight.scheduled_out
        ? new Date(flight.scheduled_out)
        : now;
      const got = await cached(
        deps,
        "inbound_cache",
        "flight_id",
        flight.id,
        INBOUND_TTL_MS,
        now,
        async () => ({
          legs: await fetchInbound(aero, flight.provider_id, departure),
        }),
      );
      return json({
        flight_id: flight.id,
        fetched_at: got.fetched_at,
        stale: got.stale,
        legs: Array.isArray(got.payload.legs) ? got.payload.legs : [],
      });
    }
    throw new ApiError(
      "invalid_request",
      400,
      "mode must be arrival_forecast or inbound",
    );
  } catch (e) {
    return errorResponse(e);
  }
}
