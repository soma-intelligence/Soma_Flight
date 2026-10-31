// Alerts by text message (iMessage or SMS through the Soma Linq line): the plumbing only, OFF.
//
// Nothing here sends a message while `smsEnabled` is false, which it is unless the SMS_ALERTS_ENABLED
// secret is exactly "true"; and the Linq sender (linq.ts) refuses without its LINQ_API_KEY secret, so the
// hook then has no sender. Two modes share one row per account:
// - "Text Me Too" (`enabled`): the alerts that change the next step (SMS_KINDS), next to the push;
// - "In-Flight Texts" (`in_flight`, or the flight sheet's switch in sms_flight_prefs): between boarding and
//   arrival at the gate, the alerts that matter on board (IN_FLIGHT_KINDS), for airline Wi-Fi that only
//   lets messaging apps through.
// An alert either mode wants is one text: claim_sms logs it per user, flight and alert key before the send.
// Design: docs/sms-alerts.md. Tables: migrations 20261031000024_sms_alerts.sql, 20261031000028_sms_in_flight.sql.
import type { SupabaseClient } from "npm:@supabase/supabase-js@2";
import type { Alert, AlertCategory, AlertFlight, AlertKind } from "./alerts.ts";
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
  /** The account's in-flight mode; rows read before migration 20261031000028 have none (off). */
  in_flight?: boolean;
}

export const SMS_COLUMNS =
  "user_id, phone_e164, code_hash, code_expires_at, attempts, verified_at, enabled, opted_out_at, in_flight";

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

/** A number texts may reach at all: verified, not opted out (STOP). */
export function canReach(row: SmsRow): boolean {
  return row.verified_at !== null && row.opted_out_at === null &&
    row.phone_e164 !== null;
}

/** A row that may receive "Text Me Too" texts: reachable and switched on. */
export function canText(row: SmsRow): boolean {
  return row.enabled && canReach(row);
}

// MARK: In-flight texts

/**
 * The alerts worth a text on board: what the traveller cannot see from the seat and needs before the
 * door opens. Departure news stays with "Text Me Too": once boarded it no longer changes the next step.
 */
export const IN_FLIGHT_KINDS: ReadonlySet<AlertKind> = new Set<AlertKind>([
  "arrival_delay",
  "diversion",
  "gate_assigned",
  "gate_change",
  "terminal_change",
  "baggage_belt",
  "connection_at_risk",
  "landing",
]);
/** An arrival delay goes by text on board from this many minutes late (not "back on time"). */
export const IN_FLIGHT_MIN_DELAY = 15;
/** The window opens this long before the best departure: boarding. */
export const BOARDING_LEAD_MIN = 45;
/** It stays open this long after arrival at the gate, for the belt and the arrival gate that follow. */
export const AFTER_GATE_MIN = 30;
/** With no arrival at the gate yet, it closes this long after the best arrival (a long hold, a diversion). */
export const LATE_ARRIVAL_GRACE_MIN = 180;

export function wantsInFlight(a: Alert): boolean {
  if (!IN_FLIGHT_KINDS.has(a.kind)) return false;
  if (a.kind === "arrival_delay") {
    return (a.minutes ?? 0) >= IN_FLIGHT_MIN_DELAY;
  }
  // Only the arrival end matters on board.
  if (
    a.kind === "gate_assigned" || a.kind === "gate_change" ||
    a.kind === "terminal_change"
  ) return a.side === "arrival";
  return true;
}

const ms = (v: string | null | undefined): number | null => {
  if (!v) return null;
  const t = Date.parse(v);
  return Number.isFinite(t) ? t : null;
};

/**
 * Whether `now` falls between boarding and a little after arrival at the gate for `f`: from
 * BOARDING_LEAD_MIN before the best departure (the push-back when known) to AFTER_GATE_MIN after
 * actual_in, or LATE_ARRIVAL_GRACE_MIN after the best arrival while the flight has not reached the gate.
 * Never for a canceled flight.
 */
export function inFlightWindow(f: AlertFlight, now: Date): boolean {
  if (f.status === "canceled") return false;
  const out = ms(f.estimated_out) ?? ms(f.scheduled_out);
  const pushed = ms(f.actual_out);
  const startsAt = Math.min(
    out === null ? Infinity : out - BOARDING_LEAD_MIN * 60_000,
    pushed ?? Infinity,
  );
  if (!Number.isFinite(startsAt)) return false;
  const gate = ms(f.actual_in);
  const due = ms(f.estimated_in) ?? ms(f.scheduled_in);
  const endsAt = gate !== null
    ? gate + AFTER_GATE_MIN * 60_000
    : due !== null
    ? due + LATE_ARRIVAL_GRACE_MIN * 60_000
    : startsAt + 20 * 3_600_000;
  const t = now.getTime();
  return t >= startsAt && t <= endsAt;
}

