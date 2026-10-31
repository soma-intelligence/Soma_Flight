// GET /alternate-flights?origin=KSFO&destination=KORD&after=2026-11-03T15:20:00Z
//   -> { origin, destination, after, fetched_at, stale, flights }
// The flight sheet's "Other flights" card (docs/api-contract.md): direct flights on a route, any
// airline, for a canceled flight or a connection at risk. The app asks only when its paid sections are
// on (INSIGHTS_ENABLED).
//
// The provider's schedules (/schedules/{date_start}/{date_end}) are read for the WINDOW_HOURS from the
// start of the hour of `after`, through the AeroApi client and its spend cap, and cached whole per route
// and hour (alternates_cache, CACHE_TTL_MS), empty answers included, so everyone looking at the same
// route that hour shares one paid call. A schedule is a plan with no status: each answer is laid over
// the flights rows the backend already tracks (same provider id), free, so a tracked flight shows its
// status and estimates. When the provider refuses (the daily cap, an outage, its rate limit) a cached
// answer of any age is served with stale: true; with nothing cached the call fails with
// provider_unavailable, which the app shows as an empty card.
import type { SupabaseClient } from "npm:@supabase/supabase-js@2";
import type { AeroApi, AeroScheduledFlight } from "../_shared/aeroapi.ts";
import { requireUser, type TokenVerifier } from "../_shared/auth.ts";
import { ApiError, errorResponse, json } from "../_shared/errors.ts";
import { checkRate } from "../_shared/limits.ts";

export const CACHE_TTL_MS = 30 * 60_000;
/** Hours of schedule read from the start of the hour asked about. */
export const WINDOW_HOURS = 24;
export const ALTERNATES_MAX_PER_HOUR = 60;
/** How far `after` may sit from now: a little in the past (a request held to the half hour), two days on. */
export const AFTER_PAST_MS = 2 * 3_600_000;
export const AFTER_FUTURE_MS = 2 * 86_400_000;

const HOUR_MS = 3_600_000;
const CODE = /^[A-Z0-9]{3,4}$/;

export interface Deps {
  db: SupabaseClient;
  aero: Pick<AeroApi, "schedules">;
  verifier?: TokenVerifier;
  now?: () => Date;
}

/** One flight of the answer, in the shape FlightKit decodes. */
export interface Alternate {
  id: string;
  ident: string;
  operator: string | null;
  origin_iata: string;
  destination_iata: string;
  scheduled_out: string;
  scheduled_in: string;
  estimated_out: string | null;
  estimated_in: string | null;
  status: string;
  aircraft_type: string | null;
}

/** The start of the UTC hour of `at`. */
export function hourOf(at: Date): Date {
  return new Date(Math.floor(at.getTime() / HOUR_MS) * HOUR_MS);
}

/** "KSFO-KORD-2026-11-03T15": the cache key of a route and hour. */
export function cacheKey(origin: string, destination: string, hour: Date) {
  return `${origin}-${destination}-${hour.toISOString().slice(0, 13)}`;
}

/**
 * One schedule entry as an answer row: the IATA designator (else the provider's), the operator from
 * the ICAO designator's letters, IATA airport codes (else ICAO, else the provider's own). No status
 * or estimates yet (`overlay` adds them for tracked flights). Null without times.
 */
export function toAlternate(s: AeroScheduledFlight): Alternate | null {
  const out = Date.parse(s.scheduled_out), arrive = Date.parse(s.scheduled_in);
  if (Number.isNaN(out) || Number.isNaN(arrive)) return null;
  const operator = /^([A-Z]{3})[0-9]/.exec(s.ident_icao ?? "")?.[1] ?? null;
  const outIso = new Date(out).toISOString();
  return {
    id: s.fa_flight_id ?? `${s.ident_icao ?? s.ident}-${outIso}`,
    ident: s.ident_iata ?? s.ident,
    operator,
    origin_iata: s.origin_iata ?? s.origin_icao ?? s.origin,
    destination_iata: s.destination_iata ?? s.destination_icao ?? s.destination,
    scheduled_out: outIso,
    scheduled_in: new Date(arrive).toISOString(),
    estimated_out: null,
    estimated_in: null,
    status: "scheduled",
    aircraft_type: s.aircraft_type ?? null,
  };
}

interface TrackedRow {
  provider_id: string;
  status: string;
  estimated_out: string | null;
  estimated_in: string | null;
  actual_out: string | null;
  actual_in: string | null;
}

/**
 * Lays the flights rows the backend tracks (by provider id) over the schedule: their status, and their
 * actual or estimated gate times. A read failure keeps the schedule as it is.
 */
