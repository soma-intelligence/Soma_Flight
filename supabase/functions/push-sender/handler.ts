// POST /push-sender { flightId, eventId }: APNs alerts and Live Activity updates for one event.
// POST /push-sender { flightId, program }: one airport program alert (faa-status's sweep), the same
// claim in alert_log and the same delivery, with no event and no Live Activity update.
// Service role only. The gateway checks the JWT signature (verify_jwt); this checks its role claim.
import type { SupabaseClient } from "npm:@supabase/supabase-js@2";
import { ApiError, errorResponse, json } from "../_shared/errors.ts";
import { isServiceCaller } from "../_shared/auth.ts";
import {
  apnsJwt,
  type ApnsResult,
  evictApnsJwt,
  type FlightEventKind,
  isBadDeviceToken,
  isDeadToken,
  isProviderTokenRejected,
  mapLimit,
  sendApns,
} from "../_shared/apns.ts";
import {
  type Alert,
  type AlertCategory,
  type AlertFlight,
  type AlertHistory,
  detectAlerts,
  IMMEDIATE_ALERTS,
  inboundLate,
} from "../_shared/alerts.ts";
import { alertText, type CopyContext } from "../_shared/alert_copy.ts";
import {
  cachesFrom,
  predictedDelay,
  type PredictionCaches,
} from "../_shared/prediction.ts";
import { connectionAlert } from "../_shared/connections.ts";
import { connectionsOf } from "./connections.ts";
import { readProgramAlert } from "../_shared/faa_nas.ts";
import { smsHook, type SmsHookDeps } from "../_shared/sms_alerts.ts";

export const SEND_CONCURRENCY = 10;
/**
 * Live Activity pushes at priority 10 are budgeted by Apple; routine updates go at 5. An `update`
 * event goes at 10 when one of its alerts is in IMMEDIATE_ALERTS (take-off, gate, cancel...).
 */
const IMMEDIATE_KINDS = new Set([
  "gate_change",
  "departure",
  "arrival",
  "cancel",
  "diversion",
]);
/** Flights whose inbound leg is the one an event is about, checked per call. */
const MAX_DEPENDENTS = 20;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const PAGE = 1000;

export interface ApnsConfig {
  teamId: string;
  keyId: string;
  p8: string;
  bundleId: string;
  sandbox: boolean;
}

export interface Deps {
  db: SupabaseClient;
  /** Reads the APNS_* secrets at request time. Undefined when any is missing. */
  config: () => ApnsConfig | undefined;
  fetchFn?: typeof fetch;
  now?: () => Date;
  /** The project's service role key, compared with the bearer token. Defaults to the env. */
  serviceKey?: () => string | undefined;
  /** What the predicted delay alert reads (`cachesFrom(db)` when unset). */
  caches?: PredictionCaches;
  /**
   * Alerts by text (`_shared/sms_alerts.ts`), off: index.ts passes none and the SMS_ALERTS_ENABLED flag
   * is unset, so the hook returns before reading a row.
   */
  sms?: SmsHookDeps;
}

export function configFromEnv(): ApnsConfig | undefined {
  const g = (n: string) => Deno.env.get(n) || undefined;
  const teamId = g("APNS_TEAM_ID"),
    keyId = g("APNS_KEY_ID"),
    p8 = g("APNS_P8"),
    bundleId = g("APNS_BUNDLE_ID");
  if (!teamId || !keyId || !p8 || !bundleId) return undefined;
  // Secrets set through dashboards often carry literal \n for the key's line breaks.
  return {
    teamId,
    keyId,
    p8: p8.includes("\\n") ? p8.replace(/\\n/g, "\n") : p8,
    bundleId,
    sandbox: g("APNS_SANDBOX") === "true",
  };
}

type Row = Record<string, unknown>;

type Flight = AlertFlight & {
  id: string;
  provider_id: string;
  [k: string]: unknown;
};

