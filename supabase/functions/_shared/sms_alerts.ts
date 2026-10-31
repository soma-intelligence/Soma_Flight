// Alerts by text message (iMessage or SMS through the Soma Linq line): the plumbing only, OFF.
//
// Nothing here sends a message. `smsEnabled` is false unless the SMS_ALERTS_ENABLED secret is exactly
// "true", and push-sender passes no `SmsSender` at all (index.ts), so the hook returns before it reads a
// row. Turning it on needs the owner's yes, a Linq sender written against their API, the sms-verify
// function (code by text, never built yet) and an App Store privacy label update (phone number).
// Design: docs/sms-alerts.md. Table: migration 20261031000024_sms_alerts.sql.
import type { SupabaseClient } from "npm:@supabase/supabase-js@2";
import type { Alert, AlertCategory, AlertKind } from "./alerts.ts";
import type { AlertText } from "./alert_copy.ts";

export const SMS_FLAG = "SMS_ALERTS_ENABLED";

/** True only when the flag secret is exactly "true". Anything else, or no secret, is off. */
export function smsEnabled(
  get: (name: string) => string | undefined = (n) => Deno.env.get(n),
): boolean {
  return get(SMS_FLAG) === "true";
}

/**
 * The alerts worth a text: the ones that change what the traveller does next. Take-off, landing, belts
 * and predictions stay push only; a delay goes by text from 30 minutes.
 */
export const SMS_KINDS: ReadonlySet<AlertKind> = new Set<AlertKind>([
  "departure_delay",
  "gate_change",
  "cancel",
  "diversion",
  "connection_at_risk",
]);
export const SMS_MIN_DELAY = 30;

export function wantsSms(a: Alert): boolean {
  if (!SMS_KINDS.has(a.kind)) return false;
  if (a.kind === "departure_delay") return (a.minutes ?? 0) >= SMS_MIN_DELAY;
  return true;
}

/** "+1 (415) 555-0100", "415 555 0100" (US default) or "+33 6 12 34 56 78" as E.164; null otherwise. */
export function normalisePhone(
  raw: string,
  defaultCountry = "1",
): string | null {
  const t = raw.trim();
  const plus = t.startsWith("+") || t.startsWith("00");
  const digits = t.replace(/^00/, "").replace(/[^0-9]/g, "");
  let e164: string;
  if (plus) e164 = `+${digits}`;
  // North American numbers: the area code never starts with 0 or 1.
  else if (defaultCountry === "1" && /^[2-9][0-9]{9}$/.test(digits)) {
    e164 = `+1${digits}`;
  } else if (defaultCountry === "1" && /^1[2-9][0-9]{9}$/.test(digits)) {
    e164 = `+${digits}`;
  } else return null;
  return /^\+[1-9][0-9]{7,14}$/.test(e164) ? e164 : null;
}

// Verification codes: six digits by text, kept only as a hash, ten minutes, five tries.
export const CODE_TTL_MS = 10 * 60 * 1000;
export const MAX_ATTEMPTS = 5;

/** Six random digits from the platform's CSPRNG. */
export function newCode(
  random: (a: Uint32Array) => Uint32Array = (a) => crypto.getRandomValues(a),
): string {
  const n = random(new Uint32Array(1))[0] % 1_000_000;
  return n.toString().padStart(6, "0");
}

/** SHA-256 hex of the phone, the code and a server secret, so a read of the table opens nothing. */
export async function hashCode(
  phone: string,
  code: string,
  pepper: string,
): Promise<string> {
  const bytes = new TextEncoder().encode(`${phone}:${code}:${pepper}`);
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", bytes));
  return [...digest].map((b) => b.toString(16).padStart(2, "0")).join("");
}

export interface SmsRow {
  user_id: string;
  phone_e164: string | null;
  code_hash: string | null;
  code_expires_at: string | null;
  attempts: number;
  verified_at: string | null;
  enabled: boolean;
  opted_out_at: string | null;
}

export type CodeCheck = "ok" | "none" | "expired" | "locked" | "wrong";

