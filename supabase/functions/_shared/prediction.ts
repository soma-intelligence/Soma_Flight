// The predicted delay alert: "AF 84 likely 25m late" before the airline moves its estimate, once per
// flight, at medium or high confidence (core predict.rs decides the minutes, reason and confidence).
//
// Nothing here calls a provider. The inputs are what the backend already holds:
//   * the inbound leg's flights row when it is in flights (push-sender's inboundOf), else the cached
//     inbound chain (inbound_cache, written when someone opened the flight sheet), when recent;
//   * the cached arrival forecast of the flight number (forecast_cache);
//   * the origin's departures stats and both airports' weather (airport_snapshots), when recent.
// A missing or stale cache is a missing signal, never a failure.
import type { SupabaseClient } from "npm:@supabase/supabase-js@2";
import {
  type Alert,
  type AlertFlight,
  type AlertHistory,
  CATEGORY,
} from "./alerts.ts";
import {
  type Affects,
  type DelayInput,
  type DelayPrediction,
  type FlightStatus,
  type ImpactLevel,
  predictDelay,
  weatherImpact,
} from "./flightcore.ts";

/** A cached JSON payload and when it was fetched. */
export interface Cached {
  payload: Record<string, unknown>;
  fetchedAt: string;
}

/** The caches the prediction reads. */
export interface PredictionCaches {
  /** inbound_cache: the inbound chain of a flights row, newest leg first. */
  inbound(flightId: string): Promise<Cached | null>;
  /** forecast_cache: how the flight number arrived lately. */
  forecast(ident: string): Promise<Cached | null>;
  /** airport_snapshots of one airport. */
  snapshot(icao: string, kind: "stats" | "weather"): Promise<Cached | null>;
}

/** A cached inbound chain older than this may describe a plane that has moved on. */
export const INBOUND_MAX_AGE_MS = 30 * 60_000;
/** A board older than this says little about the airport now. */
export const STATS_MAX_AGE_MS = 30 * 60_000;
/** Weather snapshots (the METAR and the TAF in it). */
export const WEATHER_MAX_AGE_MS = 2 * 3_600_000;
/** The current observation speaks for a time this close to now; beyond it only a TAF period does. */
export const METAR_HORIZON_MS = 3 * 3_600_000;

/** The flights columns the prediction reads, on top of the alert ones. */
export type PredictionFlight = AlertFlight & {
  id: string;
  aircraft_type?: string | null;
};

const ms = (v: unknown): number | null => {
  if (typeof v !== "string" || v === "") return null;
  const t = Date.parse(v);
  return Number.isFinite(t) ? t : null;
};

const num = (v: unknown): number | null =>
  typeof v === "number" && Number.isFinite(v) ? v : null;

const str = (v: unknown): string | null =>
  typeof v === "string" && v !== "" ? v : null;

const fresh = (c: Cached | null, maxAge: number, now: number) =>
  c !== null && now - Date.parse(c.fetchedAt) <= maxAge;

const MOVING = new Set(["departed", "en_route", "landed", "arrived"]);
const LEVELS: ImpactLevel[] = ["none", "minor", "moderate", "severe"];

/** The caches in the database, read as the service role. A failed read is a missing cache. */
export function cachesFrom(db: SupabaseClient): PredictionCaches {
  const one = async (
    table: string,
    column: string,
    value: string,
    extra?: [string, string],
  ): Promise<Cached | null> => {
    let q = db.from(table).select("payload, fetched_at").eq(column, value);
    if (extra) q = q.eq(extra[0], extra[1]);
    const { data, error } = await q.maybeSingle();
    if (error) {
      console.error(`prediction: ${table} read failed: ${error.message}`);
      return null;
    }
    return data
      ? {
        payload: (data.payload ?? {}) as Record<string, unknown>,
        fetchedAt: new Date(data.fetched_at).toISOString(),
      }
      : null;
  };
  return {
    inbound: (id) => one("inbound_cache", "flight_id", id),
    forecast: (ident) => one("forecast_cache", "ident", ident),
    snapshot: (icao, kind) =>
      one("airport_snapshots", "icao", icao, ["kind", kind]),
  };
}

/**
 * The inbound signal: the live row of the leg when push-sender has it and it ends where this flight
 * starts, else the newest leg of a recent cached chain that does.
 */
