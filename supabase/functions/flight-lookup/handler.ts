// POST /flight-lookup { ident? | origin+destination, date } -> { flights }
import type { SupabaseClient } from "npm:@supabase/supabase-js@2";
import {
  type AeroApi,
  inProviderWindow,
  toFlightRows,
} from "../_shared/aeroapi.ts";
import type { AeroFlight } from "../_shared/aeroapi_types.ts";
import {
  requireUser,
  serviceClient,
  type TokenVerifier,
} from "../_shared/auth.ts";
import { ApiError, errorResponse, json } from "../_shared/errors.ts";
import { checkRate, productionAeroApi } from "../_shared/limits.ts";

export const ROUTE_CACHE_MINUTES = 10;
export const LOOKUP_MAX_PER_HOUR = 30;

export interface Deps {
  db: SupabaseClient;
  aero: Pick<AeroApi, "flightsByIdent" | "searchRoute">;
  verifier?: TokenVerifier;
  now?: () => Date;
}

const DAY_MS = 86_400_000;

async function resolveAirport(
  db: SupabaseClient,
  code: unknown,
): Promise<string> {
  const c = typeof code === "string" ? code.trim().toUpperCase() : "";
  if (!/^([A-Z0-9]{3}|[A-Z0-9]{4})$/.test(c)) {
    throw new ApiError("invalid_request", 400, "Invalid airport code");
  }
  const { data, error } = await db.from("airports").select("icao")
    .eq(c.length === 3 ? "iata" : "icao", c).maybeSingle();
  if (error) throw new Error(`airport lookup failed: ${error.message}`);
  if (!data) throw new ApiError("invalid_request", 400, `Unknown airport ${c}`);
  return data.icao as string;
}

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
    if (!inProviderWindow(start, now)) {
      throw new ApiError(
        "out_of_window",
        400,
        "Date must be within 10 days back and 2 days ahead",
      );
    }
    const dayEnd = new Date(start.getTime() + DAY_MS);

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
      const end = new Date(
        Math.min(dayEnd.getTime(), now.getTime() + 2 * DAY_MS),
      );
      const found = await aero.flightsByIdent(
        ident,
        start.toISOString(),
        end.toISOString(),
      );
      const onDay = found.filter((f) => {
        const t = f.scheduled_out ? Date.parse(f.scheduled_out) : NaN;
        return t >= start.getTime() && t < dayEnd.getTime();
      });
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

    // Route searches cost about $0.02 a page: share results for a few minutes.
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

    const found = await aero.searchRoute(origin, destination, date);
    const rows = await upsertFlights(db, found, now);
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
