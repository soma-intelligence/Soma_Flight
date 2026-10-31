// Polling refresh for followed flights when the status provider has no webhook (every provider but
// AeroAPI). pg_cron calls maintenance?mode=poll every 5 minutes; each run asks the provider about the
// followed flights that reached a poll point since their last poll, and feeds every change through
// process_alert, the webhook's own transaction, so events, gate history and pushes work as they do
// with AeroAPI alerts.
//
// Poll points sit around the best known departure D (estimated_out, else scheduled_out) and arrival
// A (estimated_in, else scheduled_in). The core four catch what users care most about: the gate and
// delay before boarding, the departure, the arrival estimate and the landing with its belt.
// docs/free-providers.md has the quota math (flights per day each tier supports).
import type { SupabaseClient } from "npm:@supabase/supabase-js@2";
import { ApiError } from "../errors.ts";
import { periodStart, type QuotaCharge, type QuotaRule } from "./quota.ts";
import type { FlightRef, ProviderFlight, StatusProvider } from "./types.ts";

export interface PollPoint {
  /** Lower ranks are polled first when the budget is short. */
  rank: number;
  side: "departure" | "arrival";
  /** Minutes from D (departure) or A (arrival); negative is before. */
  offsetMin: number;
  label: string;
}

/** The core ladder: four polls per flight. */
export const CORE_POINTS: readonly PollPoint[] = [
  { rank: 1, side: "departure", offsetMin: -120, label: "gate and delay" },
  { rank: 2, side: "departure", offsetMin: 15, label: "departed" },
  { rank: 3, side: "arrival", offsetMin: -30, label: "arrival estimate" },
  { rank: 4, side: "arrival", offsetMin: 20, label: "landed, belt" },
];

/** Four more for a paid tier: eight polls per flight. */
export const EXTENDED_POINTS: readonly PollPoint[] = [
  ...CORE_POINTS,
  {
    rank: 5,
    side: "departure",
    offsetMin: -360,
    label: "early schedule check",
  },
  { rank: 6, side: "departure", offsetMin: -45, label: "boarding gate" },
  { rank: 7, side: "arrival", offsetMin: -90, label: "mid flight estimate" },
  { rank: 8, side: "arrival", offsetMin: 60, label: "at the gate" },
];

/** A missed point is still polled this long after it passed (cron gaps); later it is skipped. */
export const CATCH_UP_MS = 30 * 60_000;

/** POLL_POINTS: "extended" for eight polls a flight, anything else the core four. */
export function ladder(
  env: (n: string) => string | undefined,
): readonly PollPoint[] {
  return env("POLL_POINTS") === "extended" ? EXTENDED_POINTS : CORE_POINTS;
}

export interface PlanFlight {
  scheduled_out: string | null;
  estimated_out: string | null;
  scheduled_in: string | null;
  estimated_in: string | null;
  status: string;
}

const FINAL = new Set(["arrived", "canceled", "diverted"]);

/** Each point of the ladder as an instant. A side with no known time has no points. */
export function pollTimes(
  f: PlanFlight,
  points: readonly PollPoint[],
): { point: PollPoint; at: number }[] {
  const dep = Date.parse(f.estimated_out ?? f.scheduled_out ?? "");
  const arr = Date.parse(f.estimated_in ?? f.scheduled_in ?? "");
  const out: { point: PollPoint; at: number }[] = [];
  for (const p of points) {
    const base = p.side === "departure" ? dep : arr;
    if (Number.isFinite(base)) {
      out.push({ point: p, at: base + p.offsetMin * 60_000 });
    }
  }
  return out.sort((a, b) => a.at - b.at);
}

/**
 * The point due now: the latest one at or before `now`, after the last poll, and no older than
 * CATCH_UP_MS. Null when nothing is due or the flight is finished.
 */
export function duePoint(
  f: PlanFlight,
  lastPolledAt: string | null,
  now: Date,
  points: readonly PollPoint[] = CORE_POINTS,
): { point: PollPoint; at: number } | null {
  if (FINAL.has(f.status)) return null;
  const last = lastPolledAt ? Date.parse(lastPolledAt) : -Infinity;
  const t = now.getTime();
  let due: { point: PollPoint; at: number } | null = null;
  for (const x of pollTimes(f, points)) {
    if (x.at <= t && x.at > last && t - x.at <= CATCH_UP_MS) due = x;
  }
  return due;
}

/**
 * Followed flights a quota supports per day: (allowance x poll share) / days in the period /
 * polls per flight. A daily allowance counts one day.
 */
