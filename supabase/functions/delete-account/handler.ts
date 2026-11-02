// POST /delete-account { apple_authorization_code? } -> { ok: true }. Revokes the caller's Sign in with
// Apple tokens, archives the caller's data (archive.deleted_accounts), then erases the live rows and the
// auth user (App Store in-app deletion).
import type { SupabaseClient } from "npm:@supabase/supabase-js@2";
import type { AppleRevoker } from "../_shared/apple.ts";
import { requireUser, type TokenVerifier } from "../_shared/auth.ts";
import { ApiError, errorResponse, json } from "../_shared/errors.ts";
import { type AlertApi, unfollow } from "../_shared/follow.ts";
import { checkRate } from "../_shared/limits.ts";

export const DELETE_MAX_PER_HOUR = 5;

/** The private bucket of profile photos (migration 20261031000030), one file per user. */
export const AVATARS_BUCKET = "avatars";
export const avatarPath = (userId: string) => `${userId}/avatar.jpg`;
/** Where a deleted account's photo is kept: no user or friend policy matches this folder. */
export const archivedAvatarPath = (userId: string) =>
  `deleted/${userId}/avatar.jpg`;

export interface Deps {
  db: SupabaseClient;
  aero: AlertApi;
  verifier?: TokenVerifier;
  /** Null when the Sign in with Apple key is not configured: Apple accounts are then refused. */
  apple?: AppleRevoker | null;
}

/** True when the account signs in with Apple (Supabase lists every linked provider in app_metadata). */
async function usesApple(db: SupabaseClient, userId: string): Promise<boolean> {
  const got = await db.auth.admin.getUserById(userId);
  // Already gone: a retry after the auth user was deleted, nothing left to revoke.
  if (got.error) {
    if (got.error.status === 404) return false;
    throw new Error(`user read failed: ${got.error.message}`);
  }
  const meta = got.data.user?.app_metadata ?? {};
  const providers: unknown[] = Array.isArray(meta.providers)
    ? meta.providers
    : [meta.provider];
  return providers.includes("apple");
}

/** The authorization code from the body, if any. An empty or non-JSON body is no code. */
async function appleCode(req: Request): Promise<string | null> {
  const body = await req.json().catch(() => null) as
    | Record<string, unknown>
    | null;
  const code = body?.apple_authorization_code;
  return typeof code === "string" && code.length > 0 ? code : null;
}

function must(r: { error: { message: string } | null }, what: string): void {
  if (r.error) throw new Error(`${what} failed: ${r.error.message}`);
}

/**
 * Order matters and every step is safe to repeat, so a retry finishes an interrupted deletion:
 * revoke the Apple tokens first (Apple sign-in accounts must send a fresh authorization code, and
 * nothing is erased when the revoke fails), archive everything the user owns (the first snapshot is kept on retries), unfollow (releases alerts nobody else needs; a provider failure keeps alert_id for the sweep and
 * never blocks the deletion), erase user rows, move the profile photo to the archive folder, strip and mark the profile, then delete the auth
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

    if (await usesApple(db, userId)) {
      const code = await appleCode(req);
      if (!code) {
        throw new ApiError(
          "invalid_request",
          400,
          "Sign in with Apple again to delete your account.",
        );
      }
      if (!deps.apple) {
        console.error(
          "delete-account: APPLE_TEAM_ID, APPLE_SIGNIN_KEY_ID or APPLE_SIGNIN_PRIVATE_KEY missing",
        );
        throw new ApiError(
          "provider_unavailable",
          503,
          "Account deletion is unavailable right now.",
        );
      }
      await deps.apple.revoke(code);
    }

    // Before anything is erased, so the archive holds the whole account.
    must(
      await db.rpc("archive_account", { p_user: userId }),
      "account archive",
    );
    const followed = await db.from("user_flights").select("flight_id")
      .eq("user_id", userId);
    must(followed, "follow read");
    // A follow added after this read is removed by the auth user cascade but its alert is not
    // released here: the hourly no-follower alert cleanup (Task 9) covers that.
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
    // The profile photo moves to the archive folder. No photo (none set, or a retry after the move) is not
    // an error; any older archived photo is replaced first so the move cannot collide.
    const photo = await db.storage.from(AVATARS_BUCKET).list(userId);
    must(photo, "avatar read");
    if ((photo.data ?? []).some((f) => f.name === "avatar.jpg")) {
      must(
        await db.storage.from(AVATARS_BUCKET).remove([
          archivedAvatarPath(userId),
        ]),
        "archived avatar replace",
      );
      must(
        await db.storage.from(AVATARS_BUCKET).move(
          avatarPath(userId),
          archivedAvatarPath(userId),
        ),
        "avatar archive",
      );
    }
    must(
      await db.from("profiles").update({
        status: "deleted",
        display_name: null,
        emoji: null,
        first_name: null,
        last_name: null,
        avatar_path: null,
        onboarded_at: null,
      })
        .eq("user_id", userId),
      "profile update",
    );

    // Drop the activity trail that still carries the id of the retained profile. The delete-account
    // rows stay so the hourly limit holds across retries; the periodic prune removes them later.
    must(
      await db.from("rate_events").delete().eq("user_id", userId)
        .neq("endpoint", "delete-account"),
      "rate events delete",
    );

    // Note: requireUser does not read profiles.status, so if this delete fails an old session
    // stays valid until the retry succeeds. Later functions must not rely on status alone.
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
