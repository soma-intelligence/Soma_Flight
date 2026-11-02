// POST /flight-schedules { origin?, destination?, airline?, ident?, date: "YYYY-MM-DD", time? }
//   -> { date, fetched_at, stale, truncated, flights: [{ ident, airline, origin, destination,
//        scheduled_out, scheduled_in, aircraft_type }] }
// The "add a flight" search for days or weeks ahead (docs/api-contract.md): what the airlines plan to
// fly on a day, from an airport, to an airport, under an airline or flight number. Needs at least one
// of origin, destination and ident. `date` is the local date at the origin (else the destination), up to
// MAX_DAYS_AHEAD days from now. A flight number alone has no place to read the day in: the provider is
// asked from 10:00Z the day before (UTC+14's midnight) to noon UTC the day after, and the flights
// kept are those leaving on `date` at their own origin. `time` (minutes after local midnight) narrows a search with a place
// to TIME_WINDOW_MS either side, within the day, so a busy airport's evening is not lost past the
// pages read; `truncated` says when the provider still had pages after MAX_PAGES.
//
// The provider's schedules (/schedules/{date_start}/{date_end}) are read for that local day, through
// the AeroApi client and its spend cap, and cached whole per query and day (schedules_cache,
// CACHE_TTL_MS), empty answers included, so the same search shares one paid call. A schedule is a plan
// with no status, and nothing is stored in flights: the app follows a row through flight-lookup. When
// the provider refuses (the daily cap, an outage, its rate limit) a cached answer of any age is served
// with stale: true; with nothing cached the call fails with provider_unavailable.
import type { SupabaseClient } from "npm:@supabase/supabase-js@2";
import type { AeroApi, AeroScheduledFlight } from "../_shared/aeroapi.ts";
import { resolveAirport } from "../_shared/airports.ts";
import { requireUser, type TokenVerifier } from "../_shared/auth.ts";
import { ApiError, errorResponse, json } from "../_shared/errors.ts";
import { checkRate } from "../_shared/limits.ts";
import { localDate, zonedDayStart } from "../flight-lookup/handler.ts";

export const CACHE_TTL_MS = 6 * 3600_000;
export const SCHEDULES_MAX_PER_HOUR = 30;
/** How far ahead a date may be: the airlines publish about eleven months. */
export const MAX_DAYS_AHEAD = 330;
/** Pages read per search, each one billed. */
export const MAX_PAGES = 3;
/** How far either side of an asked time of day the provider is asked. */
export const TIME_WINDOW_MS = 4 * 3600_000;

const DAY_MS = 86_400_000;
const AIRLINE = /^([A-Z]{3}|[A-Z0-9]{2})$/;
/** An ident is the airline designator (3 letters, else 2 characters) and the number. */
const IDENT = /^([A-Z]{3}|[A-Z0-9]{2})([0-9]{1,4})$/;

export interface Deps {
  db: SupabaseClient;
  aero: Pick<AeroApi, "scheduleWindow">;
  verifier?: TokenVerifier;
  now?: () => Date;
}

/** One flight of the answer, in the shape FlightKit decodes. */
export interface ScheduledFlight {
  ident: string;
  airline: string | null;
  origin: string;
  destination: string;
  scheduled_out: string;
  scheduled_in: string;
  aircraft_type: string | null;
}

/**
 * "KSFO-KORD-*-UA1958-2026-11-20": the cache key of a query and day, `*` for a part not asked. A time
 * of day narrows the answer, so it is its own search: "KSFO-*-*-*-2026-11-20-t1140".
 */
export function cacheKey(
  q: {
    origin?: string;
    destination?: string;
    airline?: string;
    ident?: string;
    time?: number;
  },
  date: string,
): string {
  const p = (v?: string) => v || "*";
  const t = q.time === undefined ? "" : `-t${q.time}`;
  return `${p(q.origin)}-${p(q.destination)}-${p(q.airline)}-${
    p(q.ident)
  }-${date}${t}`;
}

/**
 * One schedule entry as an answer row: the IATA designator (else the provider's), the operator from
 * the ICAO designator's letters, ICAO airport codes (else the provider's own). Null without times.
 */
export function toScheduledFlight(
  s: AeroScheduledFlight,
): ScheduledFlight | null {
  const out = Date.parse(s.scheduled_out), arrive = Date.parse(s.scheduled_in);
  if (Number.isNaN(out) || Number.isNaN(arrive)) return null;
  return {
    ident: s.ident_iata ?? s.ident,
    airline: /^([A-Z]{3})[0-9]/.exec(s.ident_icao ?? "")?.[1] ?? null,
    origin: s.origin_icao ?? s.origin,
    destination: s.destination_icao ?? s.destination,
    scheduled_out: new Date(out).toISOString(),
    scheduled_in: new Date(arrive).toISOString(),
    aircraft_type: s.aircraft_type ?? null,
  };
}

