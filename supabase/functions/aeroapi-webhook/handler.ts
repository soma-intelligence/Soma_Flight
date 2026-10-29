// POST /aeroapi-webhook?secret=<WEBHOOK_SECRET>: FlightAware AeroAPI alert deliveries.
//
// Flow: secret check (constant time, fails closed), size cap, raw body into webhook_inbox, then
// one SQL transaction (process_alert, migration 0004) that matches the delivery to a followed
// flight by fa_flight_id, decides everything against the locked flights row, writes flights and
// flight_events, records the delivery cost and marks the inbox row. Then push-sender per new event.
// Anything the provider cannot fix by retrying (bad JSON, unknown shape) answers 200 and keeps the
// inbox row with an error. Database failures answer 500 so the provider retries.
import type { SupabaseClient } from "npm:@supabase/supabase-js@2";
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

/** A delay event fires from this many minutes, then whenever it moves this far from the last one. */
export const DELAY_STEP_MIN = 15;

const TIME_KEYS = [
  "scheduled_out",
  "scheduled_in",
  "estimated_out",
  "estimated_in",
  "actual_out",
  "actual_off",
  "actual_on",
  "actual_in",
] as const;
/** payload key -> process_alert field name. */
const TEXT_KEYS: [string, string][] = [
  ["gate_origin", "gate_origin"],
  ["gate_destination", "gate_destination"],
  ["terminal_origin", "terminal_origin"],
  ["terminal_destination", "terminal_destination"],
  ["baggage_claim", "baggage_belt"],
  ["aircraft_type", "aircraft_type"],
  ["registration", "registration"],
  ["origin_icao", "origin_icao"],
  ["origin_iata", "origin_iata"],
  ["destination_icao", "destination_icao"],
  ["destination_iata", "destination_iata"],
];

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

/** The delivery's flight fields in the shape process_alert takes. Invalid values are left out. */
function normalise(f: Row): Row {
  const out: Row = {};
  for (const k of TIME_KEYS) {
    if (typeof f[k] === "string" && instant(f[k]) !== null) out[k] = f[k];
  }
  for (const [from, to] of TEXT_KEYS) {
    if (typeof f[from] === "string" && f[from] !== "") {
      out[to] = (f[from] as string).slice(0, 100);
    }
  }
  out.cancelled = f.cancelled === true;
  out.diverted = f.diverted === true;
  return out;
}

/** True when a decoded string or key holds a NUL, which jsonb cannot store. */
function hasNul(v: unknown): boolean {
  if (typeof v === "string") return v.includes("\u0000");
  if (Array.isArray(v)) return v.some(hasNul);
  if (v && typeof v === "object") {
    return Object.entries(v).some(([k, x]) => hasNul(k) || hasNul(x));
  }
  return false;
}

interface Outcome {
  duplicate: boolean;
  flight_id: string | null;
  events: { id: string; kind: EventKind }[];
}

function asOutcome(v: unknown): Outcome | null {
  const o = v as Outcome | null;
  if (!o || typeof o !== "object" || typeof o.duplicate !== "boolean") {
    return null;
  }
  if (!Array.isArray(o.events)) return null;
  if (o.events.some((e) => typeof e?.id !== "string")) return null;
  if (o.events.length > 0 && typeof o.flight_id !== "string") return null;
  return o;
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
      } else if (hasNul(parsed)) {
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

    const flight = alert.flight;
    const res = await db.rpc("process_alert", {
      p_inbox: inboxId,
      p_hash: eventId,
      p_fa_flight_id: flight.fa_flight_id,
      p_event_code: alert.event_code,
      p_alert_id: alert.alert_id,
      p_texts: {
        short_description: str(alert.short_description),
        summary: str(alert.summary),
      },
      p_fields: normalise(flight),
      p_day: now.toISOString().slice(0, 10),
      p_cost: ALERT_DELIVERY_COST,
      p_delay_step: DELAY_STEP_MIN,
    });
    if (res.error) throw new Step(`process_alert failed: ${res.error.message}`);
    const out = asOutcome(res.data);
    if (!out) throw new Step("process_alert returned an unexpected result");
    if (out.duplicate) return json({ ok: true, duplicate: true });

    // After the commit, so a crash before this point is reprocessed by the provider's retry.
    for (const ev of out.events) {
      try {
        await deps.push(out.flight_id as string, ev.id);
      } catch (e) {
        console.error(
          `push failed for event ${ev.id}`,
          e instanceof Error ? e.message : "unknown",
        );
      }
    }
    return json({ ok: true, events: out.events });
  } catch (e) {
    const msg = e instanceof Error ? e.message : "unknown error";
    console.error("aeroapi-webhook failed:", msg);
    if (inboxId !== null) await mark(db, inboxId, { error: msg });
    return json({ error: { code: "provider_unavailable" } }, 500);
  }
}
