// Friend invitations for the Friends tab (docs/api-contract.md). Signed in, rate limited, POST only:
//
//   { action: "invite" }                          -> { id, url, expires_at }    a new single-use link
//   { action: "preview", token }                  -> { state, display_name, emoji }
//   { action: "accept" | "decline", token }       -> { friend_id | null }
//   { action: "request", code }                   -> { result: "sent" | "accepted" | "friends" }
//   { action: "respond", invitation_id, accept }  -> { answered }
//   { action: "revoke", invitation_id }           -> { revoked }
//   { action: "reset_code" }                      -> { code }
//
// Privacy: no contacts, no phone or email lookup. A friendship starts only from a link the inviter handed
// over (https://somalabs.me/i/<token>, the token kept as its SHA-256 only) or from the friend code they
// showed, and the other side answers. Reads (friends, their flights, Passport totals) are SQL functions the
// app calls itself (migration 20261031000022); this function writes invitations only.
import type { SupabaseClient } from "npm:@supabase/supabase-js@2";
import { requireUser, type TokenVerifier } from "../_shared/auth.ts";
import { ApiError, errorResponse, json } from "../_shared/errors.ts";
import { checkRate } from "../_shared/limits.ts";
import { hashToken, newToken, TOKEN_RE } from "../_shared/share.ts";

/** Every action together, per user: plenty for a person, little for a script. */
export const FRIENDS_MAX_PER_HOUR = 60;
/** Codes typed in, per user: 40 bits of code space stay out of reach of guessing. */
export const CODE_TRIES_PER_HOUR = 10;
/** Where links point unless INVITE_BASE_URL says otherwise; the landing site sends /i/* to the app. */
export const DEFAULT_INVITE_BASE = "https://somalabs.me/i/";
/** How long a link stays open. */
export const INVITE_TTL_HOURS = 7 * 24;

const UUID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
/** Crockford base32, 8 characters; read case-insensitively, spaces and dashes ignored. */
export const CODE_RE = /^[0-9A-HJKMNP-TV-Z]{8}$/;

export interface Deps {
  db: SupabaseClient;
  verifier?: TokenVerifier;
  /** Where links point (INVITE_BASE_URL); DEFAULT_INVITE_BASE otherwise. */
  base?: string | null;
  /** Test hook: the token generator (newToken otherwise). */
  token?: () => string;
}

/** The invite link for `token` under `base` (https only, else the default). */
export function inviteUrl(token: string, base?: string | null): string {
  const b = base && /^https:\/\//.test(base) ? base : DEFAULT_INVITE_BASE;
  return (b.endsWith("/") ? b : `${b}/`) + token;
}

/** A code as typed ("abcd-1234 ") in the stored form, or null when it cannot be one. */
export function normalizeCode(raw: unknown): string | null {
  if (typeof raw !== "string") return null;
  const c = raw.replace(/[\s-]/g, "").toUpperCase();
  return CODE_RE.test(c) ? c : null;
}