/** The account mode, overridden by the flight's own switch when the user set one. */
export function inFlightOn(
  row: SmsRow,
  flightSwitch: boolean | undefined,
): boolean {
  return flightSwitch ?? row.in_flight === true;
}

/** "Soma Flight: AF 84 gate change. Now gate K40. Reply STOP to stop." Under two SMS segments. */
export function smsText(t: AlertText, extra?: string): string {
  const head = `Soma Flight: ${t.title}.`;
  const tail = " Reply STOP to stop.";
  const full = extra ? `${t.body} ${extra}` : t.body;
  const room = 300 - head.length - tail.length - 1;
  const body = full.length > room
    ? `${full.slice(0, room - 1).trimEnd()}…`
    : full;
  return `${head} ${body}${tail}`;
}

export interface SmsMessage {
  userId: string;
  to: string;
  text: string;
  kind: AlertKind;
  /** The alert's key in alert_log, claimed per user in sms_log. */
  key: string;
  /** Which switch asked for it: the in-flight mode wins when both do. */
  mode: "standard" | "in_flight";
}

/** What the in-flight rules need about the flight an alert is for. */
export interface InFlightContext {
  /** inFlightWindow at the time of the alert. */
  open: boolean;
  /** Each user's flight switch (sms_flight_prefs), when they set one. */
  switches: Map<string, boolean>;
  /** A line to add per user (the landing text's onward connection). */
  notes?: Map<string, string>;
}

/**
 * The texts one alert is worth: to each follower in `users` whose number is reachable, who has not
 * turned the alert's category off, and whose "Text Me Too" switch wants it (SMS_KINDS) or whose in-flight
 * mode wants it while the window is open (IN_FLIGHT_KINDS). One text per user, whichever switch asked.
 * Pure, so the rules are tested without a database or a network.
 */
export function planSms(
  alert: Alert,
  text: AlertText,
  users: Set<string>,
  rows: SmsRow[],
  muted: Map<AlertCategory, Set<string>>,
  inFlight?: InFlightContext,
): SmsMessage[] {
  const standard = wantsSms(alert);
  const onBoard = inFlight?.open === true && wantsInFlight(alert);
  if (!standard && !onBoard) return [];
  const off = muted.get(alert.category) ?? new Set<string>();
  const out: SmsMessage[] = [];
  for (const r of rows) {
    if (!users.has(r.user_id) || off.has(r.user_id) || !canReach(r)) continue;
    const air = onBoard && inFlightOn(r, inFlight?.switches.get(r.user_id));
    if (!air && !(standard && r.enabled)) continue;
    out.push({
      userId: r.user_id,
      to: r.phone_e164!,
      text: smsText(text, air ? inFlight?.notes?.get(r.user_id) : undefined),
      kind: alert.kind,
      key: alert.key,
      mode: air ? "in_flight" : "standard",
    });
  }
  return out;
}

/** What sends a text: `LinqSender` (linq.ts) in production, fakes in tests. */
export interface SmsSender {
  send(
    to: string,
    text: string,
    opts?: { idempotencyKey?: string },
  ): Promise<{ ok: boolean }>;
}

export interface SmsHookDeps {
  db: SupabaseClient;
  /** The sender; undefined (no LINQ_API_KEY) means nothing is sent. */
  sender?: SmsSender;
  /** The flag; defaults to the SMS_ALERTS_ENABLED secret. */
  enabled?: () => boolean;
}

/** The flight an alert is for, when push-sender knows it: the in-flight window and the dedupe key. */
export interface SmsFlightContext {
  flightId: string;
  flight: AlertFlight;
  now: Date;
  /**
   * The onward connection line per user ("Next: AF 85 from gate K40..."), asked only when a landing
   * text goes to someone in in-flight mode, so a disabled or idle hook costs no read.
   */
  onward?: () => Promise<Map<string, string>>;
}

