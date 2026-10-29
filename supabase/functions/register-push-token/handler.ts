// POST /register-push-token { token, kind, flightId?, platform } -> { ok: true }
// Clients never write push_tokens directly. The token is unique per (token, kind): registering
// it again moves it to the caller, which is what a second account on one device needs.
import type { SupabaseClient } from "npm:@supabase/supabase-js@2";
import { requireUser, type TokenVerifier } from "../_shared/auth.ts";
import { ApiError, errorResponse, json } from "../_shared/errors.ts";
import { checkRate } from "../_shared/limits.ts";

export const REGISTER_MAX_PER_HOUR = 60;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
/** Device tokens are 32 bytes today, Live Activity tokens longer; leave room both ways. */
const TOKEN = /^(?:[0-9a-f]{2}){32,200}$/i;
const PLATFORMS = ["ios", "ipados"];

export interface Deps {
  db: SupabaseClient;
  verifier?: TokenVerifier;
}

export async function handler(req: Request, deps: Deps): Promise<Response> {
  try {
    if (req.method !== "POST") {
      throw new ApiError("invalid_request", 405, "Use POST");
    }
    const { userId } = await requireUser(req, deps.verifier);
    let body: Record<string, unknown>;
    try {
      body = await req.json();
    } catch {
      throw new ApiError("invalid_request", 400, "Invalid JSON");
    }
    const { token, kind, flightId } = body;
    const platform = body.platform ?? "ios";
    if (typeof token !== "string" || !TOKEN.test(token)) {
      throw new ApiError("invalid_request", 400, "token must be hex");
    }
    if (kind !== "alert" && kind !== "live_activity") {
      throw new ApiError(
        "invalid_request",
        400,
        "kind must be alert or live_activity",
      );
    }
    if (typeof platform !== "string" || !PLATFORMS.includes(platform)) {
      throw new ApiError("invalid_request", 400, "unsupported platform");
    }
    if (kind === "live_activity") {
      if (typeof flightId !== "string" || !UUID.test(flightId)) {
        throw new ApiError(
          "invalid_request",
          400,
          "flightId is required for live_activity",
        );
      }
    } else if (flightId !== undefined && flightId !== null) {
      throw new ApiError(
        "invalid_request",
        400,
        "flightId is only for live_activity",
      );
    }
    await checkRate(
      userId,
      "register-push-token",
      REGISTER_MAX_PER_HOUR,
      60,
      deps.db,
    );

    if (kind === "live_activity") {
      const { data, error } = await deps.db.from("user_flights").select(
        "flight_id",
      )
        .eq("user_id", userId).eq("flight_id", flightId as string)
        .maybeSingle();
      if (error) throw new Error(`follow read failed: ${error.message}`);
      if (!data) {
        throw new ApiError("not_found", 404, "You do not follow this flight");
      }
    }
    const lower = token.toLowerCase();
    const prev = await deps.db.from("push_tokens").select("user_id")
      .eq("token", lower).eq("kind", kind).maybeSingle();
    if (prev.data && prev.data.user_id !== userId) {
      console.log(
        `push token reassigned kind=${kind} from=${prev.data.user_id} to=${userId}`,
      );
    }
    const { error } = await deps.db.from("push_tokens").upsert({
      user_id: userId,
      token: lower,
      bad_count: 0,
      kind,
      flight_id: kind === "live_activity" ? flightId as string : null,
      platform,
      updated_at: new Date().toISOString(),
    }, { onConflict: "token,kind" });
    if (error) throw new Error(`token upsert failed: ${error.message}`);
    return json({ ok: true });
  } catch (e) {
    return errorResponse(e);
  }
}
