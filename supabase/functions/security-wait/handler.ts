// GET /security-wait?airport=SFO -> { airport, iata, available, reason, live, source, fetched_at, checkpoints }
// The security (TSA) wait at a US airport, per checkpoint, for the flight sheet's Good to Know row and
// the airport sheet's Security section (docs/api-contract.md).
//
// Sources, best first:
// 1. A live provider that covers the airport (LIVE_PROVIDERS). There is none today: no free live source
//    may be reused by a public app (docs/data-sources.md). A provider is only added with the source's
//    written permission; the code path is tested with a fake one.
// 2. An estimate from TSA's hourly throughput per checkpoint (security_checkpoints, security_throughput),
//    when the airport has rows: each checkpoint's load at this local hour (model.ts).
// 3. An estimate from a typical US day, one "All checkpoints" row, when the airport has no rows.
// Estimates always answer live: false, and the app labels them as estimates.
//
// Airports outside the US (and its territories, where TSA screens) answer available: false with reason
// outside_us and no checkpoints. An unknown or malformed code is 400 invalid_request.
//
// Answers are cached whole per airport in security_wait_cache for CACHE_TTL_MS. A failing live provider
// is logged and the estimate answers instead: an old live figure is never served as current.
import type { SupabaseClient } from "npm:@supabase/supabase-js@2";
import { resolveAirport } from "../_shared/airports.ts";
import { requireUser, type TokenVerifier } from "../_shared/auth.ts";
import { ApiError, errorResponse, json } from "../_shared/errors.ts";
import { checkRate } from "../_shared/limits.ts";
import {
  loadAt,
  localTime,
  typicalWeek,
  waitForLoad,
  weekFromRows,
} from "./model.ts";

export const CACHE_TTL_MS = 5 * 60_000;
export const SECURITY_MAX_PER_HOUR = 120;
/** Countries (ISO codes in airports.country) where TSA screens passengers. */
export const TSA_COUNTRIES = new Set(["US", "PR", "GU", "VI", "AS", "MP"]);

export interface Source {
  id: string;
  name: string;
  url: string | null;
}

export const THROUGHPUT_SOURCE: Source = {
  id: "estimate_tsa_throughput",
  name: "Estimate from TSA checkpoint traffic",
  url: "https://www.tsa.gov/foia/readingroom",
};
export const TYPICAL_SOURCE: Source = {
  id: "estimate_typical_day",
  name: "Estimate from a typical day at US airports",
  url: null,
};

export interface Checkpoint {
  id: string;
  name: string;
  terminal: string | null;
  /** True with PreCheck lanes, false without, null when unknown. */
  precheck: boolean | null;
  standard_minutes: number | null;
  /** null when the checkpoint has no PreCheck lanes (precheck false). */
  precheck_minutes: number | null;
}

export interface Answer {
  airport: string;
  iata: string | null;
  available: boolean;
  reason: "outside_us" | null;
  live: boolean;
  source: Source | null;
  fetched_at: string;
  checkpoints: Checkpoint[];
}

/**
 * A live source of checkpoint waits. `fetch` answers the checkpoints it knows, minutes as measured; it
 * throws when the source is down. Only sources whose terms allow this use may be listed.
 */
export interface LiveProvider {
  source: Source;
  covers(icao: string): boolean;
  fetch(icao: string): Promise<Checkpoint[]>;
}

/** The live sources in production: none today (see the header). */
export const LIVE_PROVIDERS: readonly LiveProvider[] = [];

export interface Deps {
  db: SupabaseClient;
  verifier?: TokenVerifier;
  now?: () => Date;
  /** Test hook: the live providers (LIVE_PROVIDERS otherwise). */
  live?: readonly LiveProvider[];
}

interface AirportRow {
  icao: string;
  iata: string | null;
  country: string | null;
  tz: string | null;
}

/** The checkpoints of the airport with their estimate at `now`; empty when it has no throughput rows. */
async function throughputEstimate(
  db: SupabaseClient,
  airport: AirportRow,
  now: Date,
): Promise<Checkpoint[]> {
  const cps = await db.from("security_checkpoints")
    .select("id, name, terminal, precheck").eq("airport_icao", airport.icao)
    .order("id");
  if (cps.error) {
    throw new Error(`security_checkpoints read failed: ${cps.error.message}`);
  }
  if (!cps.data?.length) return [];
  const rows = await db.from("security_throughput")
    .select("checkpoint_id, weekday, hour, passengers")
    .eq("airport_icao", airport.icao);
  if (rows.error) {
    throw new Error(`security_throughput read failed: ${rows.error.message}`);
  }
  const t = localTime(now, airport.tz);
  const out: Checkpoint[] = [];
  for (const c of cps.data) {
    const mine = (rows.data ?? []).filter((r) => r.checkpoint_id === c.id);
    // A checkpoint with no traffic on record (closed, or not in the report) says nothing.
    if (!mine.length) continue;
    const wait = waitForLoad(loadAt(weekFromRows(mine), t));
    out.push({
      id: c.id,
      name: c.name,
      terminal: c.terminal ?? null,
      precheck: c.precheck ?? null,
      standard_minutes: wait.standard,
      precheck_minutes: c.precheck === false ? null : wait.precheck,
    });
  }
  return out;
}

