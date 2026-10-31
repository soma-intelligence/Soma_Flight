// POST /sms-inbound: Linq's webhook for the texts people send back to the Soma line (docs/sms-alerts.md).
// Signed the Standard Webhooks way with LINQ_WEBHOOK_SECRET (linq.ts verifyWebhook), so the gateway's JWT
// check is off for it (config.toml). Only `message.received` events from a number in sms_alerts are acted
// on, and only for the carrier keywords: the line is shared with the Soma companion, whose conversations
// pass through untouched.
//   STOP, STOPALL, UNSUBSCRIBE, CANCEL, END, QUIT: opted_out_at now, both switches off, one reply.
//   HELP, INFO: the support link.
//   START, UNSTOP, YES: texts come back only through a new verification in the app, said in the reply.
// Each event id is kept (sms_inbound_events), so Linq's at least once delivery acts once.
// Logs carry the event kind and the keyword, never the number or the words.
import type { SupabaseClient } from "npm:@supabase/supabase-js@2";
import { errorResponse, json } from "../_shared/errors.ts";
import { readInbound, verifyWebhook } from "../_shared/linq.ts";
import {
  normalisePhone,
  smsEnabled,
  type SmsSender,
} from "../_shared/sms_alerts.ts";

export const STOP_WORDS = new Set([
  "STOP",
  "STOPALL",
  "UNSUBSCRIBE",
  "CANCEL",
  "END",
  "QUIT",
]);
export const HELP_WORDS = new Set(["HELP", "INFO"]);
export const START_WORDS = new Set(["START", "UNSTOP", "YES"]);

export const STOP_REPLY =
  "Soma Flight: you will get no more flight texts. To turn them back on, verify your number again in the app.";
export const HELP_REPLY =
  "Soma Flight flight alerts. Help: https://somalabs.me/support. Msg and data rates may apply. Reply STOP to stop.";
export const START_REPLY =
  "Soma Flight: to get flight texts again, open the app, Settings > Notifications > Text Me Too, and verify your number.";

export type Keyword = "stop" | "help" | "start";

/** The keyword a text is, read as carriers do: the whole message, case and spacing ignored. */
export function keywordOf(text: string): Keyword | null {
  const w = text.trim().replace(/[.!]+$/, "").toUpperCase();
  if (STOP_WORDS.has(w)) return "stop";
  if (HELP_WORDS.has(w)) return "help";
  if (START_WORDS.has(w)) return "start";
  return null;
}

export interface Deps {
  db: SupabaseClient;
  /** Replies go through it; none (no LINQ_API_KEY) still records a STOP. */
  sender?: SmsSender;
  /** The webhook's signing secret; defaults to LINQ_WEBHOOK_SECRET. */
  secret?: () => string | undefined;
  enabled?: () => boolean;
  now?: () => Date;
}

export async function handler(req: Request, deps: Deps): Promise<Response> {
  try {
    if (req.method !== "POST") return json({ ok: false }, 405);
    const raw = await req.text();
    const now = (deps.now ?? (() => new Date()))();
    const secret = (deps.secret ?? (() =>
      Deno.env.get("LINQ_WEBHOOK_SECRET")))();
    if (!(await verifyWebhook(req.headers, raw, secret, now))) {
      // 401 is not retried by Linq, which is right for a request that is not theirs.
      return json({ ok: false }, 401);
    }
    let payload: unknown;
    try {
      payload = JSON.parse(raw);
    } catch {
      return json({ ok: false }, 400);
    }
    const msg = readInbound(payload);
    if (!msg) return json({ ok: true, ignored: "event" });
    const keyword = keywordOf(msg.text);
    const phone = normalisePhone(msg.from);
    if (!keyword || !phone) return json({ ok: true, ignored: "not_a_keyword" });

    const { db } = deps;
    const rows = await db.from("sms_alerts").select("user_id, opted_out_at")
      .eq("phone_e164", phone);
    if (rows.error) {
      throw new Error(`sms_alerts read failed: ${rows.error.message}`);
    }
    // Someone the alerts never texted: the companion's business, not ours.
    if ((rows.data ?? []).length === 0) {
      return json({ ok: true, ignored: "unknown_number" });
    }
    const seen = await db.from("sms_inbound_events").upsert(
      { event_id: msg.eventId },
      { onConflict: "event_id", ignoreDuplicates: true },
    ).select("event_id");
    if (seen.error) {
      throw new Error(`inbound event write failed: ${seen.error.message}`);
    }
    if ((seen.data ?? []).length === 0) {
      return json({ ok: true, duplicate: true });
    }

    if (keyword === "stop") {
      const { error } = await db.from("sms_alerts").update({
        opted_out_at: now.toISOString(),
        enabled: false,
        in_flight: false,
      }).eq("phone_e164", phone);
      if (error) throw new Error(`sms_alerts stop failed: ${error.message}`);
    }
    console.log(`sms-inbound: keyword=${keyword}`);
    // The reply to a STOP is the one text a stopped number gets; the others only while texts are on.
    const reply = keyword === "stop"
      ? STOP_REPLY
      : keyword === "help"
      ? HELP_REPLY
      : START_REPLY;
    if (deps.sender && (keyword === "stop" || (deps.enabled ?? smsEnabled)())) {
      try {
        await deps.sender.send(phone, reply, {
          idempotencyKey: `reply:${msg.eventId}`,
        });
      } catch {
        console.error("sms-inbound: reply failed");
      }
    }
    return json({ ok: true, keyword });
  } catch (e) {
    return errorResponse(e);
  }
}