async function pagedUsers(
  db: SupabaseClient,
  flightId: string,
  onlyNotify: boolean,
): Promise<Set<string>> {
  const out = new Set<string>();
  for (let from = 0;; from += PAGE) {
    let q = db.from("user_flights").select("user_id").eq("flight_id", flightId);
    if (onlyNotify) q = q.eq("notify", true);
    const { data, error } = await q.order("user_id").range(
      from,
      from + PAGE - 1,
    );
    if (error) throw new Error(`followers read failed: ${error.message}`);
    for (const r of data) out.add(r.user_id as string);
    if (data.length < PAGE) return out;
  }
}

interface TokenRow {
  user_id: string;
  token: string;
  updated_at: string;
  bad_count: number;
}

async function tokensFor(
  db: SupabaseClient,
  kind: "alert" | "live_activity",
  users: Set<string>,
  flightId?: string,
): Promise<TokenRow[]> {
  const ids = [...users];
  const tokens: TokenRow[] = [];
  for (let i = 0; i < ids.length; i += 200) {
    let q = db.from("push_tokens").select(
      "user_id, token, updated_at, bad_count",
    ).eq(
      "kind",
      kind,
    )
      .in("user_id", ids.slice(i, i + 200));
    if (flightId) q = q.eq("flight_id", flightId);
    const { data, error } = await q;
    if (error) throw new Error(`tokens read failed: ${error.message}`);
    for (const r of data) tokens.push(r as TokenRow);
  }
  return [...new Map(tokens.map((t) => [t.token, t])).values()];
}

function progressOf(f: Row, now: number): number {
  if (f.status === "arrived" || f.status === "landed") return 1;
  if (f.status === "scheduled" || f.status === "unknown") return 0;
  const t = (
    k: string,
  ) => (typeof f[k] === "string" ? Date.parse(f[k] as string) : NaN);
  const out = [t("actual_out"), t("estimated_out"), t("scheduled_out")].find(
    Number.isFinite,
  );
  const inn = [
    t("actual_in"),
    t("actual_on"),
    t("estimated_in"),
    t("scheduled_in"),
  ]
    .find(Number.isFinite);
  if (out === undefined || inn === undefined || inn <= out) return 0;
  return Math.min(1, Math.max(0, (now - out) / (inn - out)));
}

function contentState(f: Row, now: number) {
  return {
    status: f.status,
    gateOrigin: f.gate_origin ?? null,
    gateDestination: f.gate_destination ?? null,
    estimatedOut: f.estimated_out ?? f.scheduled_out ?? null,
    estimatedIn: f.estimated_in ?? f.scheduled_in ?? null,
    progress: Math.round(progressOf(f, now) * 1000) / 1000,
  };
}

async function tz(db: SupabaseClient, icao: unknown): Promise<string | null> {
  if (typeof icao !== "string") return null;
  const { data } = await db.from("airports").select("tz").eq("icao", icao)
    .maybeSingle();
  return (data?.tz as string | null) ?? null;
}

interface Tally {
  sent: number;
  failed: number;
  removed: number;
}

interface FanOutOpts {
  /** Delete the row after a good send (a Live Activity that ended). */
  deleteOnSuccess?: boolean;
  /** Called when APNs refuses the provider token, so the cache can drop it. */
  onProviderRejected?: () => void;
}

/**
 * Sends to every token, a few at a time. 410 and Unregistered delete the row. BadDeviceToken is a
 * strike: the second one deletes, unless every token of the batch got it, which points at a wrong
 * APNS_SANDBOX and changes nothing. Rows are only touched while their updated_at is the one read,
 * so a token re-registered meanwhile survives. Logs carry status and reason, never tokens.
 */