export async function overlay(
  db: SupabaseClient,
  rows: Alternate[],
): Promise<Alternate[]> {
  // Made-up ids (no provider id) match no row, which is fine.
  const ids = rows.map((r) => r.id);
  if (ids.length === 0) return rows;
  const { data, error } = await db.from("flights")
    .select(
      "provider_id, status, estimated_out, estimated_in, actual_out, actual_in",
    )
    .in("provider_id", ids);
  if (error) {
    console.error(`tracked flights read failed: ${error.message}`);
    return rows;
  }
  const byId = new Map(
    (data as TrackedRow[]).map((r) => [r.provider_id, r] as const),
  );
  const iso = (v: string | null) => (v ? new Date(v).toISOString() : null);
  return rows.map((r) => {
    const t = byId.get(r.id);
    if (!t) return r;
    return {
      ...r,
      status: t.status,
      estimated_out: iso(t.actual_out ?? t.estimated_out),
      estimated_in: iso(t.actual_in ?? t.estimated_in),
    };
  });
}

/** Provider refusals a stale answer can stand in for. */
const refused = (e: unknown) =>
  e instanceof ApiError &&
  (e.code === "provider_unavailable" || e.code === "rate_limited");

/**
 * The cached rows of the route and hour when fresher than CACHE_TTL_MS, else the provider's (then
 * cached). A refused fetch serves the cached rows of any age as stale, or throws provider_unavailable
 * with nothing cached.
 */
async function cachedSchedule(
  deps: Deps,
  origin: string,
  destination: string,
  hour: Date,
  now: Date,
): Promise<{ flights: Alternate[]; fetched_at: string; stale: boolean }> {
  const key = cacheKey(origin, destination, hour);
  const hit = await deps.db.from("alternates_cache").select(
    "payload, fetched_at",
  ).eq("key", key).maybeSingle();
  if (hit.error) {
    throw new Error(`alternates_cache read failed: ${hit.error.message}`);
  }
  const cached = hit.data
    ? {
      flights: ((hit.data.payload as { flights?: Alternate[] }).flights ??
        []) as Alternate[],
      fetched_at: new Date(hit.data.fetched_at).toISOString(),
    }
    : null;
  if (cached && now.getTime() - Date.parse(cached.fetched_at) < CACHE_TTL_MS) {
    return { ...cached, stale: false };
  }
  let flights: Alternate[];
  try {
    const rows = await deps.aero.schedules(
      origin,
      destination,
      hour,
      new Date(hour.getTime() + WINDOW_HOURS * HOUR_MS),
    );
    flights = rows.map(toAlternate).filter((r): r is Alternate => r !== null)
      .sort((a, b) =>
        a.scheduled_out.localeCompare(b.scheduled_out) ||
        a.ident.localeCompare(b.ident)
      );
  } catch (e) {
    if (!refused(e)) throw e;
    console.error(
      `alternates refresh refused for ${key}`,
      (e as ApiError).code,
      (e as ApiError).message,
    );
    if (cached) return { ...cached, stale: true };
    throw new ApiError(
      "provider_unavailable",
      503,
      "Other flights are unavailable right now",
    );
  }
  const fetchedAt = now.toISOString();
  const { error } = await deps.db.from("alternates_cache").upsert({
    key,
    payload: { flights },
    fetched_at: fetchedAt,
  });
  // A failed write is logged, never a failed answer: the caller already has what it paid for.
  if (error) console.error("alternates_cache write failed", error.message);
  return { flights, fetched_at: fetchedAt, stale: false };
}

export async function handler(req: Request, deps: Deps): Promise<Response> {
  try {
    if (req.method !== "GET") {
      throw new ApiError("invalid_request", 405, "GET only");
    }
    const { userId } = await requireUser(req, deps.verifier);
    const now = (deps.now ?? (() => new Date()))();
    await checkRate(
      userId,
      "alternate-flights",
      ALTERNATES_MAX_PER_HOUR,
      60,
      deps.db,
    );

    const url = new URL(req.url);
    const code = (name: string) =>
      (url.searchParams.get(name) ?? "").trim().toUpperCase();
    const origin = code("origin"), destination = code("destination");
    if (!CODE.test(origin) || !CODE.test(destination)) {
      throw new ApiError(
        "invalid_request",
        400,
        "origin and destination must be airport codes such as KSFO",
      );
    }
    if (origin === destination) {
      throw new ApiError(
        "invalid_request",
        400,
        "origin and destination must differ",
      );
    }
    const afterRaw = url.searchParams.get("after");
    const after = afterRaw ? new Date(afterRaw) : now;
    if (Number.isNaN(after.getTime())) {
      throw new ApiError("invalid_request", 400, "after must be an ISO time");
    }
    if (
      after.getTime() < now.getTime() - AFTER_PAST_MS ||
      after.getTime() > now.getTime() + AFTER_FUTURE_MS
    ) {
      throw new ApiError(
        "out_of_window",
        400,
        "after must be within 2 hours before and 2 days after now",
      );
    }

    const hour = hourOf(after);
    const got = await cachedSchedule(deps, origin, destination, hour, now);
    const fromAfter = got.flights.filter((f) =>
      Date.parse(f.scheduled_out) >= after.getTime()
    );
    return json({
      origin,
      destination,
      after: hour.toISOString(),
      fetched_at: got.fetched_at,
      stale: got.stale,
      flights: await overlay(deps.db, fromAfter),
    });
  } catch (e) {
    return errorResponse(e);
  }
}