/** The token of a link or of a bare token; null when it is neither. */
export function tokenOf(raw: unknown): string | null {
  if (typeof raw !== "string") return null;
  const t = raw.trim().replace(/^.*\/i\//, "");
  return TOKEN_RE.test(t) ? t : null;
}

function uuid(raw: unknown, name: string): string {
  if (typeof raw !== "string" || !UUID_RE.test(raw)) {
    throw new ApiError("invalid_request", 400, `${name} must be a uuid`);
  }
  return raw.toLowerCase();
}

function token(raw: unknown): string {
  const t = tokenOf(raw);
  if (!t) throw new ApiError("invalid_request", 400, "token is not an invite");
  return t;
}

/** The SQL functions raise these names; anything else is a server failure. */
const SQL_ERRORS: Record<string, ApiError> = {
  invite_not_found: new ApiError(
    "not_found",
    404,
    "This invitation does not exist",
  ),
  code_not_found: new ApiError("not_found", 404, "No one has this code"),
  invite_closed: new ApiError(
    "out_of_window",
    409,
    "This invitation was already used or has expired",
  ),
  friend_self: new ApiError("invalid_request", 400, "That invitation is yours"),
  too_many_invites: new ApiError(
    "rate_limited",
    429,
    "Too many open invitations",
  ),
  too_many_requests: new ApiError(
    "rate_limited",
    429,
    "Too many open requests",
  ),
  friend_limit: new ApiError("plan_limit", 403, "Too many friends"),
};

async function rpc<T>(
  db: SupabaseClient,
  fn: string,
  args: Record<string, unknown>,
): Promise<T> {
  const { data, error } = await db.rpc(fn, args);
  if (error) {
    const known = SQL_ERRORS[error.message];
    if (known) throw known;
    throw new Error(`${fn} failed: ${error.message}`);
  }
  return data as T;
}

type Body = Record<string, unknown>;

async function act(deps: Deps, user: string, body: Body): Promise<Response> {
  const { db } = deps;
  switch (body.action) {
    case "invite": {
      const t = (deps.token ?? newToken)();
      const rows = await rpc<{ id: string; expires_at: string }[]>(
        db,
        "friend_invite_create",
        {
          p_user: user,
          p_token_hash: await hashToken(t),
          p_ttl_hours: INVITE_TTL_HOURS,
        },
      );
      const row = rows?.[0];
      if (!row) throw new Error("friend_invite_create returned nothing");
      return json({
        id: row.id,
        url: inviteUrl(t, deps.base),
        expires_at: new Date(row.expires_at).toISOString(),
      });
    }
    case "preview": {
      const rows = await rpc<
        { display_name: string | null; emoji: string | null; state: string }[]
      >(db, "friend_invite_preview", {
        p_user: user,
        p_token_hash: await hashToken(token(body.token)),
      });
      const row = rows?.[0];
      if (!row) throw SQL_ERRORS.invite_not_found;
      return json({
        state: row.state,
        display_name: row.display_name,
        emoji: row.emoji,
      });
    }
    case "accept":
    case "decline": {
      const friend = await rpc<string | null>(db, "friend_invite_respond", {
        p_user: user,
        p_token_hash: await hashToken(token(body.token)),
        p_accept: body.action === "accept",
      });
      return json({ friend_id: friend ?? null });
    }
    case "request": {
      const code = normalizeCode(body.code);
      if (!code) {
        throw new ApiError(
          "invalid_request",
          400,
          "A friend code is 8 letters and digits",
        );
      }
      await checkRate(user, "friends-code", CODE_TRIES_PER_HOUR, 60, db);
      const result = await rpc<string>(db, "friend_request_by_code", {
        p_user: user,
        p_code: code,
      });
      return json({ result });
    }
    case "respond": {
      if (typeof body.accept !== "boolean") {
        throw new ApiError(
          "invalid_request",
          400,
          "accept must be true or false",
        );
      }
      const answered = await rpc<boolean>(db, "friend_request_respond", {
        p_user: user,
        p_invitation: uuid(body.invitation_id, "invitation_id"),
        p_accept: body.accept,
      });
      return json({ answered: answered === true });
    }
    case "revoke": {
      const revoked = await rpc<boolean>(db, "friend_invite_revoke", {
        p_user: user,
        p_invitation: uuid(body.invitation_id, "invitation_id"),
      });
      return json({ revoked: revoked === true });
    }
    case "reset_code": {
      const code = await rpc<string>(db, "friend_code_reset", { p_user: user });
      return json({ code });
    }
    default:
      throw new ApiError("invalid_request", 400, "Unknown action");
  }
}

export async function handler(req: Request, deps: Deps): Promise<Response> {
  try {
    if (req.method !== "POST") {
      throw new ApiError("invalid_request", 405, "POST only");
    }
    const { userId } = await requireUser(req, deps.verifier);
    let body: unknown;
    try {
      body = await req.json();
    } catch {
      throw new ApiError("invalid_request", 400, "Body must be JSON");
    }
    if (!body || typeof body !== "object" || Array.isArray(body)) {
      throw new ApiError("invalid_request", 400, "Body must be an object");
    }
    await checkRate(userId, "friends", FRIENDS_MAX_PER_HOUR, 60, deps.db);
    return await act(deps, userId, body as Body);
  } catch (e) {
    return errorResponse(e);
  }
}
