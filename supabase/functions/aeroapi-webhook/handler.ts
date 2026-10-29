// POST /aeroapi-webhook?secret=<WEBHOOK_SECRET>: FlightAware AeroAPI alert deliveries.
//
// Flow: secret check (constant time, fails closed), size cap, raw body into webhook_inbox, then
// match the delivery to a followed flights row by fa_flight_id, update flights, insert one
// flight_events row keyed on sha256(raw body), record the delivery cost, call push-sender.
// Anything the provider cannot fix by retrying (bad JSON, unknown shape) answers 200 and keeps the
// inbox row with an error. Database failures answer 500 so the provider retries.
import type { SupabaseClient } from "npm:@supabase/supabase-js@2";
import { toFlightRow } from "../_shared/aeroapi.ts";
import type { AeroFlight } from "../_shared/aeroapi.ts";
import { json } from "../_shared/errors.ts";

export const MAX_BODY_BYTES = 256 * 1024;
/** AeroAPI bills each alert delivery as a query (docs/provider-check.md). */
export const ALERT_DELIVERY_COST = 0.02;
export const ALERT_USAGE_ENDPOINT = "alert_delivery";

export type EventKind =
  | "gate_change"
  | "delay"
  | "departure"
  | "arrival"
  | "cancel"
  | "diversion"
  | "position";

export interface Deps {
  db: SupabaseClient;
  /** Reads WEBHOOK_SECRET at request time. Undefined or empty rejects every request. */
  secret: () => string | undefined;
  /** The secret being rotated out, accepted alongside the current one. */
  previousSecret?: () => string | undefined;
  /** Notifies followers of a stored event. Failures are logged and never fail the webhook. */
  push: (flightId: string, eventId: string) => Promise<void>;
  now?: () => Date;
}

/** Default push dep: invokes the push-sender edge function with the service client. */
export function pushViaFunction(db: SupabaseClient): Deps["push"] {
  return async (flightId, eventId) => {
    const { error } = await db.functions.invoke("push-sender", {
      body: { flightId, eventId },
    });
    if (error) throw new Error(`push-sender failed: ${error.message}`);
  };
}

/** Event codes that always map to one kind. */
const FIXED_KIND: Record<string, EventKind> = {
  departure: "departure",
  arrival: "arrival",
  cancelled: "cancel",
  diverted: "diversion",
};
/**
 * Event codes that only refresh the flight. They produce an event when a gate/terminal/baggage
 * value or an estimated time actually changed, and nothing otherwise (out, off, on, in would
 * otherwise duplicate the departure and arrival pushes).
 */
const DIFF_CODES = new Set([
  "change",
  "filed",
  "minutes_out",
  "out",
  "off",
  "on",
  "in",
]);

const TIME_COLS = [
  "scheduled_out",
  "scheduled_in",
  "estimated_out",
  "estimated_in",
  "actual_out",
  "actual_off",
  "actual_on",
  "actual_in",
] as const;
/** payload key -> flights column. */
const PLACE_COLS: [string, string][] = [
  ["gate_origin", "gate_origin"],
  ["gate_destination", "gate_destination"],
  ["terminal_origin", "terminal_origin"],
  ["terminal_destination", "terminal_destination"],
  ["baggage_claim", "baggage_belt"],
];
const PLAIN_COLS = [
  "aircraft_type",
  "registration",
  "origin_icao",
  "origin_iata",
  "destination_icao",
  "destination_iata",
] as const;

type Row = Record<string, unknown>;

interface Alert {
  event_code: string;
  alert_id: number;
  flight: Row & { fa_flight_id: string };
  short_description?: unknown;
  summary?: unknown;
}

class Step extends Error {}