export function inboundSignal(
  flight: PredictionFlight,
  row: AlertFlight | null,
  cached: Cached | null,
  now: number,
): DelayInput["inbound"] {
  if (
    row && !["canceled", "diverted"].includes(row.status) &&
    (!row.destination_icao || !flight.origin_icao ||
      row.destination_icao === flight.origin_icao)
  ) {
    const arrival = ms(row.actual_in) ?? ms(row.estimated_in) ??
      ms(row.scheduled_in);
    if (arrival !== null) {
      return {
        arrival: Math.floor(arrival / 1000),
        departed: row.actual_out != null || row.actual_off != null ||
          MOVING.has(row.status),
      };
    }
  }
  if (!fresh(cached, INBOUND_MAX_AGE_MS, now)) return null;
  const legs = cached!.payload.legs;
  if (!Array.isArray(legs) || legs.length === 0) return null;
  const leg = legs[0] as Record<string, unknown>;
  const status = str(leg.status) ?? "unknown";
  if (status === "canceled" || status === "diverted") return null;
  const dest = str(leg.destination_iata);
  const origin = flight.origin_iata ?? null;
  if (dest && origin && dest !== origin) return null;
  const scheduledIn = ms(leg.scheduled_in);
  if (scheduledIn === null) return null;
  const delay = Math.max(0, num(leg.delay_minutes) ?? 0);
  return {
    arrival: Math.floor((scheduledIn + delay * 60_000) / 1000),
    departed: MOVING.has(status),
  };
}

/** The flight number's arrival record from a cached forecast. */
export function historySignal(cached: Cached | null): DelayInput["history"] {
  const f = cached?.payload.forecast as Record<string, unknown> | null;
  if (!f || typeof f !== "object") return null;
  const observed = num(f.observed),
    late = num(f.late_percent),
    avg = num(f.average_late_minutes);
  if (observed === null || late === null || avg === null) return null;
  return {
    observed: Math.max(0, Math.round(observed)),
    latePercent: Math.max(0, Math.round(late)),
    averageLateMinutes: Math.max(0, Math.round(avg)),
  };
}

/** The origin's departures from a recent stats snapshot. */
export function boardSignal(
  cached: Cached | null,
  now: number,
): DelayInput["board"] {
  if (!fresh(cached, STATS_MAX_AGE_MS, now)) return null;
  const d = cached!.payload.departures as Record<string, unknown> | null;
  if (!d || typeof d !== "object") return null;
  const total = num(d.total),
    delayed = num(d.delayed15),
    avg = num(d.avgDelayMinutes);
  if (total === null || delayed === null || avg === null) return null;
  return {
    total: Math.max(0, Math.round(total)),
    delayed15: Math.max(0, Math.round(delayed)),
    avgDelayMinutes: avg,
  };
}

type Conditions = Record<string, unknown>;

function impactOf(c: Conditions, wx: string) {
  return weatherImpact({
    ceilingFt: num(c.ceilingFt),
    visibilitySm: num(c.visibilitySm),
    windKt: num(c.windKt),
    gustKt: num(c.gustKt),
    wx,
  });
}

/**
 * The weather impact at an airport around `at` (ms): the worst TAF period in force then, else the
 * current observation when `at` is within METAR_HORIZON_MS of now. The app reads its own copy the same
 * way (`Weather.forecastImpact(at:)`, then `WeatherImpact.of(_:)`).
 */
export function weatherSignal(
  cached: Cached | null,
  at: number | null,
  now: number,
): DelayInput["originWeather"] {
  if (at === null || !fresh(cached, WEATHER_MAX_AGE_MS, now)) return null;
  const w = cached!.payload.weather as Conditions | null;
  if (!w || typeof w !== "object") return null;
  const periods = Array.isArray(w.forecast) ? w.forecast as Conditions[] : [];
  let best: { level: ImpactLevel; affects: Affects | null } | null = null;
  for (const p of periods) {
    const from = ms(p.from), to = ms(p.to);
    if (from === null || to === null || at < from || at >= to) continue;
    const i = impactOf(p, str(p.wx) ?? "");
    if (!best || LEVELS.indexOf(i.level) > LEVELS.indexOf(best.level)) {
      best = { level: i.level, affects: i.affects };
    }
  }
  if (best) return best;
  if (Math.abs(at - now) > METAR_HORIZON_MS) return null;
  const i = impactOf(w, str(w.wx) ?? str(w.metarRaw) ?? "");
  return { level: i.level, affects: i.affects };
}

