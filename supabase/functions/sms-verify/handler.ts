// POST /sms-verify { action, ... }: the signed-in traveller's number for texts (docs/sms-alerts.md).
//   status { flightId? }        -> the row as the app shows it (never the code hash), and the flight switch
//   start  { phone }            -> sends a six digit code to the number (3 an hour per account and number)
//   check  { code }             -> verifies it: Text Me Too switches on
//   settings { enabled?, inFlight? } -> the account's two switches (a verified number only)
//   flight { flightId, inFlight }    -> the flight sheet's "Text Me Updates In Flight" (null follows the account)
//   forget {}                   -> deletes the row, forgetting the number
// Everything but status answers 503 while SMS_ALERTS_ENABLED is off; start also needs the sender (no
// LINQ_API_KEY: 503) and the SMS_CODE_PEPPER secret. The number and the code are never logged.
import type { SupabaseClient } from "npm:@supabase/supabase-js@2";
import { requireUser, type TokenVerifier } from "../_shared/auth.ts";
import { ApiError, errorResponse, json } from "../_shared/errors.ts";
import {
  checkCode,
  CODE_TTL_MS,
  hashCode,
  MAX_ATTEMPTS,
  newCode,
  normalisePhone,
  SMS_COLUMNS,
  smsEnabled,
  type SmsRow,
  type SmsSender,
} from "../_shared/sms_alerts.ts";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export interface Deps {
  db: SupabaseClient;
  verifier?: TokenVerifier;
  /** The Linq sender; undefined (no LINQ_API_KEY) refuses to send codes. */
  sender?: SmsSender;
  /** The flag; defaults to the SMS_ALERTS_ENABLED secret. */
  enabled?: () => boolean;
  /** The server secret mixed into code hashes; defaults to SMS_CODE_PEPPER. */
  pepper?: () => string | undefined;
  now?: () => Date;
}

/** What the app shows. `phone` is the owner's own number (theirs to see), null when there is none. */
export interface SmsStatus {
  available: boolean;
  phone: string | null;
  pending: boolean;
  verified: boolean;
  enabled: boolean;
  inFlight: boolean;
  optedOut: boolean;
  /** The flight's own switch when `flightId` was asked: true, false, or null (follows the account). */
  flightInFlight?: boolean | null;
}

/** "Soma Flight code: 123456. It expires in 10 minutes. Reply STOP to stop." */
export function codeText(code: string): string {
  return `Soma Flight code: ${code}. It expires in 10 minutes. If you did not ask for it, ignore this text. Reply STOP to stop.`;
}

async function rowOf(db: SupabaseClient, user: string): Promise<SmsRow | null> {
  const { data, error } = await db.from("sms_alerts").select(SMS_COLUMNS)
    .eq("user_id", user).maybeSingle();
  if (error) throw new Error(`sms_alerts read failed: ${error.message}`);
  return (data as SmsRow | null) ?? null;
}

function statusOf(
  row: SmsRow | null,
  available: boolean,
  now: Date,
): SmsStatus {
  return {
    available,
    phone: row?.phone_e164 ?? null,
    pending: !!row?.code_hash && !!row.code_expires_at &&
      Date.parse(row.code_expires_at) > now.getTime() &&
      row.attempts < MAX_ATTEMPTS,
    verified: !!row?.verified_at,
    enabled: row?.enabled ?? false,
    inFlight: row?.in_flight ?? false,
    optedOut: !!row?.opted_out_at,
  };
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
    const now = (deps.now ?? (() => new Date()))();
    const available = (deps.enabled ?? smsEnabled)();
    const { db } = deps;

    if (body.action === "status") {
      const out = statusOf(await rowOf(db, userId), available, now);
      if (typeof body.flightId === "string" && UUID.test(body.flightId)) {
        const { data, error } = await db.from("sms_flight_prefs")
          .select("in_flight").eq("user_id", userId)
          .eq("flight_id", body.flightId).maybeSingle();
        if (error) {
          throw new Error(`sms_flight_prefs read failed: ${error.message}`);
        }
        out.flightInFlight = (data?.in_flight as boolean | undefined) ?? null;
      }
      return json(out);
    }
    if (body.action === "forget") {
      // Always allowed, flag or not: forgetting a number is never blocked.
      const { error } = await db.from("sms_alerts").delete().eq(
        "user_id",
        userId,
      );
      if (error) throw new Error(`sms_alerts delete failed: ${error.message}`);
      return json(statusOf(null, available, now));
    }
    if (!available) {
      throw new ApiError(
        "provider_unavailable",
        503,
        "Texts are not available yet",
      );
    }

    switch (body.action) {
      case "start":
        return json(await start(deps, userId, body.phone, now));
      case "check":
        return json(await check(deps, userId, body.code, now));
      case "settings":
        return json(await settings(db, userId, body, now));
      case "flight":
        return json(await flightSwitch(db, userId, body));
      default:
        throw new ApiError("invalid_request", 400, "Unknown action");
    }
  } catch (e) {
    return errorResponse(e);
  }
}