async function sha256Hex(bytes: Uint8Array<ArrayBuffer>): Promise<string> {
  const d = await crypto.subtle.digest("SHA-256", bytes);
  return [...new Uint8Array(d)].map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

/** Constant time string comparison: both sides are hashed to equal length first. */
export async function secretMatches(
  given: string,
  expected: string,
): Promise<boolean> {
  const enc = new TextEncoder();
  const [a, b] = await Promise.all([
    crypto.subtle.digest("SHA-256", enc.encode(given)),
    crypto.subtle.digest("SHA-256", enc.encode(expected)),
  ]);
  const x = new Uint8Array(a);
  const y = new Uint8Array(b);
  let diff = 0;
  for (let i = 0; i < x.length; i++) diff |= x[i] ^ y[i];
  return diff === 0;
}

/** Reads the body up to `max` bytes; null when it is larger. */
async function readCapped(
  req: Request,
  max: number,
): Promise<Uint8Array<ArrayBuffer> | null> {
  const declared = Number(req.headers.get("content-length"));
  if (Number.isFinite(declared) && declared > max) return null;
  if (!req.body) return new Uint8Array();
  const reader = req.body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    total += value.byteLength;
    if (total > max) {
      await reader.cancel();
      return null;
    }
    chunks.push(value);
  }
  const out = new Uint8Array(total);
  let at = 0;
  for (const c of chunks) {
    out.set(c, at);
    at += c.byteLength;
  }
  return out;
}

function asAlert(v: unknown): Alert | null {
  if (!v || typeof v !== "object" || Array.isArray(v)) return null;
  const o = v as Row;
  const f = o.flight as Row | undefined;
  if (typeof o.event_code !== "string") return null;
  if (!Number.isInteger(o.alert_id)) return null;
  if (!f || typeof f !== "object" || typeof f.fa_flight_id !== "string") {
    return null;
  }
  if (f.fa_flight_id.length === 0) return null;
  return o as unknown as Alert;
}

function instant(v: unknown): number | null {
  if (typeof v !== "string") return null;
  const t = Date.parse(v);
  return Number.isNaN(t) ? null : t;
}

function str(v: unknown, max = 500): string | null {
  return typeof v === "string" ? v.slice(0, max) : null;
}

interface Plan {
  update: Row;
  changes: Record<string, { from: unknown; to: unknown }>;
  placeChanged: boolean;
  /** Set when this delivery moves the flight to canceled or diverted. */
  statusTo: "canceled" | "diverted" | null;
  /** Current delay in minutes against schedule (worst of out and in), null when unknown. */
  delay: number | null;
}

/** A delay event fires from this many minutes, then whenever it moves this far from the last one. */
export const DELAY_STEP_MIN = 15;

const RANK: Record<string, number> = {
  unknown: -1,
  scheduled: 0,
  departed: 1,
  en_route: 2,
  landed: 3,
  arrived: 4,
};
const ACTUAL_OF: Record<string, (typeof TIME_COLS)[number]> = {
  estimated_out: "actual_out",
  estimated_in: "actual_in",
};

/**
 * What the delivery changes on the stored flight. Deliveries carry no timestamp, so ordering cannot
 * be proven; damage from a stale one is limited instead: null never wipes, an actual time is set
 * once, an estimate is ignored once its actual exists, status never goes backwards and canceled
 * and diverted are sticky.
 */
