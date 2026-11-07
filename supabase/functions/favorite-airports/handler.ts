// POST /favorite-airports?mode=sweep -> { ok, mode, programs, favorites, sent, failed } or { skipped }.
// Service role only (pg_cron, every 5 minutes at minute 2, right after faa-status-sweep refreshed the
// shared FAA cache). For every ground stop, ground delay program or closure at an airport that a user
// follows (favorite_airports), asks push-sender to send that user one push. push-sender claims it in
// favorite_alert_log (user and program key), so each program is announced once per user however many
// sweeps see it.
//
// The sweep reads faa_status_cache only and never calls the FAA: a cache older than STALE_MAX_MS announces
// nothing (an old feed was already seen by an earlier sweep).
//
// Off unless FAVORITE_AIRPORT_ALERTS_ENABLED is exactly "true": the answer is { skipped: "disabled" }.
//
// A user who follows a flight through the same airport and program already got the flight's own
// airport_program alert (faa-status sweep, same programKey in alert_log), so the favorite push skips them.
//
// TODO(conditions): airport conditions level "major" (the faa-status conditions summary another agent is
// adding) should trigger a favorite alert too. See _shared/favorite_alerts.ts.
import type { SupabaseClient } from "npm:@supabase/supabase-js@2";
import { isServiceCaller } from "../_shared/auth.ts";
import { ApiError, errorResponse, json } from "../_shared/errors.ts";
import { ALERT_KINDS, type Program, programKey } from "../_shared/faa_nas.ts";
import type { FavoriteAlert } from "../_shared/favorite_alerts.ts";

export const STALE_MAX_MS = 30 * 60_000;
/** Countries whose airports the FAA feed covers (the same set faa-status uses). */
export const FAA_COUNTRIES = new Set(["US", "PR", "GU", "VI", "AS", "MP"]);
/** At most this many pushes are handed over per sweep; the next sweep takes the rest. */
export const MAX_SENDS = 200;
export const FLAG = "FAVORITE_AIRPORT_ALERTS_ENABLED";

export interface Deps {
  db: SupabaseClient;
  now?: () => Date;
  serviceKey?: () => string | undefined;
  /** The flag; defaults to the FAVORITE_AIRPORT_ALERTS_ENABLED secret. */
  enabled?: () => boolean;
  /** Hands one favorite alert to push-sender. */
  push?: (alert: FavoriteAlert) => Promise<void>;
}

export function pushViaFunction(db: SupabaseClient): NonNullable<Deps["push"]> {
  return async (alert) => {
    const { error } = await db.functions.invoke("push-sender", {
      body: { favorite: alert },
    });
    if (error) throw new Error(`push-sender failed: ${error.message}`);
  };
}

export interface AirportRow {
  icao: string;
  iata: string | null;
  country: string | null;
}

/** Whether the feed's code names this airport: its IATA code, or its ICAO code without the K. */
export function sameAirport(faa: string, a: AirportRow): boolean {
  return faa === a.iata || (a.icao.startsWith("K") && faa === a.icao.slice(1));
}

/** The favorite log key of a program at one airport. */
export const favoriteKey = (icao: string, p: Program) =>
  `favorite:${programKey(icao, p)}`;

export interface FavoriteRow {
  user_id: string;
  airport_icao: string;
}

/**
 * The pushes this sweep owes: one per user, followed airport and alerting program, minus the keys in
 * `sent` (`<user> <key>`) and the ones a followed flight already announced (`covered`, `<user> <program
 * key>`). Order is stable: by user, then airport, then the feed's program order.
 */
export function planFavoriteAlerts(
  programs: Program[],
  airports: AirportRow[],
  favorites: FavoriteRow[],
  sent: Set<string>,
  covered: Set<string>,
): FavoriteAlert[] {
  const byIcao = new Map<string, { row: AirportRow; programs: Program[] }>();
  for (const a of airports) {
    if (!FAA_COUNTRIES.has(a.country ?? "")) continue;
    const mine = programs.filter((p) =>
      ALERT_KINDS.has(p.kind) && sameAirport(p.airport, a)
    );
    if (mine.length) byIcao.set(a.icao, { row: a, programs: mine });
  }
  const out: FavoriteAlert[] = [];
  const favs = [...favorites].sort((x, y) =>
    x.user_id === y.user_id
      ? x.airport_icao.localeCompare(y.airport_icao)
      : x.user_id.localeCompare(y.user_id)
  );
  for (const f of favs) {
    const at = byIcao.get(f.airport_icao);
    if (!at) continue;
    for (const p of at.programs) {
      const key = favoriteKey(at.row.icao, p);
      if (sent.has(`${f.user_id} ${key}`)) continue;
      if (covered.has(`${f.user_id} ${programKey(at.row.icao, p)}`)) continue;
      out.push({
        user_id: f.user_id,
        key,
        kind: p.kind,
        code: at.row.iata ?? at.row.icao,
        airport_icao: at.row.icao,
        reason: p.reason,
        average_minutes: p.average_minutes,
        ends_at: p.ends_at,
      });
    }
  }
  return out;
}

const PAGE = 1000;