export interface SmsTally {
  sent: number;
  failed: number;
  /** Texts the dedupe or the per-account cap stopped. */
  deduped?: number;
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
  ctx?: SmsFlightContext,
): Promise<SmsTally> {
  if (!deps || !(deps.enabled ?? smsEnabled)()) {
    return { sent: 0, failed: 0, skipped: "disabled" };
  }
  if (!deps.sender) return { sent: 0, failed: 0, skipped: "no_sender" };
  const open = ctx ? inFlightWindow(ctx.flight, ctx.now) : false;
  const onBoard = open && wantsInFlight(alert);
  if ((!wantsSms(alert) && !onBoard) || users.size === 0) {
    return { sent: 0, failed: 0, skipped: "nothing_to_send" };
  }
  const ids = [...users];
  const rows: SmsRow[] = [];
  const switches = new Map<string, boolean>();
  for (let i = 0; i < ids.length; i += 200) {
    const chunk = ids.slice(i, i + 200);
    const { data, error } = await deps.db.from("sms_alerts")
      .select(SMS_COLUMNS)
      .in("user_id", chunk)
      .or("enabled.eq.true,in_flight.eq.true");
    if (error) throw new Error(`sms_alerts read failed: ${error.message}`);
    rows.push(...(data ?? []) as SmsRow[]);
    if (onBoard && ctx) {
      const prefs = await deps.db.from("sms_flight_prefs")
        .select("user_id, in_flight")
        .eq("flight_id", ctx.flightId)
        .in("user_id", chunk);
      if (prefs.error) {
        throw new Error(`sms_flight_prefs read failed: ${prefs.error.message}`);
      }
      for (const p of prefs.data ?? []) {
        switches.set(p.user_id as string, p.in_flight as boolean);
      }
    }
  }
  // Rows with only a flight switch on are read too: their account mode may be off.
  if (onBoard && ctx) {
    const missing = [...switches].filter(([u, on]) =>
      on && !rows.some((r) => r.user_id === u)
    ).map(([u]) => u);
    if (missing.length > 0) {
      const { data, error } = await deps.db.from("sms_alerts")
        .select(SMS_COLUMNS).in("user_id", missing);
      if (error) throw new Error(`sms_alerts read failed: ${error.message}`);
      rows.push(...(data ?? []) as SmsRow[]);
    }
  }
  const context: InFlightContext = { open: onBoard, switches };
  let plan = planSms(alert, text, users, rows, muted, context);
  if (
    alert.kind === "landing" && ctx?.onward &&
    plan.some((m) => m.mode === "in_flight")
  ) {
    try {
      context.notes = await ctx.onward();
      plan = planSms(alert, text, users, rows, muted, context);
    } catch (e) {
      // A failed connection read must not stop the landing text itself.
      console.error("sms onward read failed", (e as Error).message);
    }
  }
  const tally: SmsTally = { sent: 0, failed: 0, deduped: 0 };
  for (const m of plan) {
    if (ctx) {
      const { data, error } = await deps.db.rpc("claim_sms", {
        p_user: m.userId,
        p_flight: ctx.flightId,
        p_key: m.key,
      });
      if (error) {
        console.error(`sms claim failed: ${error.message}`);
        tally.failed++;
        continue;
      }
      if (data !== true) {
        tally.deduped!++;
        continue;
      }
    }
    try {
      const r = await deps.sender.send(m.to, m.text, {
        idempotencyKey: ctx
          ? `${ctx.flightId}:${m.userId}:${m.key}`.slice(0, 255)
          : undefined,
      });
      if (r.ok) tally.sent++;
      else tally.failed++;
    } catch {
      tally.failed++;
    }
  }
  return tally;
}

// MARK: Onward connection line

const VERDICT_WORDS: Record<string, string> = {
  comfortable: "comfortable",
  tight: "tight",
  at_risk: "at risk",
  missed: "may be missed",
};

/**
 * The landing text's connection line, the Connection Assistant's verdict in words: "Next: AF 85 from
 * gate K40 at 3:10 PM, 55m to connect, comfortable." Gate and time are left out when unknown.
 */
export function onwardLine(
  ident: string,
  verdict: string,
  layoverMinutes: number | null,
  gate: string | null | undefined,
  at: string | null,
): string {
  const where = gate ? ` from gate ${gate}` : "";
  const when = at ? ` at ${at}` : "";
  const gap = layoverMinutes !== null && layoverMinutes >= 0
    ? `, ${spanText(layoverMinutes)} to connect`
    : "";
  const words = VERDICT_WORDS[verdict] ?? verdict;
  return `Next: ${ident}${where}${when}${gap}, ${words}.`;
}

function spanText(minutes: number): string {
  const m = Math.round(minutes);
  const h = Math.floor(m / 60), r = m % 60;
  if (h === 0) return `${r}m`;
  return r === 0 ? `${h}h` : `${h}h ${r}m`;
}