function plan(alert: Alert, stored: Row, now: Date): Plan {
  const f = alert.flight;
  const update: Row = {};
  const changes: Plan["changes"] = {};
  let placeChanged = false;

  const note = (col: string, to: unknown) => {
    update[col] = to;
    changes[col] = { from: stored[col] ?? null, to };
  };
  const have = (col: string) => update[col] ?? stored[col] ?? null;

  for (const col of TIME_COLS) {
    const to = f[col];
    if (typeof to !== "string" || instant(to) === null) continue;
    if (col.startsWith("actual") && stored[col] != null) continue;
    if (instant(to) === instant(stored[col])) continue;
    note(col, to);
  }
  // An estimate for a leg that already has its actual time is stale.
  for (const [est, act] of Object.entries(ACTUAL_OF)) {
    if (have(act) != null && est in update) {
      delete update[est];
      delete changes[est];
    }
  }
  for (const [key, col] of PLACE_COLS) {
    const to = f[key];
    if (typeof to === "string" && to !== "" && to !== stored[col]) {
      note(col, to);
      placeChanged = true;
    }
  }
  for (const col of PLAIN_COLS) {
    const to = f[col];
    if (typeof to === "string" && to !== "" && to !== stored[col]) {
      note(col, to);
    }
  }

  const sticky = stored.status === "canceled" || stored.status === "diverted" ||
    stored.status === "arrived";
  let statusTo: Plan["statusTo"] = null;
  if (!sticky) {
    if (alert.event_code === "cancelled" || f.cancelled === true) {
      statusTo = "canceled";
    } else if (alert.event_code === "diverted" || f.diverted === true) {
      statusTo = "diverted";
    }
  }
  if (statusTo) {
    note("status", statusTo);
  } else if (!sticky) {
    const probe = toFlightRow({
      fa_flight_id: f.fa_flight_id,
      ident: str(f.ident) ?? "",
      cancelled: false,
      diverted: false,
      actual_out: have("actual_out"),
      actual_off: have("actual_off"),
      actual_on: have("actual_on"),
      actual_in: have("actual_in"),
      status: "",
    } as unknown as AeroFlight, now);
    if ((RANK[probe.status] ?? -1) > (RANK[stored.status as string] ?? -1)) {
      note("status", probe.status);
    }
  }

  const minutes = (sched: string, est: string, act: string) => {
    const s = instant(have(sched));
    const e = instant(have(act)) ?? instant(have(est));
    return s === null || e === null ? null : Math.round((e - s) / 60000);
  };
  const dOut = minutes("scheduled_out", "estimated_out", "actual_out");
  const dIn = minutes("scheduled_in", "estimated_in", "actual_in");
  const known = [dOut, dIn].filter((d): d is number => d !== null);
  const delay = known.length ? Math.max(...known) : null;

  if (Object.keys(update).length > 0) update.updated_at = now.toISOString();
  return { update, changes, placeChanged, statusTo, delay };
}

function delayDue(delay: number | null, last: unknown): boolean {
  if (delay === null) return false;
  if (typeof last !== "number") return delay >= DELAY_STEP_MIN;
  return Math.abs(delay - last) >= DELAY_STEP_MIN;
}

function kindFor(alert: Alert, p: Plan, stored: Row): EventKind | null {
  const fixed = FIXED_KIND[alert.event_code];
  if (fixed) return fixed;
  if (p.statusTo === "canceled") return "cancel";
  if (p.statusTo === "diverted") return "diversion";
  if (!DIFF_CODES.has(alert.event_code)) return null;
  if (p.placeChanged) return "gate_change";
  if (delayDue(p.delay, stored.notified_delay_min)) return "delay";
  return null;
}

async function mark(
  db: SupabaseClient,
  inboxId: number,
  patch: { processed_at?: string; error?: string; note?: string },
): Promise<void> {
  const { error } = await db.from("webhook_inbox").update(patch).eq(
    "id",
    inboxId,
  );
  if (error) console.error(`inbox ${inboxId} not marked: ${error.message}`);
}

/** Secret check without early exit; any configured secret may match. */
async function authorised(
  given: string,
  secrets: (string | undefined)[],
): Promise<boolean> {
  let ok = false;
  for (const s of secrets.length ? secrets : [undefined]) {
    const match = await secretMatches(given, s ?? "");
    if (s && match) ok = true;
  }
  return ok;
}

/**
 * Replay rule for webhook_inbox: a row needs replay when error is not null and processed_at is
 * null (a failed attempt). Malformed or wrong-shape bodies carry an error and processed_at, since
 * a replay cannot fix them. Remarks that are not failures go in note.
 */
