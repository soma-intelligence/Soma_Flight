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
  timeChanged: boolean;
}

/** What the delivery changes on the stored flight. Null payload values never wipe stored ones. */
function plan(alert: Alert, stored: Row, now: Date): Plan {
  const f = alert.flight;
  const update: Row = {};
  const changes: Plan["changes"] = {};
  let placeChanged = false;
  let timeChanged = false;

  const note = (col: string, to: unknown) => {
    update[col] = to;
    changes[col] = { from: stored[col] ?? null, to };
  };
  for (const col of TIME_COLS) {
    const to = f[col];
    if (typeof to !== "string" || instant(to) === null) continue;
    if (instant(to) !== instant(stored[col])) {
      note(col, to);
      if (col.startsWith("estimated")) timeChanged = true;
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

  // Status from the merged actual times plus the cancelled/diverted flags. "unknown" keeps the old one.
  const merged = (col: (typeof TIME_COLS)[number]) =>
    (update[col] ?? stored[col] ?? null) as string | null;
  const probe = toFlightRow({
    fa_flight_id: f.fa_flight_id,
    ident: str(f.ident) ?? "",
    cancelled: alert.event_code === "cancelled" || f.cancelled === true,
    diverted: alert.event_code === "diverted" || f.diverted === true,
    actual_out: merged("actual_out"),
    actual_off: merged("actual_off"),
    actual_on: merged("actual_on"),
    actual_in: merged("actual_in"),
    status: "",
  } as unknown as AeroFlight, now);
  if (probe.status !== "unknown" && probe.status !== stored.status) {
    note("status", probe.status);
  }
  if (Object.keys(update).length > 0) update.updated_at = now.toISOString();
  return { update, changes, placeChanged, timeChanged };
}

function kindFor(alert: Alert, p: Plan): EventKind | null {
  const fixed = FIXED_KIND[alert.event_code];
  if (fixed) return fixed;
  if (!DIFF_CODES.has(alert.event_code)) return null;
  if (p.placeChanged) return "gate_change";
  if (p.timeChanged) return "delay";
  return null;
}

async function mark(
  db: SupabaseClient,
  inboxId: number,
  patch: { processed_at?: string; error?: string },
): Promise<void> {
  const { error } = await db.from("webhook_inbox").update(patch).eq(
    "id",
    inboxId,
  );
  if (error) console.error(`inbox ${inboxId} not marked: ${error.message}`);
}

async function recordCost(db: SupabaseClient, now: Date): Promise<void> {
  const { error } = await db.rpc("increment_usage", {
    p_day: now.toISOString().slice(0, 10),
    p_endpoint: ALERT_USAGE_ENDPOINT,
    p_cost: ALERT_DELIVERY_COST,
  });
  // The delivery itself succeeded: a counter failure is logged, never retried (it would double count).
  if (error) console.error(`increment_usage failed: ${error.message}`);
}

export async function handler(req: Request, deps: Deps): Promise<Response> {
  const { db } = deps;
  const now = (deps.now ?? (() => new Date()))();
  let inboxId: number | null = null;
  try {
    if (req.method !== "POST") {
      return json({ error: { code: "invalid_request" } }, 405);
    }
    const expected = deps.secret();
    const given = new URL(req.url).searchParams.get("secret") ?? "";
    // Compare even when the secret is missing so timing does not reveal the misconfiguration.
    const ok = await secretMatches(given, expected ?? "");
    if (!expected || !ok) {
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
    } catch {
      malformed = "malformed body: not valid JSON";
    }

    const ins = await db.from("webhook_inbox").insert({
      body: malformed ? { _unparsed: text } : parsed,
      body_sha256: eventId,
      ...(malformed ? { error: malformed } : {}),
    }).select("id").single();
    if (ins.error) throw new Step(`inbox insert failed: ${ins.error.message}`);
    inboxId = ins.data.id as number;
    if (malformed) return json({ ok: true, ignored: "malformed" });

    // Same raw body already handled: the provider retried or replayed. Bill and notify once.
    const prior = await db.from("webhook_inbox").select("id").eq(
      "body_sha256",
      eventId,
    ).not("processed_at", "is", null).neq("id", inboxId).limit(1);
    if (prior.error) {
      throw new Step(`inbox read failed: ${prior.error.message}`);
    }
    if ((prior.data ?? []).length > 0) {
      await mark(db, inboxId, {
        processed_at: now.toISOString(),
        error: "note: duplicate delivery",
      });
      return json({ ok: true, duplicate: true });
    }

    const alert = asAlert(parsed);
    if (!alert) {
      await mark(db, inboxId, { error: "invalid alert shape" });
      return json({ ok: true, ignored: "invalid_shape" });
    }

    // Every well-formed delivery is billed by the provider, followed flight or not.
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
    if (!stored || !followed) {
      await recordCost(db, now);
      await mark(db, inboxId, {
        processed_at: now.toISOString(),
        error: "note: no followed flight for this fa_flight_id",
      });
      return json({ ok: true, ignored: "not_followed" });
    }

    const p = plan(alert, stored, now);
    const kind = kindFor(alert, p);
    if (!kind) {
      if (Object.keys(p.update).length > 0) {
        const u = await db.from("flights").update(p.update).eq(
          "id",
          stored.id as string,
        );
        if (u.error) throw new Step(`flight update failed: ${u.error.message}`);
      }
      await recordCost(db, now);
      await mark(db, inboxId, {
        processed_at: now.toISOString(),
        error: `note: ${alert.event_code} produced no event`,
      });
      return json({ ok: true, event: null });
    }

    // Claim the event first: a duplicate delivery inserts nothing and must not touch the flight
    // again (an old replay could overwrite newer data) nor bill again.
    const claim = await db.from("flight_events").upsert({
      flight_id: stored.id,
      provider_event_id: eventId,
      kind,
      payload: {
        event_code: alert.event_code,
        alert_id: alert.alert_id,
        short_description: str(alert.short_description),
        summary: str(alert.summary),
        changes: p.changes,
      },
    }, { onConflict: "provider_event_id", ignoreDuplicates: true })
      .select("id");
    if (claim.error) {
      throw new Step(`event insert failed: ${claim.error.message}`);
    }
    const newEventId = claim.data?.[0]?.id as string | undefined;
    if (!newEventId) {
      await mark(db, inboxId, {
        processed_at: now.toISOString(),
        error: "note: duplicate delivery",
      });
      return json({ ok: true, duplicate: true });
    }

    if (Object.keys(p.update).length > 0) {
      const u = await db.from("flights").update(p.update).eq(
        "id",
        stored.id as string,
      );
      if (u.error) {
        // Undo the claim so the provider's retry is processed instead of treated as a duplicate.
        await db.from("flight_events").delete().eq("id", newEventId);
        throw new Step(`flight update failed: ${u.error.message}`);
      }
    }
    await recordCost(db, now);
    await mark(db, inboxId, { processed_at: now.toISOString() });

    try {
      await deps.push(stored.id as string, newEventId);
    } catch (e) {
      console.error(
        `push failed for event ${newEventId}`,
        e instanceof Error ? e.message : "unknown",
      );
    }
    return json({ ok: true, event: newEventId, kind });
  } catch (e) {
    const msg = e instanceof Error ? e.message : "unknown error";
    console.error("aeroapi-webhook failed:", msg);
    if (inboxId !== null) await mark(db, inboxId, { error: msg });
    return json({ error: { code: "provider_unavailable" } }, 500);
  }
}