/** Everything predictDelay reads for `flight`, from `inbound` (its live row) and the caches. */
export async function delayInputOf(
  flight: PredictionFlight,
  inbound: AlertFlight | null,
  caches: PredictionCaches,
  now: Date,
): Promise<DelayInput | null> {
  const scheduledOut = ms(flight.scheduled_out);
  if (scheduledOut === null) return null;
  const t = now.getTime();
  const departure = ms(flight.estimated_out) ?? scheduledOut;
  const arrival = ms(flight.estimated_in) ?? ms(flight.scheduled_in);
  const [chain, forecast, stats, originWx, destWx] = await Promise.all([
    caches.inbound(flight.id),
    caches.forecast(flight.ident),
    flight.origin_icao ? caches.snapshot(flight.origin_icao, "stats") : null,
    flight.origin_icao ? caches.snapshot(flight.origin_icao, "weather") : null,
    flight.destination_icao
      ? caches.snapshot(flight.destination_icao, "weather")
      : null,
  ]);
  const estimatedOut = ms(flight.estimated_out);
  return {
    status: flight.status as FlightStatus,
    scheduledOut: Math.floor(scheduledOut / 1000),
    estimatedOut: estimatedOut === null
      ? null
      : Math.floor(estimatedOut / 1000),
    now: Math.floor(t / 1000),
    aircraftType: flight.aircraft_type ?? null,
    originCode: flight.origin_iata ?? flight.origin_icao ?? "the origin",
    destinationCode: flight.destination_iata ?? flight.destination_icao ??
      "the destination",
    inbound: inboundSignal(flight, inbound, chain, t),
    history: historySignal(forecast),
    board: boardSignal(stats, t),
    originWeather: weatherSignal(originWx, departure, t),
    destinationWeather: weatherSignal(destWx, arrival, t),
  };
}

/** Fixed key: the prediction is announced once per flight. */
export const PREDICTED_DELAY_KEY = "predicted_delay";

/**
 * The alert a prediction is worth: medium or high confidence only, once per flight, and only while
 * the user has heard of no delay yet (no departure delay sent). A late inbound prediction is left out
 * when the inbound late alert goes now or went before: it would say the same thing twice.
 */
export function predictedDelayAlert(
  p: DelayPrediction | null,
  history: AlertHistory,
  pending: Alert[] = [],
): Alert | null {
  if (!p || p.confidence === "low") return null;
  if (history.keys.has(PREDICTED_DELAY_KEY)) return null;
  if (history.lastDelay.departure !== null) return null;
  if (pending.some((a) => a.kind === "departure_delay")) return null;
  if (
    p.reason === "lateInbound" &&
    (history.keys.has("inbound_late") ||
      pending.some((a) => a.kind === "inbound_late"))
  ) return null;
  return {
    kind: "predicted_delay",
    category: CATEGORY.predicted_delay,
    key: PREDICTED_DELAY_KEY,
    side: "departure",
    minutes: p.minutes,
    note: p.summary,
    reason: p.reason,
  };
}

/**
 * The predicted delay alert for `flight`, or null. Never throws: a prediction is a nicety, and
 * push-sender's real alerts must go out whatever happens here.
 */
export async function predictedDelay(
  flight: PredictionFlight,
  inbound: AlertFlight | null,
  history: AlertHistory,
  pending: Alert[],
  caches: PredictionCaches,
  now: Date,
): Promise<Alert | null> {
  try {
    if (history.keys.has(PREDICTED_DELAY_KEY)) return null;
    if (flight.status !== "scheduled" && flight.status !== "unknown") {
      return null;
    }
    const input = await delayInputOf(flight, inbound, caches, now);
    if (!input) return null;
    return predictedDelayAlert(predictDelay(input), history, pending);
  } catch (e) {
    console.error(
      `prediction failed: ${e instanceof Error ? e.message : String(e)}`,
    );
    return null;
  }
}