async function fanOut(
  db: SupabaseClient,
  label: string,
  kind: "alert" | "live_activity",
  tokens: TokenRow[],
  send: (token: string) => Promise<ApnsResult>,
  opts: FanOutOpts = {},
): Promise<Tally> {
  const tally: Tally = { sent: 0, failed: 0, removed: 0 };
  const bad: TokenRow[] = [];
  let rejected = false;
  const remove = async (t: TokenRow) => {
    const del = await db.from("push_tokens").delete().eq("token", t.token)
      .eq("kind", kind).eq("updated_at", t.updated_at);
    if (del.error) {
      console.error(`${label}: token delete failed: ${del.error.message}`);
    } else tally.removed++;
  };
  await mapLimit(tokens, SEND_CONCURRENCY, async (t) => {
    if (rejected) {
      tally.failed++;
      return;
    }
    let r: ApnsResult;
    try {
      r = await send(t.token);
    } catch {
      r = { ok: false, status: 0, reason: "send_error" };
    }
    if (r.ok) {
      tally.sent++;
      if (opts.deleteOnSuccess) await remove(t);
      else if (t.bad_count > 0) {
        await db.from("push_tokens").update({ bad_count: 0 }).eq(
          "token",
          t.token,
        )
          .eq("kind", kind).eq("updated_at", t.updated_at);
      }
      return;
    }
    tally.failed++;
    if (isProviderTokenRejected(r)) {
      rejected = true;
      opts.onProviderRejected?.();
      console.error(
        `${label}: apns rejected the provider token reason=${r.reason}, batch stopped`,
      );
    } else if (isDeadToken(r)) {
      await remove(t);
    } else if (isBadDeviceToken(r)) {
      bad.push(t);
    } else {
      console.error(
        `${label}: apns failure status=${r.status} reason=${
          r.reason ?? "none"
        }`,
      );
    }
  });
  if (bad.length > 0) {
    if (tokens.length >= 2 && bad.length === tokens.length) {
      console.error(
        `${label}: BadDeviceToken for all ${tokens.length} tokens, likely APNS_SANDBOX mismatch, nothing deleted`,
      );
    } else {
      console.error(`${label}: BadDeviceToken for ${bad.length} token(s)`);
      for (const t of bad) {
        if (t.bad_count >= 1) await remove(t);
        else {
          await db.from("push_tokens").update({ bad_count: t.bad_count + 1 })
            .eq("token", t.token).eq("kind", kind).eq(
              "updated_at",
              t.updated_at,
            );
        }
      }
    }
  }
  return tally;
}

interface SendCtx {
  db: SupabaseClient;
  cfg: ApnsConfig;
  jwt: string;
  fetchFn: typeof fetch;
  evict: () => void;
  expiration: number;
  /** The event that triggered the call, carried in every alert's payload; null for a program alert. */
  eventId: string | null;
  /** The text message hook's deps; undefined sends nothing. */
  sms?: SmsHookDeps;
}

/** The keys already sent for a flight and the newest delay sent per side (alert_log). */
export async function historyOf(
  db: SupabaseClient,
  flightId: string,
): Promise<AlertHistory> {
  const { data, error } = await db.from("alert_log").select(
    "key, kind, minutes",
  ).eq("flight_id", flightId).order("sent_at", { ascending: false });
  if (error) throw new Error(`alert log read failed: ${error.message}`);
  const h: AlertHistory = {
    keys: new Set(),
    lastDelay: { departure: null, arrival: null },
  };
  for (const r of data ?? []) {
    h.keys.add(r.key as string);
    const side = r.kind === "departure_delay"
      ? "departure"
      : r.kind === "arrival_delay"
      ? "arrival"
      : null;
    if (side && h.lastDelay[side] === null && typeof r.minutes === "number") {
      h.lastDelay[side] = r.minutes;
    }
  }
  return h;
}

/** The inbound leg's row when this flight names one and flights has it. Never fetched from the provider. */
async function inboundOf(
  db: SupabaseClient,
  flight: Flight,
): Promise<Flight | null> {
  const id = flight.inbound_provider_id;
  if (typeof id !== "string" || id === "") return null;
  const { data, error } = await db.from("flights").select("*").eq(
    "provider_id",
    id,
  ).maybeSingle();
  if (error) {
    console.error(`inbound read failed: ${error.message}`);
    return null;
  }
  return (data as Flight | null) ?? null;
}

/**
 * Claims alerts in alert_log (its key is unique per flight, so one already sent is dropped) and
 * returns the ones this call won. The claim comes before the send: a crash in between loses that
 * alert rather than sending it twice.
 */
export async function claim(
  db: SupabaseClient,
  flightId: string,
  alerts: Alert[],
): Promise<Alert[]> {
  if (alerts.length === 0) return [];
  const { data, error } = await db.from("alert_log").upsert(
    alerts.map((a) => ({
      flight_id: flightId,
      key: a.key,
      kind: a.kind,
      minutes: a.minutes ?? null,
    })),
    { onConflict: "flight_id,key", ignoreDuplicates: true },
  ).select("key");
  if (error) throw new Error(`alert claim failed: ${error.message}`);
  const won = new Set((data ?? []).map((r) => r.key as string));
  return alerts.filter((a) => won.has(a.key));
}