async function sweep(deps: Deps, now: Date) {
  const { db } = deps;
  const out = {
    ok: true,
    mode: "sweep",
    programs: 0,
    favorites: 0,
    sent: 0,
    failed: 0,
  };
  const hit = await db.from("faa_status_cache").select("payload, fetched_at")
    .eq("id", "nas").maybeSingle();
  if (hit.error) {
    throw new Error(`faa_status_cache read failed: ${hit.error.message}`);
  }
  if (!hit.data) return { ...out, skipped: "no_feed" };
  const t = now.getTime();
  if (t - Date.parse(hit.data.fetched_at as string) > STALE_MAX_MS) {
    return { ...out, skipped: "stale_feed" };
  }
  const all = ((hit.data.payload as { programs?: Program[] }).programs ?? [])
    .filter((p) =>
      ALERT_KINDS.has(p.kind) &&
      (p.ends_at === null || Date.parse(p.ends_at) > t)
    );
  out.programs = all.length;
  if (all.length === 0) return out;

  const codes = [...new Set(all.map((p) => p.airport))];
  const ports = await db.from("airports").select("icao, iata, country").or(
    `iata.in.(${codes.join(",")}),icao.in.(${
      codes.map((c) => `K${c}`).join(",")
    })`,
  );
  if (ports.error) {
    throw new Error(`airports read failed: ${ports.error.message}`);
  }
  const airports = (ports.data ?? []) as AirportRow[];
  if (airports.length === 0) return out;

  const favorites: FavoriteRow[] = [];
  const icaos = airports.map((a) => a.icao);
  for (let from = 0;; from += PAGE) {
    const r = await db.from("favorite_airports").select("user_id, airport_icao")
      .in("airport_icao", icaos).order("user_id").order("airport_icao")
      .range(from, from + PAGE - 1);
    if (r.error) {
      throw new Error(`favorites read failed: ${r.error.message}`);
    }
    favorites.push(...(r.data as FavoriteRow[]));
    if ((r.data ?? []).length < PAGE) break;
  }
  out.favorites = favorites.length;
  if (favorites.length === 0) return out;

  const users = [...new Set(favorites.map((f) => f.user_id))];
  const keys = new Set<string>();
  const programKeys = new Set<string>();
  for (const a of airports) {
    for (const p of all) {
      if (!sameAirport(p.airport, a)) continue;
      keys.add(favoriteKey(a.icao, p));
      programKeys.add(programKey(a.icao, p));
    }
  }
  const sent = new Set<string>();
  const covered = new Set<string>();
  for (let i = 0; i < users.length; i += 200) {
    const chunk = users.slice(i, i + 200);
    const log = await db.from("favorite_alert_log").select("user_id, key")
      .in("user_id", chunk).in("key", [...keys]);
    if (log.error) {
      throw new Error(`favorite log read failed: ${log.error.message}`);
    }
    for (const r of log.data ?? []) sent.add(`${r.user_id} ${r.key}`);
    // Flights of these users that already carry the program's own alert.
    const al = await db.from("alert_log").select("flight_id, key")
      .in("key", [...programKeys]);
    if (al.error) {
      throw new Error(`alert log read failed: ${al.error.message}`);
    }
    const byFlight = new Map<string, string[]>();
    for (const r of al.data ?? []) {
      const l = byFlight.get(r.flight_id as string) ?? [];
      l.push(r.key as string);
      byFlight.set(r.flight_id as string, l);
    }
    const flightIds = [...byFlight.keys()];
    for (let j = 0; j < flightIds.length; j += 200) {
      const uf = await db.from("user_flights").select("user_id, flight_id")
        .in("flight_id", flightIds.slice(j, j + 200)).in("user_id", chunk)
        .eq("notify", true);
      if (uf.error) {
        throw new Error(`followers read failed: ${uf.error.message}`);
      }
      for (const r of uf.data ?? []) {
        for (const k of byFlight.get(r.flight_id as string) ?? []) {
          covered.add(`${r.user_id} ${k}`);
        }
      }
    }
  }

  const todo = planFavoriteAlerts(all, airports, favorites, sent, covered);
  const push = deps.push ?? pushViaFunction(db);
  for (const a of todo) {
    if (out.sent + out.failed >= MAX_SENDS) break;
    try {
      await push(a);
      out.sent++;
    } catch (e) {
      out.failed++;
      console.error(
        "favorite-airports: push failed",
        e instanceof Error ? e.message : e,
      );
    }
  }
  return out;
}

export async function handler(req: Request, deps: Deps): Promise<Response> {
  try {
    if (req.method !== "POST") {
      throw new ApiError("invalid_request", 405, "POST only");
    }
    const key = (deps.serviceKey ?? (() =>
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")))();
    if (!(await isServiceCaller(req, key))) {
      throw new ApiError("unauthorized", 401, "Service role only");
    }
    if (new URL(req.url).searchParams.get("mode") !== "sweep") {
      throw new ApiError("invalid_request", 400, "mode must be sweep");
    }
    const on = (deps.enabled ?? (() => Deno.env.get(FLAG) === "true"))();
    if (!on) return json({ ok: true, mode: "sweep", skipped: "disabled" });
    return json(await sweep(deps, (deps.now ?? (() => new Date()))()));
  } catch (e) {
    return errorResponse(e);
  }
}