async function start(
  deps: Deps,
  userId: string,
  raw: unknown,
  now: Date,
): Promise<SmsStatus> {
  const phone = typeof raw === "string" ? normalisePhone(raw) : null;
  if (!phone) {
    throw new ApiError(
      "invalid_request",
      400,
      "Enter a number with its country code",
    );
  }
  const pepper = (deps.pepper ?? (() => Deno.env.get("SMS_CODE_PEPPER")))();
  if (!deps.sender || !pepper) {
    console.error("sms-verify: no sender or no SMS_CODE_PEPPER, code not sent");
    throw new ApiError(
      "provider_unavailable",
      503,
      "Texts are not available yet",
    );
  }
  const { db } = deps;
  const taken = await db.from("sms_alerts").select("user_id")
    .eq("phone_e164", phone).not("verified_at", "is", null).maybeSingle();
  if (taken.error) {
    throw new Error(`sms_alerts read failed: ${taken.error.message}`);
  }
  if (taken.data && taken.data.user_id !== userId) {
    throw new ApiError(
      "invalid_request",
      409,
      "This number is already used by another account",
    );
  }
  const allowed = await db.rpc("sms_code_allowed", {
    p_user: userId,
    p_phone_hash: await hashCode(phone, "rate", pepper),
  });
  if (allowed.error) {
    throw new Error(`sms_code_allowed failed: ${allowed.error.message}`);
  }
  if (allowed.data !== true) {
    throw new ApiError(
      "rate_limited",
      429,
      "Too many codes. Try again in an hour.",
    );
  }
  const code = newCode();
  const before = await rowOf(db, userId);
  // A new code makes the number pending again: no texts until it is checked. A STOP stays recorded
  // until then, so an unchecked number never starts receiving.
  const row = {
    user_id: userId,
    phone_e164: phone,
    code_hash: await hashCode(phone, code, pepper),
    code_expires_at: new Date(now.getTime() + CODE_TTL_MS).toISOString(),
    attempts: 0,
    verified_at: null,
    enabled: false,
    in_flight: false,
    opted_out_at: before?.opted_out_at ?? null,
  };
  const { error } = await db.from("sms_alerts").upsert(row, {
    onConflict: "user_id",
  });
  if (error) throw new Error(`sms_alerts write failed: ${error.message}`);
  const sent = await deps.sender.send(phone, codeText(code));
  if (!sent.ok) {
    throw new ApiError(
      "provider_unavailable",
      502,
      "The code could not be sent. Try again.",
    );
  }
  return statusOf(row as SmsRow, true, now);
}

