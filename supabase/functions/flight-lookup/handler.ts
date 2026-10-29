// POST /flight-lookup { ident? | origin+destination, date } -> { flights }
import type { SupabaseClient } from "npm:@supabase/supabase-js@2";
import { type AeroApi, toFlightRows } from "../_shared/aeroapi.ts";
import type { AeroFlight } from "../_shared/aeroapi_types.ts";
import {
  requireUser,
  serviceClient,
  type TokenVerifier,
} from "../_shared/auth.ts";
import { resolveAirport } from "../_shared/airports.ts";
import { ApiError, errorResponse, json } from "../_shared/errors.ts";
import { checkRate, productionAeroApi } from "../_shared/limits.ts";

export const ROUTE_CACHE_MINUTES = 10;
export const LOOKUP_MAX_PER_HOUR = 30;

export interface Deps {
  db: SupabaseClient;
  aero: Pick<AeroApi, "flightsByIdent" | "searchRouteWindow">;
  verifier?: TokenVerifier;
  now?: () => Date;
}

const DAY_MS = 86_400_000;

async function upsertFlights(
  db: SupabaseClient,
  flights: AeroFlight[],
  now: Date,
) {
  const rows = toFlightRows(flights, now);
  if (rows.length === 0) return [];
  const { data, error } = await db.from("flights")
    .upsert(rows, { onConflict: "provider_id" }).select();
  if (error) throw new Error(`flights upsert failed: ${error.message}`);
  return data ?? [];
}

/** YYYY-MM-DD of an instant in a timezone. */
export function localDate(tz: string, iso: string): string {
  const at = new Date(iso);
  try {
    return new Intl.DateTimeFormat("en-CA", {
      timeZone: tz,
      year: "numeric",
      month: "2-digit",
      day: "2-digit",
    }).format(at);
  } catch {
    return at.toISOString().slice(0, 10);
  }
}

function nextDate(date: string): string {
  return new Date(Date.parse(`${date}T00:00:00Z`) + DAY_MS).toISOString()
    .slice(0, 10);
}

/** Offset of a timezone from UTC at an instant, in ms (local minus UTC). */
function zoneOffset(tz: string, at: Date): number {
  const p = Object.fromEntries(
    new Intl.DateTimeFormat("en-US", {
      timeZone: tz,
      hourCycle: "h23",
      year: "numeric",
      month: "numeric",
      day: "numeric",
      hour: "numeric",
      minute: "numeric",
      second: "numeric",
    }).formatToParts(at).map((x) => [x.type, Number(x.value)]),
  );
  const asUtc = Date.UTC(
    p.year,
    p.month - 1,
    p.day,
    p.hour,
    p.minute,
    p.second,
  );
  return asUtc - Math.floor(at.getTime() / 1000) * 1000;
}

/** The UTC instant at which local date `date` starts in `tz`. */
export function zonedDayStart(tz: string, date: string): Date {
  const local = Date.parse(`${date}T00:00:00Z`);
  let guess = local - zoneOffset(tz, new Date(local));
  guess = local - zoneOffset(tz, new Date(guess)); // settle across a DST change
  return new Date(guess);
}

/** ICAO to timezone: the provider's own value first, the airports table for the rest. */
async function originTimezones(
  db: SupabaseClient,
  flights: AeroFlight[],
  extra: string[] = [],
): Promise<Map<string, string>> {
  const out = new Map<string, string>();
  const missing = new Set<string>(extra);
  for (const f of flights) {
    const icao = f.origin?.code_icao;
    if (!icao) continue;
    if (f.origin?.timezone) out.set(icao, f.origin.timezone);
    else missing.add(icao);
  }
  for (const e of extra) out.delete(e);
  if (missing.size > 0) {
    const { data, error } = await db.from("airports").select("icao, tz")
      .in("icao", [...missing]);
    if (error) throw new Error(`airports read failed: ${error.message}`);
    for (const r of data ?? []) if (r.tz) out.set(r.icao, r.tz);
  }
  return out;
}

function sortFlights<T extends { scheduled_out: string | null }>(
  rows: T[],
): T[] {
  return [...rows].sort((a, b) =>
    (a.scheduled_out ?? "").localeCompare(b.scheduled_out ?? "")
  );
}