export async function handler(req: Request, deps: Deps): Promise<Response> {
  const { db } = deps;
  const now = (deps.now ?? (() => new Date()))();
  let inboxId: number | null = null;
  try {
    if (req.method !== "POST") {
      return json({ error: { code: "invalid_request" } }, 405);
    }
    const given = new URL(req.url).searchParams.get("secret") ?? "";
    if (!(await authorised(given, [deps.secret(), deps.previousSecret?.()]))) {
      return json({ error: { code: "unauthorized" } }, 401);
    }

    const bytes = await readCapped(req, MAX_BODY_BYTES);
    if (!bytes) return json({ error: { code: "payload_too_large" } }, 413);
    const text = new TextDecoder().decode(bytes);
    const eventId = await sha256Hex(bytes);

    let parsed: unknown;
    let malformed: string | null = null;
    try {
      parsed = JSON.parse(text);
      if (parsed === null || typeof parsed !== "object") {
        malformed = "malformed body: not a JSON object";
      } else if (JSON.stringify(parsed).includes("\\u0000")) {
        malformed = "malformed body: contains NUL";
      }
    } catch {
      malformed = "malformed body: not valid JSON";
    }

    const ins = await db.from("webhook_inbox").insert({
      body: malformed
        ? { _unparsed: text.replaceAll("\u0000", "\uFFFD") }
        : parsed,
      body_sha256: eventId,
      // A replay cannot fix these: error for the record, processed_at so they are not replayed.
      ...(malformed
        ? { error: malformed, processed_at: now.toISOString() }
        : {}),
    }).select("id").single();
    if (ins.error) throw new Step(`inbox insert failed: ${ins.error.message}`);
    inboxId = ins.data.id as number;
    if (malformed) return json({ ok: true, ignored: "malformed" });

    const alert = asAlert(parsed);
    if (!alert) {
      await mark(db, inboxId, {
        error: "invalid alert shape",
        processed_at: now.toISOString(),
      });
      return json({ ok: true, ignored: "invalid_shape" });
    }

    const flightRes = await db.from("flights").select("*").eq(
      "provider_id",
      alert.flight.fa_flight_id,
    ).maybeSingle();
    if (flightRes.error) {
      throw new Step(`flight read failed: ${flightRes.error.message}`);
    }
    const stored = flightRes.data as Row | null;
    let followed = false;
    if (stored) {
      const c = await db.from("user_flights").select("user_id", {
        count: "exact",
        head: true,
      }).eq("flight_id", stored.id as string);
      if (c.error) throw new Step(`follower read failed: ${c.error.message}`);
      followed = (c.count ?? 0) > 0;
    }

    let flightId: string | null = null;
    let kind: EventKind | null = null;
    let payload: Row = {};
    let update: Row = {};
    let noteText: string | null = null;
    if (!stored || !followed) {
      noteText = "no followed flight for this fa_flight_id";
    } else {
      flightId = stored.id as string;
      const p = plan(alert, stored, now);
      kind = kindFor(alert, p, stored);
      update = { ...p.update };
      delete update.updated_at;
      if (kind === "delay") update.notified_delay_min = p.delay;
      payload = {
        event_code: alert.event_code,
        alert_id: alert.alert_id,
        short_description: str(alert.short_description),
        summary: str(alert.summary),
        changes: p.changes,
        ...(kind === "delay"
          ? {
            delay_minutes: p.delay,
            previous_delay_minutes: stored.notified_delay_min ?? null,
          }
          : {}),
      };
      if (!kind) noteText = `${alert.event_code} produced no event`;
    }

    // One transaction: duplicate check, event, flight update, cost, inbox mark.
    const res = await db.rpc("process_alert", {
      p_inbox: inboxId,
      p_hash: eventId,
      p_flight: flightId,
      p_kind: kind,
      p_payload: payload,
      p_update: update,
      p_note: noteText,
      p_day: now.toISOString().slice(0, 10),
      p_cost: ALERT_DELIVERY_COST,
    });
    if (res.error) throw new Step(`process_alert failed: ${res.error.message}`);
    const out = res.data as { duplicate: boolean; event_id: string | null };
    if (out.duplicate) return json({ ok: true, duplicate: true });
    if (!out.event_id || !flightId) return json({ ok: true, event: null });

    // After the commit, so a crash before this point is reprocessed by the provider's retry.
    try {
      await deps.push(flightId, out.event_id);
    } catch (e) {
      console.error(
        `push failed for event ${out.event_id}`,
        e instanceof Error ? e.message : "unknown",
      );
    }
    return json({ ok: true, event: out.event_id, kind });
  } catch (e) {
    const msg = e instanceof Error ? e.message : "unknown error";
    console.error("aeroapi-webhook failed:", msg);
    if (inboxId !== null) await mark(db, inboxId, { error: msg });
    return json({ error: { code: "provider_unavailable" } }, 500);
  }
}
