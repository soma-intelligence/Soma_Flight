// POST /flight-position { flightId } -> { flight }
// Ruling F2: the live position is fetched lazily. When a user views a followed flight that is
// departed or en route, the first viewer of each 2 minute window (claim_position_refresh, shared by
// every follower) asks the provider for /flights/{id}/position ($0.01, counted through the usage
// counter and the daily cap) and stores it in flights.position_*; Realtime carries it to every
// viewer. Everyone else, and every flight not in the air or not followed by the caller, gets the
// stored row as it is. A provider failure is logged and answers the stored row too: the position is
// a nicety, never a reason to fail the detail screen.
import type { SupabaseClient } from "npm:@supabase/supabase-js@2";
import type { AeroApi } from "../_shared/aeroapi.ts";
import { requireUser, type TokenVerifier } from "../_shared/auth.ts";
import { ApiError, errorResponse, json } from "../_shared/errors.ts";
import { checkRate } from "../_shared/limits.ts";

export const POSITION_TTL_SECONDS = 120;
export const POSITION_MAX_PER_HOUR = 120;
const AIRBORNE = new Set(["departed", "en_route"]);
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export interface Deps {
  db: SupabaseClient;
  aero: Pick<AeroApi, "flightPosition">;
  verifier?: TokenVerifier;
}

export async function handler(req: Request, deps: Deps): Promise<Response> {
  try {
    if (req.method !== "POST") {
      throw new ApiError("invalid_request", 405, "POST only");
    }
    const { userId } = await requireUser(req, deps.verifier);
    const { db, aero } = deps;
    await checkRate(userId, "flight-position", POSITION_MAX_PER_HOUR, 60, db);

    const body = await req.json().catch(() => null) as
      | Record<string, unknown>
      | null;
    const flightId = body?.flightId;
    if (typeof flightId !== "string" || !UUID.test(flightId)) {
      throw new ApiError("invalid_request", 400, "flightId must be a uuid");
    }

    const got = await db.from("flights").select().eq("id", flightId)
      .maybeSingle();
    if (got.error) throw new Error(`flight read failed: ${got.error.message}`);
    if (!got.data) throw new ApiError("not_found", 404, "Unknown flight");
    const flight = got.data as Record<string, unknown> & {
      provider_id: string;
      status: string;
    };
    if (!AIRBORNE.has(flight.status)) return json({ flight });

    const follow = await db.from("user_flights").select("flight_id")
      .eq("user_id", userId).eq("flight_id", flightId).maybeSingle();
    if (follow.error) {
      throw new Error(`follow read failed: ${follow.error.message}`);
    }
    if (!follow.data) return json({ flight });

    const claim = await db.rpc("claim_position_refresh", {
      p_flight: flightId,
      p_seconds: POSITION_TTL_SECONDS,
    });
    if (claim.error) {
      throw new Error(`claim_position_refresh failed: ${claim.error.message}`);
    }
    if (claim.data !== true) return json({ flight });

    let position;
    try {
      position = await aero.flightPosition(flight.provider_id);
    } catch (e) {
      console.error(
        `position refresh failed for ${flightId}`,
        e instanceof ApiError ? e.code : (e as Error).message,
      );
      return json({ flight });
    }
    if (!position) return json({ flight });
    const upd = await db.from("flights").update(position).eq("id", flightId)
      .select().single();
    if (upd.error) {
      throw new Error(`position write failed: ${upd.error.message}`);
    }
    return json({ flight: upd.data });
  } catch (e) {
    return errorResponse(e);
  }
}