export async function handler(req: Request, deps: Deps): Promise<Response> {
  try {
    if (req.method !== "POST") {
      throw new ApiError("invalid_request", 405, "POST only");
    }
    const { userId } = await requireUser(req, deps.verifier);
    const { db, aero } = deps;
    const now = (deps.now ?? (() => new Date()))();
    await checkRate(userId, "flight-lookup", LOOKUP_MAX_PER_HOUR, 60, db);

    const body = await req.json().catch(() => null) as
      | Record<string, unknown>
      | null;
    if (!body || typeof body !== "object") {
      throw new ApiError("invalid_request", 400, "Invalid JSON body");
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
    // The provider serves 10 days back and 2 days ahead only: never spend a call outside.
    // The date is the local date at the origin airport, so a whole UTC day is the loose bound.
    const dayEnd = new Date(start.getTime() + DAY_MS);
    if (
      dayEnd.getTime() <= now.getTime() - 10 * DAY_MS ||
      start.getTime() > now.getTime() + 2 * DAY_MS
    ) {
      throw new ApiError(
        "out_of_window",
        400,
        "Date must be within 10 days back and 2 days ahead",
      );
    }

    const hasIdent = typeof body.ident === "string" && body.ident.trim() !== "";
    const hasRoute = body.origin !== undefined ||
      body.destination !== undefined;
    if (hasIdent === hasRoute) {
      throw new ApiError(
        "invalid_request",
        400,
        "Provide ident, or origin and destination",
      );
    }

    if (hasIdent) {
      const ident = (body.ident as string).replace(/\s+/g, "").toUpperCase();
      if (!/^[A-Z0-9]{2,8}$/.test(ident)) {
        throw new ApiError("invalid_request", 400, "Invalid ident");
      }
      // Local date at the origin can sit a day either side of the UTC date: widen, then filter.
      const from = new Date(Math.max(
        start.getTime() - DAY_MS,
        now.getTime() - 10 * DAY_MS,
      ));
      const to = new Date(Math.min(
        start.getTime() + 2 * DAY_MS,
        now.getTime() + 2 * DAY_MS,
      ));
      if (from.getTime() >= to.getTime()) return json({ flights: [] });
      const found = await aero.flightsByIdent(
        ident,
        from.toISOString(),
        to.toISOString(),
      );
      const tzs = await originTimezones(db, found);
      const onDay = found.filter((f) =>
        f.scheduled_out != null &&
        localDate(
            tzs.get(f.origin?.code_icao ?? "") ?? "UTC",
            f.scheduled_out,
          ) ===
          date
      );
      return json({
        flights: sortFlights(await upsertFlights(db, onDay, now)),
      });
    }

    const origin = await resolveAirport(db, body.origin);
    const destination = await resolveAirport(db, body.destination);
    if (origin === destination) {
      throw new ApiError(
        "invalid_request",
        400,
        "Origin and destination are the same",
      );
    }

    // A route search is billed per page (about $0.02 to $0.05): share results for a few minutes.
    const cached = await db.from("route_cache").select(
      "provider_ids, fetched_at",
    )
      .eq("origin_icao", origin).eq("destination_icao", destination)
      .eq("date", date).maybeSingle();
    if (cached.error) {
      throw new Error(`route_cache read failed: ${cached.error.message}`);
    }
    if (
      cached.data &&
      now.getTime() - Date.parse(cached.data.fetched_at) <
        ROUTE_CACHE_MINUTES * 60_000
    ) {
      const ids = cached.data.provider_ids as string[];
      if (ids.length === 0) return json({ flights: [] });
      const rows = await db.from("flights").select().in("provider_id", ids);
      if (rows.error) {
        throw new Error(`flights read failed: ${rows.error.message}`);
      }
      return json({ flights: sortFlights(rows.data ?? []) });
    }

    // One provider call covering the origin's local day, converted to UTC.
    let tz = (await originTimezones(db, [], [origin])).get(origin);
    if (!tz) {
      console.warn(`airport ${origin} has no timezone, using UTC`);
      tz = "UTC";
    }
    const found = await aero.searchRouteWindow(
      origin,
      destination,
      zonedDayStart(tz, date),
      zonedDayStart(tz, nextDate(date)),
    );
    const onDay = found.filter((f) =>
      f.scheduled_out != null && localDate(tz, f.scheduled_out) === date
    );
    const rows = await upsertFlights(db, onDay, now);
    const put = await db.from("route_cache").upsert({
      origin_icao: origin,
      destination_icao: destination,
      date,
      provider_ids: rows.map((r) => r.provider_id),
      fetched_at: now.toISOString(),
    }, { onConflict: "origin_icao,destination_icao,date" });
    if (put.error) console.error("route_cache write failed", put.error.message);
    return json({ flights: sortFlights(rows) });
  } catch (e) {
    return errorResponse(e);
  }
}
