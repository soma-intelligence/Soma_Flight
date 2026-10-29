// GET /airport-board?airport=<IATA or ICAO>&kind=departures|arrivals|stats|weather
//   -> { icao, kind, fetchedAt, stale, payload }
// Lazy refresh only: a snapshot older than its TTL is rebuilt on read. One lease per airport and
// kind (claim_airport_refresh) keeps concurrent readers from each paying the provider.
import type { SupabaseClient } from "npm:@supabase/supabase-js@2";
import { type AeroApi, toFlightRows } from "../_shared/aeroapi.ts";
import { resolveAirport } from "../_shared/airports.ts";
import { requireUser, type TokenVerifier } from "../_shared/auth.ts";
import {
  computeStats,
  type DelayStats,
  type Severity,
} from "../_shared/delay_stats.ts";
import { ApiError, errorResponse, json } from "../_shared/errors.ts";
import { checkRate } from "../_shared/limits.ts";
import { fetchWeather } from "../_shared/weather.ts";

export const BOARD_TTL_MS = 5 * 60_000;
export const WEATHER_TTL_MS = 15 * 60_000;
export const BOARD_MAX_PER_HOUR = 120;
/** A refresh that outlives this is presumed dead and can be claimed again. */
export const LEASE_SECONDS = 20;
const WAIT_MS = 6_000;
const POLL_MS = 400;

export type Kind = "departures" | "arrivals" | "stats" | "weather";
const KINDS: readonly string[] = ["departures", "arrivals", "stats", "weather"];

export interface Deps {
  db: SupabaseClient;
  aero: Pick<AeroApi, "boardFlights">;
  fetchFn?: typeof fetch;
  verifier?: TokenVerifier;
  now?: () => Date;
  /** Test hooks for the wait on a first-ever refresh in flight elsewhere. */
  sleep?: (ms: number) => Promise<void>;
  waitMs?: number;
}

interface Snapshot {
  payload: unknown;
  fetchedAt: string;
  stale: boolean;
}

const ttlOf = (kind: Kind) =>
  kind === "weather" ? WEATHER_TTL_MS : BOARD_TTL_MS;

async function read(
  db: SupabaseClient,
  icao: string,
  kind: Kind,
): Promise<{ payload: unknown; fetchedAt: string } | null> {
  const { data, error } = await db.from("airport_snapshots")
    .select("payload, fetched_at").eq("icao", icao).eq("kind", kind)
    .maybeSingle();
  if (error) throw new Error(`snapshot read failed: ${error.message}`);
  return data
    ? {
      payload: data.payload,
      fetchedAt: new Date(data.fetched_at).toISOString(),
    }
    : null;
}

async function touch(db: SupabaseClient, icao: string, kind: Kind, now: Date) {
  const { error } = await db.from("airport_snapshots")
    .update({ last_viewed_at: now.toISOString() })
    .eq("icao", icao).eq("kind", kind);
  if (error) throw new Error(`last_viewed_at update failed: ${error.message}`);
}

async function write(
  db: SupabaseClient,
  icao: string,
  kind: Kind,
  payload: unknown,
  fetchedAt: string,
  now: Date,
) {
  const { error } = await db.from("airport_snapshots").upsert({
    icao,
    kind,
    payload,
    fetched_at: fetchedAt,
    last_viewed_at: now.toISOString(),
  }, { onConflict: "icao,kind" });
  if (error) throw new Error(`snapshot write failed: ${error.message}`);
}

async function claim(db: SupabaseClient, icao: string, kind: Kind) {
  const { data, error } = await db.rpc("claim_airport_refresh", {
    p_icao: icao,
    p_kind: kind,
    p_lease_seconds: LEASE_SECONDS,
  });
  if (error) throw new Error(`claim_airport_refresh failed: ${error.message}`);
  return data === true;
}

async function release(db: SupabaseClient, icao: string, kind: Kind) {
  const { error } = await db.rpc("release_airport_refresh", {
    p_icao: icao,
    p_kind: kind,
  });
  if (error) {
    throw new Error(`release_airport_refresh failed: ${error.message}`);
  }
}

const isFresh = (fetchedAt: string, kind: Kind, now: Date) =>
  now.getTime() - Date.parse(fetchedAt) < ttlOf(kind);

/**
 * The snapshot when fresh. Otherwise one caller wins the lease and refreshes; the others get the
 * stale snapshot, or wait briefly when there is none yet. A failed refresh serves the old
 * snapshot as stale (original fetchedAt) and keeps the lease as a short back-off, or throws
 * provider_unavailable when there is nothing to serve.
 */