async function check(
  deps: Deps,
  userId: string,
  raw: unknown,
  now: Date,
): Promise<SmsStatus & { result: string; triesLeft: number }> {
  const pepper = (deps.pepper ?? (() => Deno.env.get("SMS_CODE_PEPPER")))();
  if (!pepper) {
    throw new ApiError(
      "provider_unavailable",
      503,
      "Texts are not available yet",
    );
  }
  const { db } = deps;
  const row = await rowOf(db, userId);
  const code = typeof raw === "string" ? raw.trim() : "";
  const result = row ? await checkCode(row, code, pepper, now) : "none";
  if (!row || result !== "ok") {
    let attempts = row?.attempts ?? 0;
    if (row && result === "wrong") {
      attempts = Math.min(10, attempts + 1);
      const { error } = await db.from("sms_alerts").update({ attempts })
        .eq("user_id", userId);
      if (error) throw new Error(`sms_alerts write failed: ${error.message}`);
    }
    const s = statusOf(row ? { ...row, attempts } : null, true, now);
    return { ...s, result, triesLeft: Math.max(0, MAX_ATTEMPTS - attempts) };
  }
  const verified = {
    verified_at: now.toISOString(),
    opted_out_at: null,
    enabled: true,
    code_hash: null,
    code_expires_at: null,
    attempts: 0,
  };
  const { error } = await db.from("sms_alerts").update(verified).eq(
    "user_id",
    userId,
  );
  if (error) {
    // The unique index on verified numbers: another account verified it in the meantime.
    if (/duplicate|unique/i.test(error.message)) {
      throw new ApiError(
        "invalid_request",
        409,
        "This number is already used by another account",
      );
    }
    throw new Error(`sms_alerts write failed: ${error.message}`);
  }
  return {
    ...statusOf({ ...row, ...verified } as SmsRow, true, now),
    result: "ok",
    triesLeft: MAX_ATTEMPTS,
  };
}

async function settings(
  db: SupabaseClient,
  userId: string,
  body: Record<string, unknown>,
  now: Date,
): Promise<SmsStatus> {
  const patch: Record<string, boolean> = {};
  if (typeof body.enabled === "boolean") patch.enabled = body.enabled;
  if (typeof body.inFlight === "boolean") patch.in_flight = body.inFlight;
  if (Object.keys(patch).length === 0) {
    throw new ApiError("invalid_request", 400, "Nothing to change");
  }
  const row = await rowOf(db, userId);
  const turningOn = patch.enabled === true || patch.in_flight === true;
  if (turningOn && (!row?.verified_at || row.opted_out_at)) {
    throw new ApiError("invalid_request", 409, "Verify your number first");
  }
  if (!row) return statusOf(null, true, now);
  const { error } = await db.from("sms_alerts").update(patch).eq(
    "user_id",
    userId,
  );
  if (error) throw new Error(`sms_alerts write failed: ${error.message}`);
  return statusOf({ ...row, ...patch } as SmsRow, true, now);
}

async function flightSwitch(
  db: SupabaseClient,
  userId: string,
  body: Record<string, unknown>,
): Promise<{ flightId: string; flightInFlight: boolean | null }> {
  const flightId = body.flightId;
  if (typeof flightId !== "string" || !UUID.test(flightId)) {
    throw new ApiError("invalid_request", 400, "flightId must be a UUID");
  }
  const on = body.inFlight;
  if (on !== null && typeof on !== "boolean") {
    throw new ApiError(
      "invalid_request",
      400,
      "inFlight must be true, false or null",
    );
  }
  const follow = await db.from("user_flights").select("flight_id")
    .eq("user_id", userId).eq("flight_id", flightId).maybeSingle();
  if (follow.error) {
    throw new Error(`follow read failed: ${follow.error.message}`);
  }
  if (!follow.data) {
    throw new ApiError("not_found", 404, "You do not follow this flight");
  }
  if (on === true) {
    const row = await rowOf(db, userId);
    if (!row?.verified_at || row.opted_out_at) {
      throw new ApiError("invalid_request", 409, "Verify your number first");
    }
  }
  if (on === null) {
    const { error } = await db.from("sms_flight_prefs").delete()
      .eq("user_id", userId).eq("flight_id", flightId);
    if (error) {
      throw new Error(`sms_flight_prefs delete failed: ${error.message}`);
    }
  } else {
    const { error } = await db.from("sms_flight_prefs").upsert({
      user_id: userId,
      flight_id: flightId,
      in_flight: on,
      updated_at: new Date().toISOString(),
    }, { onConflict: "user_id,flight_id" });
    if (error) {
      throw new Error(`sms_flight_prefs write failed: ${error.message}`);
    }
  }
  return { flightId, flightInFlight: on };
}