export function flightsPerDay(
  rule: QuotaRule,
  share: number,
  pollsPerFlight: number,
  unitsPerPoll = 1,
): number {
  const days = rule.period === "day" ? 1 : 30;
  return (rule.limit * share) / days / (pollsPerFlight * unitsPerPoll);
}

/** The poller's daily pace for a monthly allowance: its share spread over 30 days (at least 1). */
export function dailyPace(rule: QuotaRule, share: number): number {
  const total = Math.floor(rule.limit * share);
  return rule.period === "day" ? total : Math.max(1, Math.floor(total / 30));
}

export interface Candidate extends PlanFlight {
  id: string;
  provider_id: string;
  ident: string;
  operator: string | null;
  origin_icao: string | null;
  origin_iata: string | null;
  destination_icao: string | null;
  destination_iata: string | null;
  actual_out: string | null;
  actual_off: string | null;
  actual_on: string | null;
  actual_in: string | null;
  gate_origin: string | null;
  gate_destination: string | null;
  terminal_origin: string | null;
  terminal_destination: string | null;
  baggage_belt: string | null;
  aircraft_type: string | null;
  registration: string | null;
  updated_at: string;
  last_polled_at: string | null;
}

const TIME_FIELDS = [
  "scheduled_out",
  "scheduled_in",
  "estimated_out",
  "estimated_in",
  "actual_out",
  "actual_off",
  "actual_on",
  "actual_in",
] as const;
const TEXT_FIELDS = [
  "gate_origin",
  "gate_destination",
  "terminal_origin",
  "terminal_destination",
  "baggage_belt",
  "aircraft_type",
  "registration",
  "origin_icao",
  "origin_iata",
  "destination_icao",
  "destination_iata",
] as const;
const RANK = ["scheduled", "departed", "en_route", "landed", "arrived"];

/** A provider answer in the field shape process_alert takes (as the webhook's `normalise`). */
export function alertFields(got: ProviderFlight): Record<string, unknown> {
  const out: Record<string, unknown> = {};
  for (const k of TIME_FIELDS) if (got[k]) out[k] = got[k];
  for (const k of TEXT_FIELDS) if (got[k]) out[k] = got[k];
  out.cancelled = got.status === "canceled";
  out.diverted = got.status === "diverted";
  if (got.status !== "unknown") out.status = got.status;
  return out;
}

/**
 * True when the answer could change the stored row: a field it gives differs, or the status moves
 * forward or to canceled or diverted. Unchanged answers are dropped before the database.
 */
export function changes(
  stored: Candidate,
  fields: Record<string, unknown>,
): boolean {
  for (const k of TIME_FIELDS) {
    const v = fields[k];
    if (typeof v !== "string") continue;
    const s = stored[k];
    if (!s || Date.parse(s) !== Date.parse(v)) return true;
  }
  for (const k of TEXT_FIELDS) {
    const v = fields[k];
    if (typeof v === "string" && v !== stored[k]) return true;
  }
  if (fields.cancelled === true || fields.diverted === true) return true;
  const to = RANK.indexOf(String(fields.status ?? ""));
  return to > RANK.indexOf(stored.status);
}