async function serve(
  deps: Deps,
  icao: string,
  kind: Kind,
  now: Date,
  refresh: () => Promise<unknown>,
): Promise<Snapshot> {
  const { db } = deps;
  const existing = await read(db, icao, kind);
  if (existing && isFresh(existing.fetchedAt, kind, now)) {
    await touch(db, icao, kind, now);
    return { ...existing, stale: false };
  }

  if (!await claim(db, icao, kind)) {
    if (existing) {
      await touch(db, icao, kind, now);
      return { ...existing, stale: true };
    }
    const sleep = deps.sleep ??
      ((ms: number) => new Promise<void>((r) => setTimeout(r, ms)));
    for (let waited = 0; waited < (deps.waitMs ?? WAIT_MS); waited += POLL_MS) {
      await sleep(POLL_MS);
      const got = await read(db, icao, kind);
      if (got) {
        await touch(db, icao, kind, now);
        return { ...got, stale: !isFresh(got.fetchedAt, kind, now) };
      }
    }
    throw new ApiError(
      "provider_unavailable",
      503,
      "Board is refreshing, retry shortly",
    );
  }

  // Won the lease. Someone may have finished between the read and the claim.
  const again = await read(db, icao, kind);
  if (again && isFresh(again.fetchedAt, kind, now)) {
    await release(db, icao, kind);
    await touch(db, icao, kind, now);
    return { ...again, stale: false };
  }
  const old = again ?? existing;

  let payload: unknown;
  try {
    payload = await refresh();
  } catch (e) {
    console.error(`refresh ${icao} ${kind} failed`, e);
    if (old) {
      await touch(db, icao, kind, now);
      return { ...old, stale: true };
    }
    await release(db, icao, kind);
    throw new ApiError(
      "provider_unavailable",
      503,
      "Provider unavailable and no snapshot yet",
    );
  }
  const fetchedAt = now.toISOString();
  await write(db, icao, kind, payload, fetchedAt, now);
  await release(db, icao, kind);
  return { payload, fetchedAt, stale: false };
}

const SEVERITY_RANK: Record<Severity, number> = {
  normal: 0,
  moderate: 1,
  major: 2,
};

interface BoardPayload {
  flights: Parameters<typeof computeStats>[0];
}

/**
 * Delay stats of both boards. fetchedAt is the older board's, so stats age with their data and
 * a stale board shows as stale stats.
 */
async function serveStats(
  deps: Deps,
  icao: string,
  now: Date,
): Promise<Snapshot> {
  const { db } = deps;
  const existing = await read(db, icao, "stats");
  if (existing && isFresh(existing.fetchedAt, "stats", now)) {
    await touch(db, icao, "stats", now);
    return { ...existing, stale: false };
  }
  try {
    const [dep, arr] = await Promise.all([
      serve(
        deps,
        icao,
        "departures",
        now,
        () => refreshBoard(deps, icao, "departures", now),
      ),
      serve(
        deps,
        icao,
        "arrivals",
        now,
        () => refreshBoard(deps, icao, "arrivals", now),
      ),
    ]);
    const departures = computeStats(
      (dep.payload as BoardPayload).flights,
      "departures",
    );
    const arrivals = computeStats(
      (arr.payload as BoardPayload).flights,
      "arrivals",
    );
    const payload = {
      departures,
      arrivals,
      severity: [departures, arrivals].map((s: DelayStats) => s.severity)
        .reduce((a, b) => SEVERITY_RANK[b] > SEVERITY_RANK[a] ? b : a),
    };
    const fetchedAt = dep.fetchedAt < arr.fetchedAt
      ? dep.fetchedAt
      : arr.fetchedAt;
    await write(db, icao, "stats", payload, fetchedAt, now);
    return { payload, fetchedAt, stale: dep.stale || arr.stale };
  } catch (e) {
    if (existing && e instanceof ApiError) {
      await touch(db, icao, "stats", now);
      return { ...existing, stale: true };
    }
    throw e;
  }
}

async function refreshBoard(
  deps: Deps,
  icao: string,
  kind: "departures" | "arrivals",
  now: Date,
): Promise<BoardPayload> {
  const flights = await deps.aero.boardFlights(icao, kind);
  return { flights: toFlightRows(flights, now) };
}

export async function handler(req: Request, deps: Deps): Promise<Response> {
  try {
    if (req.method !== "GET") {
      throw new ApiError("invalid_request", 405, "GET only");
    }
    const { userId } = await requireUser(req, deps.verifier);
    const { db } = deps;
    const now = (deps.now ?? (() => new Date()))();
    await checkRate(userId, "airport-board", BOARD_MAX_PER_HOUR, 60, db);

    const url = new URL(req.url);
    const kind = url.searchParams.get("kind") ?? "";
    if (!KINDS.includes(kind)) {
      throw new ApiError(
        "invalid_request",
        400,
        "kind must be departures, arrivals, stats or weather",
      );
    }
    const icao = await resolveAirport(db, url.searchParams.get("airport"));

    let snap: Snapshot;
    switch (kind as Kind) {
      case "stats":
        snap = await serveStats(deps, icao, now);
        break;
      case "weather":
        snap = await serve(
          deps,
          icao,
          "weather",
          now,
          () => fetchWeather(icao, deps.fetchFn),
        );
        break;
      default: {
        const k = kind as "departures" | "arrivals";
        snap = await serve(
          deps,
          icao,
          k,
          now,
          () => refreshBoard(deps, icao, k, now),
        );
      }
    }
    return json({
      icao,
      kind,
      fetchedAt: snap.fetchedAt,
      stale: snap.stale,
      payload: snap.payload,
    });
  } catch (e) {
    return errorResponse(e);
  }
}