/** The typical US day at the airport's local time, as one row for every checkpoint. */
export function typicalEstimate(airport: AirportRow, now: Date): Checkpoint[] {
  const wait = waitForLoad(loadAt(typicalWeek(), localTime(now, airport.tz)));
  return [{
    id: "all",
    name: "All checkpoints",
    terminal: null,
    precheck: null,
    standard_minutes: wait.standard,
    precheck_minutes: wait.precheck,
  }];
}

/** Checkpoints sorted the way the app lists them: by terminal, then name. */
function sorted(cps: Checkpoint[]): Checkpoint[] {
  return [...cps].sort((a, b) =>
    (a.terminal ?? "").localeCompare(b.terminal ?? "", "en", {
      numeric: true,
    }) || a.name.localeCompare(b.name, "en")
  );
}

/** A live provider's answer kept to sane figures: whole minutes from 0 to 300, else unknown. */
function clean(c: Checkpoint): Checkpoint {
  const m = (v: number | null) =>
    typeof v === "number" && Number.isFinite(v) && v >= 0 && v <= 300
      ? Math.round(v)
      : null;
  return {
    ...c,
    standard_minutes: m(c.standard_minutes),
    precheck_minutes: m(c.precheck_minutes),
  };
}

/** Builds the answer for `airport` from the best source that answers. */
export async function build(
  deps: Deps,
  airport: AirportRow,
  now: Date,
): Promise<Answer> {
  const base = {
    airport: airport.icao,
    iata: airport.iata,
    fetched_at: now.toISOString(),
  };
  if (!TSA_COUNTRIES.has(airport.country ?? "")) {
    return {
      ...base,
      available: false,
      reason: "outside_us",
      live: false,
      source: null,
      checkpoints: [],
    };
  }
  for (const p of deps.live ?? LIVE_PROVIDERS) {
    if (!p.covers(airport.icao)) continue;
    try {
      const got = (await p.fetch(airport.icao)).map(clean)
        .filter((c) => c.standard_minutes !== null);
      if (got.length) {
        return {
          ...base,
          available: true,
          reason: null,
          live: true,
          source: p.source,
          checkpoints: sorted(got),
        };
      }
    } catch (e) {
      console.error(
        `live security source ${p.source.id} failed for ${airport.icao}`,
        e instanceof Error ? e.message : e,
      );
    }
  }
  const measured = await throughputEstimate(deps.db, airport, now);
  return {
    ...base,
    available: true,
    reason: null,
    live: false,
    source: measured.length ? THROUGHPUT_SOURCE : TYPICAL_SOURCE,
    checkpoints: sorted(
      measured.length ? measured : typicalEstimate(airport, now),
    ),
  };
}

export async function handler(req: Request, deps: Deps): Promise<Response> {
  try {
    if (req.method !== "GET") {
      throw new ApiError("invalid_request", 405, "GET only");
    }
    const { userId } = await requireUser(req, deps.verifier);
    const { db } = deps;
    const now = (deps.now ?? (() => new Date()))();
    await checkRate(
      userId,
      "security-wait",
      SECURITY_MAX_PER_HOUR,
      60,
      db,
    );
    const icao = await resolveAirport(
      db,
      new URL(req.url).searchParams.get("airport"),
    );

    const hit = await db.from("security_wait_cache")
      .select("payload, fetched_at").eq("airport_icao", icao).maybeSingle();
    if (hit.error) {
      throw new Error(`security_wait_cache read failed: ${hit.error.message}`);
    }
    if (
      hit.data &&
      now.getTime() - Date.parse(hit.data.fetched_at) < CACHE_TTL_MS
    ) {
      return json(hit.data.payload as Answer);
    }

    const row = await db.from("airports").select("icao, iata, country, tz")
      .eq("icao", icao).single();
    if (row.error) throw new Error(`airport read failed: ${row.error.message}`);
    const answer = await build(deps, row.data as AirportRow, now);
    const { error } = await db.from("security_wait_cache").upsert({
      airport_icao: icao,
      payload: answer,
      fetched_at: answer.fetched_at,
    });
    // A failed write is logged, never a failed answer.
    if (error) console.error("security_wait_cache write failed", error.message);
    return json(answer);
  } catch (e) {
    return errorResponse(e);
  }
}