const CATEGORIES: AlertCategory[] = [
  "delays",
  "gates",
  "takeoff_landing",
  "baggage",
  "cancellations",
  "reminders",
];

/** For each category, the users who turned it off. A user with no row has everything on. */
export async function mutedBy(
  db: SupabaseClient,
  users: Set<string>,
): Promise<Map<AlertCategory, Set<string>>> {
  const out = new Map<AlertCategory, Set<string>>(
    CATEGORIES.map((c) => [c, new Set<string>()]),
  );
  const ids = [...users];
  for (let i = 0; i < ids.length; i += 200) {
    const { data, error } = await db.from("notification_preferences")
      .select(`user_id, ${CATEGORIES.join(", ")}`)
      .in("user_id", ids.slice(i, i + 200));
    if (error) throw new Error(`preferences read failed: ${error.message}`);
    for (const r of (data ?? []) as unknown as Record<string, unknown>[]) {
      for (const c of CATEGORIES) {
        if (r[c] === false) out.get(c)!.add(r.user_id as string);
      }
    }
  }
  return out;
}

type Sent = Tally & { kinds: string[] };

/** Who else an alert concerns: a connection's users and its onward flight. */
interface DeliverOpts {
  /** Only these users (among the flight's followers with notify on). */
  only?: Set<string>;
  /** The onward flight of a connection alert, for its words. */
  onward?: Flight;
}

/** Claims `alerts` for `flight` and sends each one to the followers who want its category. */
async function deliver(
  ctx: SendCtx,
  flight: Flight,
  alerts: Alert[],
  inbound: Flight | null,
  opts: DeliverOpts = {},
): Promise<Sent> {
  const tally: Sent = { sent: 0, failed: 0, removed: 0, kinds: [] };
  const won = await claim(ctx.db, flight.id, alerts);
  if (won.length === 0) return tally;
  const users = await pagedUsers(ctx.db, flight.id, true);
  if (opts.only) {
    for (const u of [...users]) if (!opts.only.has(u)) users.delete(u);
  }
  if (users.size === 0) return tally;
  const [tokens, muted, originTz, destinationTz] = await Promise.all([
    tokensFor(ctx.db, "alert", users),
    mutedBy(ctx.db, users),
    tz(ctx.db, flight.origin_icao),
    tz(ctx.db, flight.destination_icao),
  ]);
  const copyCtx: CopyContext = {
    originTz,
    destinationTz,
    inbound,
    onward: opts.onward,
  };
  for (const a of won) {
    const off = muted.get(a.category)!;
    const text = alertText(a, flight, copyCtx);
    // Texts (off today): the same alert, to followers who verified a number and turned texts on.
    await smsHook(ctx.sms, a, text, users, muted);
    const to = tokens.filter((t) => !off.has(t.user_id));
    if (to.length === 0) continue;
    const body = {
      aps: {
        alert: text,
        sound: "default",
        "thread-id": flight.id,
      },
      flightId: flight.id,
      eventId: ctx.eventId,
      kind: a.kind,
    };
    // Unique per alert of the event, under APNs' 64 bytes.
    const collapseId = `${ctx.eventId ?? flight.id}:${a.kind}${
      a.side ? `:${a.side[0]}` : ""
    }`;
    const t = await fanOut(
      ctx.db,
      "alert",
      "alert",
      to,
      (tok) =>
        sendApns(tok, body, {
          pushType: "alert",
          topic: ctx.cfg.bundleId,
          sandbox: ctx.cfg.sandbox,
          jwt: ctx.jwt,
          priority: 10,
          expiration: ctx.expiration,
          collapseId,
        }, ctx.fetchFn),
      { onProviderRejected: ctx.evict },
    );
    tally.sent += t.sent;
    tally.failed += t.failed;
    tally.removed += t.removed;
    tally.kinds.push(a.kind);
  }
  return tally;
}

