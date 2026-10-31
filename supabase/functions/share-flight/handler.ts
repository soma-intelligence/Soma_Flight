// Live flight sharing for the flight sheet's Share and "Stop Sharing" (docs/api-contract.md).
//
//   POST   /share-flight { flight_id }   -> { url, expires_at }       a new link to the flight
//   GET    /share-flight?flight_id=<id>  -> { active, expires_at }    whether the caller shares it now
//   DELETE /share-flight?flight_id=<id>  -> { revoked }               stops every link of the caller's
//
// A share is tied to one flight and one sharer. Only a flight the caller follows (user_flights) or keeps in
// the Passport (past_flights.flight_id) can be shared, and only until it expires: 24 hours after the flight
// arrives (_shared/share.ts). Each POST makes a new random token; the table keeps its SHA-256 only, so the
// link is answered once, here, and never read back. Stopping revokes all of the caller's links to the
// flight at once (the app does not track them one by one). Free: no provider call behind any of this.
import type { SupabaseClient } from "npm:@supabase/supabase-js@2";
import { requireUser, type TokenVerifier } from "../_shared/auth.ts";
import { ApiError, errorResponse, json } from "../_shared/errors.ts";
import { checkRate } from "../_shared/limits.ts";
import {
  type FlightTimes,
  hashToken,
  newToken,
  shareExpiresAt,
  shareUrl,
} from "../_shared/share.ts";

/** Creating, checking and stopping together: generous for a person, tight for a script. */
export const SHARE_MAX_PER_HOUR = 60;
const UUID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const TIMES =
  "scheduled_out, estimated_out, actual_out, scheduled_in, estimated_in, actual_in, scheduled_on, estimated_on, actual_on";

export interface Deps {
  db: SupabaseClient;
  verifier?: TokenVerifier;
  now?: () => Date;
  /** Where links point (SHARE_BASE_URL); somalabs.me/f/ otherwise. */
  base?: string | null;
  /** Test hook: the token generator (newToken otherwise). */
  token?: () => string;
}

function flightId(raw: unknown): string {
  if (typeof raw !== "string" || !UUID_RE.test(raw)) {
    throw new ApiError("invalid_request", 400, "flight_id must be a uuid");
  }
  return raw.toLowerCase();
}

/** True when the caller follows the flight or keeps it in the Passport. */
async function holds(
  db: SupabaseClient,
  userId: string,
  id: string,
): Promise<boolean> {
  const follow = await db.from("user_flights").select("flight_id")
    .eq("user_id", userId).eq("flight_id", id).maybeSingle();
  if (follow.error) {
    throw new Error(`follow read failed: ${follow.error.message}`);
  }
  if (follow.data) return true;
  const past = await db.from("past_flights").select("id")
    .eq("user_id", userId).eq("flight_id", id).limit(1);
  if (past.error) throw new Error(`past read failed: ${past.error.message}`);
  return (past.data ?? []).length > 0;
}

async function times(db: SupabaseClient, id: string): Promise<FlightTimes> {
  const f = await db.from("flights").select(TIMES).eq("id", id).maybeSingle();
  if (f.error) throw new Error(`flight read failed: ${f.error.message}`);
  if (!f.data) throw new ApiError("not_found", 404, "Unknown flight");
  return f.data as FlightTimes;
}

async function create(
  deps: Deps,
  userId: string,
  req: Request,
  now: Date,
): Promise<Response> {
  let body: unknown;
  try {
    body = await req.json();
  } catch {
    throw new ApiError("invalid_request", 400, "Body must be JSON");
  }
  const id = flightId((body as { flight_id?: unknown } | null)?.flight_id);
  const { db } = deps;
  // A flight the caller has nothing to do with answers as unknown: no probing other people's flights.
  if (!(await holds(db, userId, id))) {
    throw new ApiError("not_found", 404, "Unknown flight");
  }
  const expires = shareExpiresAt(await times(db, id), now);
  if (expires.getTime() <= now.getTime()) {
    throw new ApiError(
      "out_of_window",
      409,
      "This flight can no longer be shared",
    );
  }
  const token = (deps.token ?? newToken)();
  const ins = await db.from("flight_shares").insert({
    token_hash: await hashToken(token),
    flight_id: id,
    user_id: userId,
    created_at: now.toISOString(),
  });
  if (ins.error) throw new Error(`share write failed: ${ins.error.message}`);
  return json({
    url: shareUrl(token, deps.base),
    expires_at: expires.toISOString(),
  });
}

async function status(
  deps: Deps,
  userId: string,
  id: string,
  now: Date,
): Promise<Response> {
  const { db } = deps;
  const live = await db.from("flight_shares").select("created_at")
    .eq("user_id", userId).eq("flight_id", id).is("revoked_at", null)
    .order("created_at", { ascending: false }).limit(1);
  if (live.error) throw new Error(`share read failed: ${live.error.message}`);
  const newest = live.data?.[0];
  if (!newest) return json({ active: false, expires_at: null });
  const expires = shareExpiresAt(
    await times(db, id),
    new Date(newest.created_at),
  );
  const active = expires.getTime() > now.getTime();
  return json({ active, expires_at: active ? expires.toISOString() : null });
}

async function revoke(
  deps: Deps,
  userId: string,
  id: string,
  now: Date,
): Promise<Response> {
  const r = await deps.db.from("flight_shares")
    .update({ revoked_at: now.toISOString() })
    .eq("user_id", userId).eq("flight_id", id).is("revoked_at", null)
    .select("id");
  if (r.error) throw new Error(`share revoke failed: ${r.error.message}`);
  return json({ revoked: r.data?.length ?? 0 });
}

export async function handler(req: Request, deps: Deps): Promise<Response> {
  try {
    if (!["POST", "GET", "DELETE"].includes(req.method)) {
      throw new ApiError("invalid_request", 405, "POST, GET or DELETE");
    }
    const { userId } = await requireUser(req, deps.verifier);
    const now = (deps.now ?? (() => new Date()))();
    await checkRate(userId, "share-flight", SHARE_MAX_PER_HOUR, 60, deps.db);
    if (req.method === "POST") return await create(deps, userId, req, now);
    const id = flightId(new URL(req.url).searchParams.get("flight_id"));
    return req.method === "GET"
      ? await status(deps, userId, id, now)
      : await revoke(deps, userId, id, now);
  } catch (e) {
    return errorResponse(e);
  }
}
