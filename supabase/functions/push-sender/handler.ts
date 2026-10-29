// POST /push-sender { flightId, eventId }: APNs alerts and Live Activity updates for one event.
// Service role only. The gateway checks the JWT signature (verify_jwt); this checks its role claim.
import type { SupabaseClient } from "npm:@supabase/supabase-js@2";
import { ApiError, errorResponse, json } from "../_shared/errors.ts";
import { isServiceCaller } from "../_shared/auth.ts";
import {
  alertCopy,
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

export const SEND_CONCURRENCY = 10;
/** Live Activity pushes at priority 10 are budgeted by Apple; routine updates go at 5. */
const IMMEDIATE_KINDS = new Set([
  "gate_change",
  "departure",
  "arrival",
  "cancel",
  "diversion",
]);
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

interface Flight {
  id: string;
  ident: string;
  status: string;
  [k: string]: unknown;
}

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
    let q = db.from("push_tokens").select("token, updated_at, bad_count").eq(
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
    let body: { flightId?: unknown; eventId?: unknown };
    try {
      body = await req.json();
    } catch {
      throw new ApiError("invalid_request", 400, "Invalid JSON");
    }
    const { flightId, eventId } = body;
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
      db.from("flight_events").select("id, flight_id, kind, payload")
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

    // Alerts: followers who want notifications.
    const alertTally: Tally = { sent: 0, failed: 0, removed: 0 };
    const [originTz, destinationTz] = await Promise.all([
      tz(db, flight.origin_icao),
      tz(db, flight.destination_icao),
    ]);
    const copy = alertCopy(kind, flight as never, {
      payload,
      originTz,
      destinationTz,
    });
    if (copy) {
      const users = await pagedUsers(db, flightId, true);
      const tokens = await tokensFor(db, "alert", users);
      const aps = {
        aps: {
          alert: copy,
          sound: "default",
          "thread-id": flightId,
        },
        flightId,
        eventId,
      };
      Object.assign(
        alertTally,
        await fanOut(db, "alert", "alert", tokens, (t) =>
          sendApns(t, aps, {
            pushType: "alert",
            topic: cfg.bundleId,
            sandbox: cfg.sandbox,
            jwt,
            priority: 10,
            expiration: hour,
            collapseId: eventId,
          }, fetchFn), { onProviderRejected: evict }),
      );
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
          priority: IMMEDIATE_KINDS.has(kind) ? 10 : 5,
          expiration: hour,
        }, fetchFn),
      { deleteOnSuccess: ends, onProviderRejected: evict },
    );

    return json({ ok: true, alerts: alertTally, liveActivities: laTally });
  } catch (e) {
    return errorResponse(e);
  }
}