async function sha256Hex(s: string): Promise<string> {
  const d = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
  return [...new Uint8Array(d)].map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

export interface PollDeps {
  db: SupabaseClient;
  status: StatusProvider;
  /** The poller's daily pace counter (provider '<name>.poll'). */
  pace: QuotaCharge;
  /** Notifies followers of a stored event, as the webhook does. */
  push: (flightId: string, eventId: string) => Promise<void>;
  now?: () => Date;
  points?: readonly PollPoint[];
  /** Candidates read per run. */
  limit?: number;
}

export interface PollResult {
  checked: number;
  due: number;
  polled: number;
  changed: number;
  events: number;
  failed: number;
  /** Why the run stopped early: a quota, or null. */
  stoppedBy: string | null;
}

/** The pace counter for a provider, on provider_quota under '<name>.poll' (daily). */
export function paceCounter(
  db: SupabaseClient,
  provider: string,
  rule: QuotaRule,
  share: number,
  now: () => Date = () => new Date(),
): QuotaCharge {
  const limit = dailyPace(rule, share);
  return async (units) => {
    const { data, error } = await db.rpc("charge_provider_quota", {
      p_provider: `${provider}.poll`,
      p_period: periodStart("day", now()),
      p_units: units,
      p_limit: limit,
    });
    if (error) {
      throw new ApiError(
        "provider_unavailable",
        503,
        `Pace counter unavailable: ${error.message}`,
      );
    }
    if (data !== true) {
      throw new ApiError(
        "provider_unavailable",
        503,
        "Daily polling pace reached",
      );
    }
  };
}

const isQuota = (e: unknown) =>
  e instanceof ApiError && e.status === 503 &&
  /quota|pace|counter/i.test(e.message);

/** One polling run. Never throws for one flight; stops at the first quota refusal. */
export async function runPoll(deps: PollDeps): Promise<PollResult> {
  const { db } = deps;
  const now = (deps.now ?? (() => new Date()))();
  const points = deps.points ?? CORE_POINTS;
  const r: PollResult = {
    checked: 0,
    due: 0,
    polled: 0,
    changed: 0,
    events: 0,
    failed: 0,
    stoppedBy: null,
  };
  const got = await db.rpc("poll_candidates", { p_limit: deps.limit ?? 500 });
  if (got.error) {
    throw new Error(`poll_candidates failed: ${got.error.message}`);
  }
  const list = (got.data ?? []) as Candidate[];
  r.checked = list.length;
  const due = list
    .map((f) => ({ f, d: duePoint(f, f.last_polled_at, now, points) }))
    .filter((x) => x.d !== null)
    .sort((a, b) => a.d!.point.rank - b.d!.point.rank || a.d!.at - b.d!.at);
  r.due = due.length;

  for (const { f } of due) {
    try {
      await deps.pace(1);
    } catch (e) {
      r.stoppedBy = e instanceof ApiError ? e.message : "pace counter failed";
      break;
    }
    // Marked before the call: a failure waits for the next point instead of retrying every 5 min.
    const mark = await db.from("provider_polls").upsert({
      flight_id: f.id,
      last_polled_at: now.toISOString(),
      provider: deps.status.name,
    }, { onConflict: "flight_id" });
    if (mark.error) {
      throw new Error(`provider_polls write failed: ${mark.error.message}`);
    }
    const ref: FlightRef = {
      provider_id: f.provider_id,
      ident: f.ident,
      operator: f.operator,
      origin_icao: f.origin_icao,
      origin_iata: f.origin_iata,
      destination_icao: f.destination_icao,
      scheduled_out: f.scheduled_out,
    };
    let answer: ProviderFlight | null;
    try {
      answer = await deps.status.flightStatus(ref);
    } catch (e) {
      if (isQuota(e)) {
        r.stoppedBy = (e as ApiError).message;
        break;
      }
      r.failed++;
      console.error(
        `poll failed for flight ${f.id}`,
        e instanceof ApiError ? e.code : (e as Error).message,
      );
      continue;
    }
    r.polled++;
    if (!answer) continue;
    const fields = alertFields(answer);
    if (!changes(f, fields)) continue;
    r.changed++;
    try {
      r.events += await apply(deps, f, fields, deps.status.name, now);
    } catch (e) {
      r.failed++;
      console.error(
        `poll apply failed for flight ${f.id}`,
        (e as Error).message,
      );
    }
  }
  return r;
}

/**
 * Feeds one polled change through webhook_inbox and process_alert (event code 'change', no
 * provider cost: the request was counted on the quota). The body hash includes the stored row's
 * updated_at, so the same answer after a real change is not mistaken for a duplicate.
 */
async function apply(
  deps: PollDeps,
  f: Candidate,
  fields: Record<string, unknown>,
  provider: string,
  now: Date,
): Promise<number> {
  const { db } = deps;
  const body = { source: "poll", provider, flight_id: f.id, fields };
  const hash = await sha256Hex(
    JSON.stringify({ ...body, stored: f.updated_at }),
  );
  const ins = await db.from("webhook_inbox").insert({ body, body_sha256: hash })
    .select("id").single();
  if (ins.error) throw new Error(`inbox insert failed: ${ins.error.message}`);
  const res = await db.rpc("process_alert", {
    p_inbox: ins.data.id,
    p_hash: hash,
    p_fa_flight_id: f.provider_id,
    p_event_code: "change",
    p_alert_id: null,
    p_texts: { short_description: null, summary: `Polled from ${provider}` },
    p_fields: fields,
    p_day: now.toISOString().slice(0, 10),
    p_cost: 0,
    p_delay_step: 15, // the webhook's DELAY_STEP_MIN
  });
  if (res.error) {
    await db.from("webhook_inbox").update({ error: res.error.message }).eq(
      "id",
      ins.data.id,
    );
    throw new Error(`process_alert failed: ${res.error.message}`);
  }
  const out = res.data as {
    flight_id: string | null;
    events: { id: string }[];
  };
  for (const ev of out.events ?? []) {
    try {
      await deps.push(out.flight_id as string, ev.id);
    } catch (e) {
      console.error(`push failed for event ${ev.id}`, (e as Error).message);
    }
  }
  return (out.events ?? []).length;
}