/** Whether `code` verifies the row's pending number at `now`. Wrong tries count against MAX_ATTEMPTS. */
export async function checkCode(
  row: SmsRow,
  code: string,
  pepper: string,
  now: Date,
): Promise<CodeCheck> {
  if (!row.code_hash || !row.code_expires_at || !row.phone_e164) return "none";
  if (row.attempts >= MAX_ATTEMPTS) return "locked";
  if (Date.parse(row.code_expires_at) <= now.getTime()) return "expired";
  if (!/^[0-9]{6}$/.test(code)) return "wrong";
  const h = await hashCode(row.phone_e164, code, pepper);
  return h === row.code_hash ? "ok" : "wrong";
}

/** A row that may receive texts: verified, switched on, not opted out (STOP), with a number. */
export function canText(row: SmsRow): boolean {
  return row.enabled && row.verified_at !== null && row.opted_out_at === null &&
    row.phone_e164 !== null;
}

/** "Soma Flight: AF 84 gate change. Now gate K40. Reply STOP to stop." Under two SMS segments. */
export function smsText(t: AlertText): string {
  const head = `Soma Flight: ${t.title}.`;
  const tail = " Reply STOP to stop.";
  const room = 300 - head.length - tail.length - 1;
  const body = t.body.length > room
    ? `${t.body.slice(0, room - 1).trimEnd()}…`
    : t.body;
  return `${head} ${body}${tail}`;
}

export interface SmsMessage {
  userId: string;
  to: string;
  text: string;
  kind: AlertKind;
}

/**
 * The texts one alert is worth: to each follower in `users` whose row can text, who has not turned the
 * alert's category off. Pure, so the rules are tested without a database or a network.
 */
export function planSms(
  alert: Alert,
  text: AlertText,
  users: Set<string>,
  rows: SmsRow[],
  muted: Map<AlertCategory, Set<string>>,
): SmsMessage[] {
  if (!wantsSms(alert)) return [];
  const off = muted.get(alert.category) ?? new Set<string>();
  return rows
    .filter((r) => users.has(r.user_id) && !off.has(r.user_id) && canText(r))
    .map((r) => ({
      userId: r.user_id,
      to: r.phone_e164!,
      text: smsText(text),
      kind: alert.kind,
    }));
}

/** What sends a text. No implementation ships: a Linq sender is written only on the owner's yes. */
export interface SmsSender {
  send(to: string, text: string): Promise<{ ok: boolean }>;
}

export interface SmsHookDeps {
  db: SupabaseClient;
  /** The sender; undefined (as in production today) means nothing is sent. */
  sender?: SmsSender;
  /** The flag; defaults to the SMS_ALERTS_ENABLED secret. */
  enabled?: () => boolean;
}

export interface SmsTally {
  sent: number;
  failed: number;
  skipped?: "disabled" | "no_sender" | "nothing_to_send";
}

/**
 * push-sender's hook, called once per delivered alert after the pushes. Returns before touching the
 * database when the flag is off or no sender is wired, which is the state this ships in.
 */
export async function smsHook(
  deps: SmsHookDeps | undefined,
  alert: Alert,
  text: AlertText,
  users: Set<string>,
  muted: Map<AlertCategory, Set<string>>,
): Promise<SmsTally> {
  if (!deps || !(deps.enabled ?? smsEnabled)()) {
    return { sent: 0, failed: 0, skipped: "disabled" };
  }
  if (!deps.sender) return { sent: 0, failed: 0, skipped: "no_sender" };
  if (!wantsSms(alert) || users.size === 0) {
    return { sent: 0, failed: 0, skipped: "nothing_to_send" };
  }
  const ids = [...users];
  const rows: SmsRow[] = [];
  for (let i = 0; i < ids.length; i += 200) {
    const { data, error } = await deps.db.from("sms_alerts")
      .select(
        "user_id, phone_e164, code_hash, code_expires_at, attempts, verified_at, enabled, opted_out_at",
      )
      .in("user_id", ids.slice(i, i + 200))
      .eq("enabled", true);
    if (error) throw new Error(`sms_alerts read failed: ${error.message}`);
    rows.push(...(data ?? []) as SmsRow[]);
  }
  const tally: SmsTally = { sent: 0, failed: 0 };
  for (const m of planSms(alert, text, users, rows, muted)) {
    try {
      const r = await deps.sender.send(m.to, m.text);
      if (r.ok) tally.sent++;
      else tally.failed++;
    } catch {
      tally.failed++;
    }
  }
  return tally;
}
