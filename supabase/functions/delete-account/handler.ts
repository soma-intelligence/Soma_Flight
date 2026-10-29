// POST /delete-account -> { ok: true }. Erases the caller's data and auth user (App Store in-app deletion).
import type { SupabaseClient } from "npm:@supabase/supabase-js@2";
import { requireUser, type TokenVerifier } from "../_shared/auth.ts";
import { ApiError, errorResponse, json } from "../_shared/errors.ts";
import { type AlertApi, unfollow } from "../_shared/follow.ts";
import { checkRate } from "../_shared/limits.ts";

export const DELETE_MAX_PER_HOUR = 5;

export interface Deps {
  db: SupabaseClient;
  aero: AlertApi;
  verifier?: TokenVerifier;
}

function must(r: { error: { message: string } | null }, what: string): void {
  if (r.error) throw new Error(`${what} failed: ${r.error.message}`);
}

/**
 * Order matters and every step is safe to repeat, so a retry finishes an interrupted deletion:
 * unfollow (releases alerts nobody else needs; a provider failure keeps alert_id for the sweep and
 * never blocks the deletion), erase user rows, strip and mark the profile, then delete the auth
 * user last. The profile row has no FK to auth.users and is kept with status 'deleted'.
 */
export async function handler(req: Request, deps: Deps): Promise<Response> {
  try {
    if (req.method !== "POST") {
      throw new ApiError("invalid_request", 405, "POST only");
    }
    const { userId } = await requireUser(req, deps.verifier);
    const { db, aero } = deps;
    await checkRate(userId, "delete-account", DELETE_MAX_PER_HOUR, 60, db);

    const followed = await db.from("user_flights").select("flight_id")
      .eq("user_id", userId);
    must(followed, "follow read");
    for (const row of followed.data ?? []) {
      await unfollow(db, aero, userId, row.flight_id as string);
    }

    must(
      await db.from("past_flights").delete().eq("user_id", userId),
      "past flights delete",
    );
    must(
      await db.from("push_tokens").delete().eq("user_id", userId),
      "push tokens delete",
    );
    must(
      await db.from("profiles").update({
        status: "deleted",
        display_name: null,
      })
        .eq("user_id", userId),
      "profile update",
    );

    const del = await db.auth.admin.deleteUser(userId);
    // Already gone (a retry after a partial run) is the goal state, not a failure.
    if (del.error && del.error.status !== 404) {
      console.error(`auth user ${userId} not deleted`, del.error);
      throw new ApiError(
        "provider_unavailable",
        500,
        "Account data erased, sign-in removal failed. Retry.",
      );
    }
    return json({ ok: true });
  } catch (e) {
    return errorResponse(e);
  }
}