export async function handler(req: Request, deps: Deps): Promise<Response> {
  try {
    if (req.method !== "POST") {
      throw new ApiError("invalid_request", 405, "Use POST");
    }
    const key = (deps.serviceKey ?? (() =>
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")))();
    if (!(await isServiceCaller(req, key))) {
      throw new ApiError("unauthorized", 401, "Service role only");
    }
    let body: { flightId?: unknown; eventId?: unknown; program?: unknown };
    try {
      body = await req.json();
    } catch {
      throw new ApiError("invalid_request", 400, "Invalid JSON");
    }
    const { flightId, eventId } = body;
    if (body.program !== undefined) {
      return await sendProgram(deps, flightId, body.program);
    }
    if (
      typeof flightId !== "string" || !UUID.test(flightId) ||
      typeof eventId !== "string" || !UUID.test(eventId)
    ) {
      throw new ApiError(
        "invalid_request",
        400,
        "flightId and eventId must be UUIDs",
      );
    }
    const cfg = deps.config();
    if (!cfg) {
      console.error("push-sender: APNS secrets are not set");
      throw new ApiError("provider_unavailable", 503, "APNs is not configured");
    }
    const { db } = deps;
    const [ev, fl] = await Promise.all([
      db.from("flight_events").select(
        "id, flight_id, kind, payload, provider_event_id",
      )
        .eq("id", eventId).maybeSingle(),
      db.from("flights").select("*").eq("id", flightId).maybeSingle(),
    ]);
    if (ev.error) throw new Error(`event read failed: ${ev.error.message}`);
    if (fl.error) throw new Error(`flight read failed: ${fl.error.message}`);
    if (!ev.data || !fl.data || ev.data.flight_id !== flightId) {
      throw new ApiError("not_found", 404, "Event not found for this flight");
    }
    const kind = ev.data.kind as FlightEventKind;
    const payload = (ev.data.payload ?? {}) as Record<string, unknown>;
    const flight = fl.data as Flight;

    const nowDate = (deps.now ?? (() => new Date()))();
    const nowS = Math.floor(nowDate.getTime() / 1000);
    const jwt = await apnsJwt(cfg.teamId, cfg.keyId, cfg.p8, nowS);
    const fetchFn = deps.fetchFn ?? fetch;
    const evict = () => evictApnsJwt(cfg.teamId, cfg.keyId, cfg.p8);
    const hour = nowS + 3600;

    // Alerts: what this event is worth, each claimed once in alert_log, sent to the followers who
    // want notifications and have not turned the alert's category off.
    const send: SendCtx = {
      db,
      cfg,
      jwt,
      fetchFn,
      evict,
      expiration: hour,
      eventId,
      sms: deps.sms,
    };
    const history = await historyOf(db, flightId);
    const detected = detectAlerts(
      {
        id: eventId,
        kind,
        payload,
        providerEventId: ev.data.provider_event_id as string | null,
      },
      flight,
      history,
    );
    const inbound = await inboundOf(db, flight);
    const late = inboundLate(flight, inbound, history);
    if (late) detected.push(late);
    const caches = deps.caches ?? cachesFrom(db);
    const predicted = await predictedDelay(
      flight,
      inbound,
      history,
      detected,
      caches,
      nowDate,
    );
    if (predicted) detected.push(predicted);
    const alertTally = await deliver(send, flight, detected, inbound);

    // Flights this one brings the aircraft for: their inbound late and predicted delay alerts, to
    // their own followers.
    const dependents = await db.from("flights").select("*")
      .eq("inbound_provider_id", flight.provider_id).limit(MAX_DEPENDENTS);
    if (dependents.error) {
      console.error(`dependents read failed: ${dependents.error.message}`);
    }
    for (const d of (dependents.data ?? []) as Flight[]) {
      const h = await historyOf(db, d.id);
      const found: Alert[] = [];
      const a = inboundLate(d, flight, h);
      if (a) found.push(a);
      const p = await predictedDelay(d, flight, h, found, caches, nowDate);
      if (p) found.push(p);
      if (found.length === 0) continue;
      const t = await deliver(send, d, found, flight);
      alertTally.sent += t.sent;
      alertTally.failed += t.failed;
      alertTally.removed += t.removed;
      alertTally.kinds.push(...t.kinds);
    }

    // Connections: this flight and the followed flights it connects with. When the layover falls under
    // the airport's usual minimum, the users who follow both hear it once, on the arriving flight.
    try {
      for (const c of await connectionsOf(db, flight)) {
        const a = connectionAlert(
          c.departing,
          c.assessment,
          (await historyOf(db, c.arriving.id)).keys,
        );
        if (!a) continue;
        const t = await deliver(send, c.arriving, [a], null, {
          only: c.users,
          onward: c.departing,
        });
        alertTally.sent += t.sent;
        alertTally.failed += t.failed;
        alertTally.removed += t.removed;
        alertTally.kinds.push(...t.kinds);
      }
    } catch (e) {
      // A connection check that fails must not stop the Live Activity update below.
      console.error("connection alerts failed", (e as Error).message);
    }

    // Live Activities: tokens for this flight whose user still follows it (notify is not consulted).
    const ends = flight.status === "arrived" || flight.status === "canceled" ||
      kind === "arrival" || kind === "cancel";
    const followers = await pagedUsers(db, flightId, false);
    const laTokens = await tokensFor(db, "live_activity", followers, flightId);
    const laPayload = {
      aps: {
        timestamp: nowS,
        event: ends ? "end" : "update",
        "content-state": contentState(flight, nowDate.getTime()),
        ...(ends
          ? {
            "dismissal-date": nowS +
              (kind === "cancel" || flight.status === "canceled" ? 3600 : 1800),
          }
          : {}),
      },
    };
    const immediate = IMMEDIATE_KINDS.has(kind) ||
      (kind === "update" && detected.some((a) => IMMEDIATE_ALERTS.has(a.kind)));
    const laTally = await fanOut(
      db,
      "live_activity",
      "live_activity",
      laTokens,
      (t) =>
        sendApns(t, laPayload, {
          pushType: "liveactivity",
          topic: `${cfg.bundleId}.push-type.liveactivity`,
          sandbox: cfg.sandbox,
          jwt,
          priority: immediate ? 10 : 5,
          expiration: hour,
        }, fetchFn),
      { deleteOnSuccess: ends, onProviderRejected: evict },
    );

    const { kinds, ...alerts } = alertTally;
    return json({ ok: true, alerts, kinds, liveActivities: laTally });
  } catch (e) {
    return errorResponse(e);
  }
}

/** The program alert path: claim it for the flight and send it to the followers who want delays. */
async function sendProgram(
  deps: Deps,
  flightId: unknown,
  raw: unknown,
): Promise<Response> {
  const program = readProgramAlert(raw);
  if (typeof flightId !== "string" || !UUID.test(flightId) || !program) {
    throw new ApiError(
      "invalid_request",
      400,
      "flightId must be a UUID and program a program alert",
    );
  }
  const cfg = deps.config();
  if (!cfg) {
    console.error("push-sender: APNS secrets are not set");
    throw new ApiError("provider_unavailable", 503, "APNs is not configured");
  }
  const { db } = deps;
  const fl = await db.from("flights").select("*").eq("id", flightId)
    .maybeSingle();
  if (fl.error) throw new Error(`flight read failed: ${fl.error.message}`);
  if (!fl.data) throw new ApiError("not_found", 404, "Flight not found");
  const nowS = Math.floor(
    (deps.now ?? (() => new Date()))().getTime() / 1000,
  );
  const ctx: SendCtx = {
    db,
    cfg,
    jwt: await apnsJwt(cfg.teamId, cfg.keyId, cfg.p8, nowS),
    fetchFn: deps.fetchFn ?? fetch,
    evict: () => evictApnsJwt(cfg.teamId, cfg.keyId, cfg.p8),
    expiration: nowS + 3600,
    eventId: null,
    sms: deps.sms,
  };
  const alert: Alert = {
    kind: "airport_program",
    category: "delays",
    key: program.key,
    program,
  };
  const { kinds, ...alerts } = await deliver(
    ctx,
    fl.data as Flight,
    [alert],
    null,
  );
  return json({ ok: true, alerts, kinds });
}
