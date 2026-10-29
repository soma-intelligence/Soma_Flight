// POST /follow-flight { flightId, notify? } -> { ok: true }; DELETE /follow-flight { flightId } unfollows.
import type { SupabaseClient } from "npm:@supabase/supabase-js@2";
import type { AeroApi } from "../_shared/aeroapi.ts";
import { requireUser, type TokenVerifier } from "../_shared/auth.ts";
import { ApiError, errorResponse, json } from "../_shared/errors.ts";
import { checkRate } from "../_shared/limits.ts";

export const FOLLOW_MAX_PER_HOUR = 60;

export interface Deps {
  db: SupabaseClient;
  aero: Pick<AeroApi, "createAlert" | "deleteAlert">;
  verifier?: TokenVerifier;
}

const DAY_MS = 86_400_000;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

interface FlightRef {
  id: string;
  provider_id: string;
  status: string;
  scheduled_out: string | null;
  scheduled_in: string | null;
  origin_icao: string | null;
  alert_id: number | null;
}

/** YYYY-MM-DD of an instant in a timezone (the departure airport's, as AeroAPI alerts expect). */
function dateIn(tz: string, at: Date): string {
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

async function loadFlight(
  db: SupabaseClient,
  flightId: string,
): Promise<FlightRef | null> {
  const { data, error } = await db.from("flights")
    .select(
      "id, provider_id, status, scheduled_out, scheduled_in, origin_icao, alert_id",
    )
    .eq("id", flightId).maybeSingle();
  if (error) throw new Error(`flight read failed: ${error.message}`);
  return data as FlightRef | null;
}

async function countFollowers(
  db: SupabaseClient,
  flightId: string,
): Promise<number> {
  const { count, error } = await db.from("user_flights")
    .select("user_id", { count: "exact", head: true }).eq(
      "flight_id",
      flightId,
    );
  if (error) throw new Error(`follower count failed: ${error.message}`);
  return count ?? 0;
}

/**
 * One provider alert per flight, however many users follow it. Creates it when missing, then claims
 * flights.alert_id with a conditional update (where alert_id is null). A request that loses the
 * race deletes the alert it just made, so exactly one stays.
 */
export async function ensureAlert(
  db: SupabaseClient,
  aero: Deps["aero"],
  flightId: string,
): Promise<void> {
  const flight = await loadFlight(db, flightId);
  if (!flight || flight.alert_id !== null) return;
  if (flight.status === "arrived" || flight.status === "canceled") return;

  // AeroAPI alert idents are ICAO: the part of fa_flight_id before the first dash (AFR84-...).
  const ident = flight.provider_id.split("-")[0];
  const out = flight.scheduled_out
    ? new Date(flight.scheduled_out)
    : new Date();
  const arrive = flight.scheduled_in
    ? new Date(flight.scheduled_in)
    : new Date(out.getTime() + DAY_MS);
  let tz = "UTC";
  if (flight.origin_icao) {
    const a = await db.from("airports").select("tz").eq(
      "icao",
      flight.origin_icao,
    ).maybeSingle();
    if (a.data?.tz) tz = a.data.tz as string;
  }
  // Window: scheduled departure minus 1 day to scheduled arrival plus 1 day.
  const start = dateIn(tz, new Date(out.getTime() - DAY_MS));
  const end = dateIn(tz, new Date(arrive.getTime() + DAY_MS));

  const alertId = await aero.createAlert(ident, start, end);
  const claimed = await db.from("flights").update({ alert_id: alertId })
    .eq("id", flightId).is("alert_id", null).select("id");
  if (claimed.error || (claimed.data ?? []).length === 0) {
    // Lost the race (or the write failed): do not leave an orphan alert billing us.
    await aero.deleteAlert(alertId);
    if (claimed.error) {
      throw new Error(`alert claim failed: ${claimed.error.message}`);
    }
  }
}

/** Deletes the alert when nobody follows the flight any more. Re-creates it if a follower slipped in meanwhile. */
async function releaseAlert(
  db: SupabaseClient,
  aero: Deps["aero"],
  flightId: string,
): Promise<void> {
  if ((await countFollowers(db, flightId)) > 0) return;
  const flight = await loadFlight(db, flightId);
  if (!flight || flight.alert_id === null) return;
  const cleared = await db.from("flights").update({ alert_id: null })
    .eq("id", flightId).eq("alert_id", flight.alert_id).select("id");
  if (cleared.error) {
    throw new Error(`alert clear failed: ${cleared.error.message}`);
  }
  if ((cleared.data ?? []).length === 0) return; // someone else released it
  await aero.deleteAlert(Number(flight.alert_id));
  // A follower may have arrived between the count and the clear and seen alert_id still set.
  if ((await countFollowers(db, flightId)) > 0) {
    await ensureAlert(db, aero, flightId);
  }
}

export async function handler(req: Request, deps: Deps): Promise<Response> {
  try {
    if (req.method !== "POST" && req.method !== "DELETE") {
      throw new ApiError("invalid_request", 405, "POST or DELETE only");
    }
    const { userId } = await requireUser(req, deps.verifier);
    const { db, aero } = deps;
    await checkRate(userId, "follow-flight", FOLLOW_MAX_PER_HOUR, 60, db);

    const body = await req.json().catch(() => null) as
      | Record<string, unknown>
      | null;
    const flightId = body?.flightId;
    if (typeof flightId !== "string" || !UUID.test(flightId)) {
      throw new ApiError("invalid_request", 400, "flightId must be a uuid");
    }
    if (body?.notify !== undefined && typeof body.notify !== "boolean") {
      throw new ApiError("invalid_request", 400, "notify must be a boolean");
    }

    if (req.method === "DELETE") {
      const del = await db.from("user_flights").delete()
        .eq("user_id", userId).eq("flight_id", flightId);
      if (del.error) throw new Error(`unfollow failed: ${del.error.message}`);
      await releaseAlert(db, aero, flightId);
      return json({ ok: true });
    }

    if (!(await loadFlight(db, flightId))) {
      throw new ApiError("not_found", 404, "Unknown flight");
    }
    const res = await db.rpc("try_follow", {
      p_user: userId,
      p_flight: flightId,
      p_notify: body?.notify ?? null,
    });
    if (res.error) throw new Error(`try_follow failed: ${res.error.message}`);
    if (res.data === "plan_limit") {
      throw new ApiError(
        "plan_limit",
        403,
        "Free plan allows 3 followed flights",
      );
    }
    try {
      await ensureAlert(db, aero, flightId);
    } catch (e) {
      // No alert means no push: undo a brand new follow so the client can simply retry.
      if (res.data === "ok") {
        await db.from("user_flights").delete().eq("user_id", userId).eq(
          "flight_id",
          flightId,
        );
      }
      throw e;
    }
    return json({ ok: true });
  } catch (e) {
    return errorResponse(e);
  }
}