/** Provider refusals a stale answer can stand in for. */
const refused = (e: unknown) =>
  e instanceof ApiError &&
  (e.code === "provider_unavailable" || e.code === "rate_limited");

function nextDate(date: string): string {
  return new Date(Date.parse(`${date}T00:00:00Z`) + DAY_MS).toISOString()
    .slice(0, 10);
}

/** ICAO to timezone for the airports the table knows. */
async function timezonesOf(
  db: SupabaseClient,
  icaos: string[],
): Promise<Map<string, string>> {
  const out = new Map<string, string>();
  if (icaos.length === 0) return out;
  const { data, error } = await db.from("airports").select("icao, tz")
    .in("icao", icaos);
  if (error) throw new Error(`airports read failed: ${error.message}`);
  for (const r of data ?? []) if (r.tz) out.set(r.icao, r.tz);
  return out;
}

/** The timezone of an airport (ICAO), UTC when the table has none. */
async function timezoneOf(db: SupabaseClient, icao: string): Promise<string> {
  const { data, error } = await db.from("airports").select("tz")
    .eq("icao", icao).maybeSingle();
  if (error) throw new Error(`airports read failed: ${error.message}`);
  if (!data?.tz) {
    console.warn(`airport ${icao} has no timezone, using UTC`);
    return "UTC";
  }
  return data.tz as string;
}

interface Query {
  origin?: string;
  destination?: string;
  airline?: string;
  ident?: string;
  date: string;
  /** Minutes after local midnight. */
  time?: number;
}

/**
 * The provider window of a query, as UTC instants: the local day at the origin (else the destination),
 * narrowed to TIME_WINDOW_MS either side of `time` within that day; with no place, 10:00Z the day
 * before to noon UTC the day after, which holds `date` at any origin (UTC-12 to UTC+14 in full).
 */
async function windowOf(
  db: SupabaseClient,
  q: Query,
): Promise<{ start: Date; end: Date }> {
  const place = q.origin ?? q.destination;
  if (!place) {
    const noon = Date.parse(`${q.date}T12:00:00Z`);
    return {
      start: new Date(noon - DAY_MS - 2 * 3600_000),
      end: new Date(noon + DAY_MS),
    };
  }
  const tz = await timezoneOf(db, place);
  const dayStart = zonedDayStart(tz, q.date).getTime();
  const dayEnd = zonedDayStart(tz, nextDate(q.date)).getTime();
  if (q.time === undefined) {
    return { start: new Date(dayStart), end: new Date(dayEnd) };
  }
  // Local clock minutes from the day's start: a DST change that day moves it by an hour at most.
  const at = dayStart + q.time * 60_000;
  return {
    start: new Date(Math.max(dayStart, at - TIME_WINDOW_MS)),
    end: new Date(Math.min(dayEnd, at + TIME_WINDOW_MS)),
  };
}

/** The rows leaving on `date` at their origin, read in its timezone (UTC when the table has none). */
async function leavingOn(
  db: SupabaseClient,
  rows: ScheduledFlight[],
  date: string,
): Promise<ScheduledFlight[]> {
  const tzs = await timezonesOf(db, [...new Set(rows.map((r) => r.origin))]);
  return rows.filter((r) =>
    localDate(tzs.get(r.origin) ?? "UTC", r.scheduled_out) === date
  );
}

/**
 * The cached flights of the query when fresher than CACHE_TTL_MS, else the provider's (then cached).
 * A refused fetch serves the cached rows of any age as stale, or throws provider_unavailable with
 * nothing cached.
 */
async function cachedSchedule(
  deps: Deps,
  q: Query,
  now: Date,
): Promise<
  {
    flights: ScheduledFlight[];
    fetched_at: string;
    stale: boolean;
    truncated: boolean;
  }
