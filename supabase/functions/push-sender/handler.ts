// POST /push-sender { flightId, eventId }: APNs alerts and Live Activity updates for one event.
// Service role only. The gateway checks the JWT signature (verify_jwt); this checks its role claim.
import type { SupabaseClient } from "npm:@supabase/supabase-js@2";
import { ApiError, errorResponse, json } from "../_shared/errors.ts";
import {
  alertCopy,
  apnsJwt,
  type ApnsResult,
  type FlightEventKind,
  isDeadToken,
  mapLimit,
  sendApns,
} from "../_shared/apns.ts";

export const SEND_CONCURRENCY = 10;
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

/** The `role` claim of a bearer JWT, unverified: the gateway already checked the signature. */
function callerRole(req: Request): string | null {
  const m = /^Bearer\s+([\w-]+)\.([\w-]+)\.([\w-]*)$/i.exec(
    req.headers.get("authorization") ?? "",
  );
  if (!m) return null;
  try {
    const b64 = m[2].replace(/-/g, "+").replace(/_/g, "/");
    const claims = JSON.parse(
      atob(b64.padEnd(Math.ceil(b64.length / 4) * 4, "=")),
    );
    return typeof claims?.role === "string" ? claims.role : null;
  } catch {
    return null;
  }
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

async function tokensFor(
  db: SupabaseClient,
  kind: "alert" | "live_activity",
  users: Set<string>,
  flightId?: string,
): Promise<string[]> {
  const ids = [...users];
  const tokens: string[] = [];
  for (let i = 0; i < ids.length; i += 200) {
    let q = db.from("push_tokens").select("token").eq("kind", kind)
      .in("user_id", ids.slice(i, i + 200));
    if (flightId) q = q.eq("flight_id", flightId);
    const { data, error } = await q;
    if (error) throw new Error(`tokens read failed: ${error.message}`);
    for (const r of data) tokens.push(r.token as string);
  }
  return [...new Set(tokens)];
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

/** Sends to every token, a few at a time. Dead tokens are deleted; other failures are logged without secrets. */
async function fanOut(
  db: SupabaseClient,
  label: string,
  kind: "alert" | "live_activity",
  tokens: string[],
  send: (token: string) => Promise<ApnsResult>,
): Promise<Tally> {
  const tally: Tally = { sent: 0, failed: 0, removed: 0 };
  await mapLimit(tokens, SEND_CONCURRENCY, async (token) => {
    let r: ApnsResult;
    try {
      r = await send(token);
    } catch {
      r = { ok: false, status: 0, reason: "send_error" };
    }
    if (r.ok) {
      tally.sent++;
      return;
    }
    tally.failed++;
    if (isDeadToken(r)) {
      const del = await db.from("push_tokens").delete().eq("token", token)
        .eq("kind", kind);
      if (del.error) {
        console.error(`${label}: token delete failed: ${del.error.message}`);
      } else tally.removed++;
    } else {
      console.error(
        `${label}: apns failure status=${r.status} reason=${
          r.reason ?? "none"
        }`,
      );
    }
  });
  return tally;
}

export async function handler(req: Request, deps: Deps): Promise<Response> {
  try {
    if (req.method !== "POST") {
      throw new ApiError("invalid_request", 405, "Use POST");
    }
    if (callerRole(req) !== "service_role") {
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
          }, fetchFn)),
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
          priority: 10,
          expiration: hour,
        }, fetchFn),
    );

    return json({ ok: true, alerts: alertTally, liveActivities: laTally });
  } catch (e) {
    return errorResponse(e);
  }
}
