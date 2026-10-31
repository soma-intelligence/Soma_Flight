// POST /follow-flight { flightId, notify? } -> { ok: true }; DELETE /follow-flight { flightId } unfollows.
import type { SupabaseClient } from "npm:@supabase/supabase-js@2";
import { requireUser, type TokenVerifier } from "../_shared/auth.ts";
import { ApiError, errorResponse, json } from "../_shared/errors.ts";
import {
  type AlertApi,
  ensureAlert,
  loadFlight,
  unfollow,
} from "../_shared/follow.ts";
import { checkRate } from "../_shared/limits.ts";

export const FOLLOW_MAX_PER_HOUR = 60;

export interface Deps {
  db: SupabaseClient;
  /** Null when the status provider has no alerts (the polling refresh covers the flight). */
  aero: AlertApi | null;
  verifier?: TokenVerifier;
}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

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
      await unfollow(db, aero, userId, flightId);
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