> {
  const key = cacheKey(q, q.date);
  const hit = await deps.db.from("schedules_cache").select(
    "flights, fetched_at, truncated",
  ).eq("key", key).maybeSingle();
  if (hit.error) {
    throw new Error(`schedules_cache read failed: ${hit.error.message}`);
  }
  const cached = hit.data
    ? {
      flights: hit.data.flights as ScheduledFlight[],
      fetched_at: new Date(hit.data.fetched_at).toISOString(),
      truncated: hit.data.truncated === true,
    }
    : null;
  if (cached && now.getTime() - Date.parse(cached.fetched_at) < CACHE_TTL_MS) {
    return { ...cached, stale: false };
  }

  const { start, end } = await windowOf(deps.db, q);
  const m = q.ident ? IDENT.exec(q.ident) : null;
  let flights: ScheduledFlight[], truncated: boolean;
  try {
    const got = await deps.aero.scheduleWindow(
      q.origin,
      q.destination,
      start,
      end,
      MAX_PAGES,
      { airline: m?.[1] ?? q.airline, flightNumber: m?.[2] },
    );
    truncated = got.truncated;
    flights = got.flights.map(toScheduledFlight)
      .filter((r): r is ScheduledFlight => r !== null)
      .sort((a, b) =>
        a.scheduled_out.localeCompare(b.scheduled_out) ||
        a.ident.localeCompare(b.ident)
      );
  } catch (e) {
    if (!refused(e)) throw e;
    console.error(
      `schedules refresh refused for ${key}`,
      (e as ApiError).code,
      (e as ApiError).message,
    );
    if (cached) return { ...cached, stale: true };
    throw new ApiError(
      "provider_unavailable",
      503,
      "Airline schedules are unavailable right now",
    );
  }
  // A wider window than the day (no place): keep the flights leaving on it at their own origin.
  if (!q.origin && !q.destination) {
    flights = await leavingOn(deps.db, flights, q.date);
  }
  const fetchedAt = now.toISOString();
  const { error } = await deps.db.from("schedules_cache").upsert({
    key,
    flights,
    fetched_at: fetchedAt,
    truncated,
  });
  // A failed write is logged, never a failed answer: the caller already has what it paid for.
  if (error) console.error("schedules_cache write failed", error.message);
  return { flights, fetched_at: fetchedAt, stale: false, truncated };
}

export async function handler(req: Request, deps: Deps): Promise<Response> {
  try {
    if (req.method !== "POST") {
      throw new ApiError("invalid_request", 405, "POST only");
    }
    const { userId } = await requireUser(req, deps.verifier);
    const now = (deps.now ?? (() => new Date()))();
    await checkRate(
      userId,
      "flight-schedules",
      SCHEDULES_MAX_PER_HOUR,
      60,
      deps.db,
    );

    const body = await req.json().catch(() => null) as
      | Record<string, unknown>
      | null;
    if (!body || typeof body !== "object") {
      throw new ApiError("invalid_request", 400, "Invalid JSON body");
    }
    const text = (v: unknown) =>
      typeof v === "string" && v.trim() !== ""
        ? v.trim().toUpperCase().replace(/\s+/g, "")
        : undefined;
    const ident = text(body.ident), airline = text(body.airline);
    if (!text(body.origin) && !text(body.destination) && !ident) {
      throw new ApiError(
        "invalid_request",
        400,
        "origin, destination or ident is required",
      );
    }
    if (ident && !IDENT.test(ident)) {
      throw new ApiError(
        "invalid_request",
        400,
        "ident must be an airline code and a number such as UA1958",
      );
    }
    if (airline && !AIRLINE.test(airline)) {
      throw new ApiError(
        "invalid_request",
        400,
        "airline must be an IATA or ICAO code such as UA",
      );
    }
    const time = body.time;
    if (
      time !== undefined &&
      !(Number.isInteger(time) && (time as number) >= 0 &&
        (time as number) < 1440)
    ) {
      throw new ApiError(
        "invalid_request",
        400,
        "time must be minutes after local midnight, 0 to 1439",
      );
    }

    const date = body.date;
    if (typeof date !== "string" || !/^\d{4}-\d{2}-\d{2}$/.test(date)) {
      throw new ApiError("invalid_request", 400, "date must be YYYY-MM-DD");
    }
    const start = new Date(`${date}T00:00:00Z`);
    if (
      Number.isNaN(start.getTime()) || start.toISOString().slice(0, 10) !== date
    ) {
      throw new ApiError("invalid_request", 400, "Invalid date");
    }
    // A schedule is a plan: nothing before yesterday (UTC, loose for the local day), nothing past
    // what the airlines have published.
    if (
      start.getTime() < now.getTime() - 2 * DAY_MS ||
      start.getTime() > now.getTime() + MAX_DAYS_AHEAD * DAY_MS
    ) {
      throw new ApiError(
        "out_of_window",
        400,
        `date must be within ${MAX_DAYS_AHEAD} days ahead`,
      );
    }

    const origin = text(body.origin)
      ? await resolveAirport(deps.db, body.origin)
      : undefined;
    const destination = text(body.destination)
      ? await resolveAirport(deps.db, body.destination)
      : undefined;
    if (origin && origin === destination) {
      throw new ApiError(
        "invalid_request",
        400,
        "origin and destination must differ",
      );
    }

    const got = await cachedSchedule(
      deps,
      {
        origin,
        destination,
        airline,
        ident,
        date,
        time: time as number | undefined,
      },
      now,
    );
    return json({
      date,
      fetched_at: got.fetched_at,
      stale: got.stale,
      truncated: got.truncated,
      flights: got.flights,
    });
  } catch (e) {
    return errorResponse(e);
  }
}
