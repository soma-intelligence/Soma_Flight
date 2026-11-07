// GET /faa-status?airport=SFO -> { airport, iata, available, reason, stale, fetched_at, programs }
// The FAA's live programs at a US airport (ground stop, ground delay program, departure or arrival
// delays, closure, deicing), for the flight sheet's Good to Know, the airport sheet's issues card and
// the Operations Report (docs/api-contract.md). Free: the FAA's public status feed (_shared/faa_nas.ts).
//
// POST /faa-status?mode=sweep -> { ok, mode, stale, programs, flights, sent, failed }. Service role only
// (pg_cron, every 5 minutes): refreshes the feed and, for every ground stop, ground delay program or
// closure that matters to a followed flight that has not left yet, asks push-sender to send the
// airport_program alert. push-sender claims it in alert_log (key per flight, airport, kind and start),
// so each program is announced once per flight however many sweeps see it.
//
// Every answer may also carry `conditions` (US or not): a level (normal, minor, major) and short reasons
// that rules over the airport's NOTAMs, METAR and TAF produce (_shared/conditions.ts). Outside the US that
// is the whole disruption read (available stays false: there is no national program feed); at US airports
// it adds the weather and notice reasons next to the FAA's programs.
//
// The feed is cached whole in faa_status_cache for CACHE_TTL_MS, shared by every airport. When the FAA
// does not answer, a cached feed up to STALE_MAX_MS old answers with stale: true; older than that, 503
// provider_unavailable (an old "no programs" must not read as a calm day). Airports outside the US
// answer available: false, reason outside_us, without reading the feed. An unknown or malformed code is
// 400 invalid_request.
import type { SupabaseClient } from "npm:@supabase/supabase-js@2";
import { resolveAirport } from "../_shared/airports.ts";
import {
  isServiceCaller,
  requireUser,
  type TokenVerifier,
} from "../_shared/auth.ts";
import { ApiError, errorResponse, json } from "../_shared/errors.ts";
import {
  ALERT_KINDS,
  type End,
  fetchNas,
  mattersAt,
  type Program,
  type ProgramAlert,
  programKey,
} from "../_shared/faa_nas.ts";
import type { Conditions } from "../_shared/conditions.ts";
import { checkRate } from "../_shared/limits.ts";

export const CACHE_TTL_MS = 5 * 60_000;
export const STALE_MAX_MS = 30 * 60_000;
export const FAA_MAX_PER_HOUR = 120;
/** Countries (ISO codes in airports.country) whose airports the FAA status feed covers. */
export const FAA_COUNTRIES = new Set(["US", "PR", "GU", "VI", "AS", "MP"]);
/** The sweep looks at flights leaving within this window. */
export const SWEEP_AHEAD_MS = 12 * 3600_000;
export const SWEEP_BEHIND_MS = 60 * 60_000;
/** At most this many alerts are handed to push-sender per sweep; the next sweep takes the rest. */
export const MAX_SENDS = 200;

export interface Deps {
  db: SupabaseClient;
  verifier?: TokenVerifier;
  now?: () => Date;
  /** The feed's fetch (tests pass a fake; never the network in tests). */
  fetchFn?: typeof fetch;
  /** The project's service role key, compared with the bearer token. Defaults to the env. */
  serviceKey?: () => string | undefined;
  /** Hands one program alert to push-sender. */
  push?: (flightId: string, program: ProgramAlert) => Promise<void>;
  /**
   * The conditions summary of an airport (NOTAMs, METAR, TAF; _shared/conditions.ts), null when nothing
   * could be read. Without it the answer has no `conditions` key (tests, and the sweep never needs it).
   */
  conditions?: (icao: string, now: Date) => Promise<Conditions | null>;
}

/** Default push dep: invokes the push-sender edge function with the service client. */
export function pushViaFunction(db: SupabaseClient): NonNullable<Deps["push"]> {
  return async (flightId, program) => {
    const { error } = await db.functions.invoke("push-sender", {
      body: { flightId, program },
    });
    if (error) throw new Error(`push-sender failed: ${error.message}`);
  };
}

export interface Answer {
  airport: string;
  iata: string | null;
  available: boolean;
  reason: "outside_us" | null;
  /** True when the FAA did not answer and the programs are from an older read (at most 30 minutes). */
  stale: boolean;
  /** When the feed was read. */
  fetched_at: string;
  /** Most serious first. */
  programs: Program[];
  /**
   * What the notices and the weather say about the airport, at every airport (US and not): a level and
   * short reasons, from rules only. Null when neither could be read. Absent when the function runs
   * without the summary wired.
   */
  conditions?: Conditions | null;
}

interface Feed {
  programs: Program[];
  fetched_at: string;
  stale: boolean;
}

/**
 * The feed: the cached copy while it is under CACHE_TTL_MS, else a fresh read (stored). A failed read
 * falls back to a copy under STALE_MAX_MS, marked stale, else 503. Programs that ended since the read
 * are dropped.
 */
export async function feed(deps: Deps, now: Date): Promise<Feed> {
  const { db } = deps;
  const hit = await db.from("faa_status_cache").select("payload, fetched_at")
    .eq("id", "nas").maybeSingle();
  if (hit.error) {
    throw new Error(`faa_status_cache read failed: ${hit.error.message}`);
  }
  const t = now.getTime();
  const live = (ps: Program[]) =>
    ps.filter((p) => p.ends_at === null || Date.parse(p.ends_at) > t);
  const age = hit.data ? t - Date.parse(hit.data.fetched_at) : Infinity;
  const cached = () =>
    live((hit.data!.payload as { programs?: Program[] }).programs ?? []);
  if (age < CACHE_TTL_MS) {
    return {
      programs: cached(),
      fetched_at: new Date(hit.data!.fetched_at).toISOString(),
      stale: false,
    };
  }
  try {
    const programs = await fetchNas(deps.fetchFn ?? fetch, now);
    const fetched_at = now.toISOString();
    const { error } = await db.from("faa_status_cache").upsert({
      id: "nas",
      payload: { programs },
      fetched_at,
    });
    // A failed write is logged, never a failed answer.
    if (error) console.error("faa_status_cache write failed", error.message);
    return { programs, fetched_at, stale: false };
  } catch (e) {
    console.error(
      "faa-status: feed read failed",
      e instanceof Error ? e.message : e,
    );
    if (age < STALE_MAX_MS) {
      return {
        programs: cached(),
        fetched_at: new Date(hit.data!.fetched_at).toISOString(),
        stale: true,
      };
    }
    throw new ApiError(
      "provider_unavailable",
      503,
      "The FAA status feed is not answering",
    );
  }
}

interface AirportRow {
  icao: string;
  iata: string | null;
  country: string | null;
}

/** Whether the feed's code names this airport: its IATA code, or its ICAO code without the K. */
export function sameAirport(faa: string, a: AirportRow): boolean {
  return faa === a.iata || (a.icao.startsWith("K") && faa === a.icao.slice(1));
}

async function answer(deps: Deps, req: Request, now: Date): Promise<Answer> {
  const { db } = deps;
  const { userId } = await requireUser(req, deps.verifier);
  await checkRate(userId, "faa-status", FAA_MAX_PER_HOUR, 60, db);
  const icao = await resolveAirport(
    db,
    new URL(req.url).searchParams.get("airport"),
  );
  const row = await db.from("airports").select("icao, iata, country")
    .eq("icao", icao).single();
  if (row.error) throw new Error(`airport read failed: ${row.error.message}`);
  const a = row.data as AirportRow;
  // The summary is an extra: its failure never fails the answer.
  const summary = async (): Promise<{ conditions?: Conditions | null }> => {
    if (!deps.conditions) return {};
    try {
      return { conditions: await deps.conditions(a.icao, now) };
    } catch (e) {
      console.error(
        "faa-status: conditions failed",
        e instanceof Error ? e.message : e,
      );
      return { conditions: null };
    }
  };
  if (!FAA_COUNTRIES.has(a.country ?? "")) {
    return {
      airport: a.icao,
      iata: a.iata,
      available: false,
      reason: "outside_us",
      stale: false,
      fetched_at: now.toISOString(),
      programs: [],
      ...await summary(),
    };
  }
  const [f, extra] = await Promise.all([feed(deps, now), summary()]);
  return {
    airport: a.icao,
    iata: a.iata,
    available: true,
    reason: null,
    stale: f.stale,
    fetched_at: f.fetched_at,
    programs: f.programs.filter((p) => sameAirport(p.airport, a)),
    ...extra,
  };
}

/** The flights columns the sweep reads. */
interface SweepFlight {
  id: string;
  origin_icao: string | null;
  destination_icao: string | null;
  scheduled_out: string | null;
  estimated_out: string | null;
  scheduled_in: string | null;
  estimated_in: string | null;
}

/**
 * Whether a program at one end matters to this flight: the kind matters at that end (mattersAt), and
 * the program covers the moment it is about: the departure for a ground stop or ground delay program
 * (they hold the flight before it leaves) and for a closure of the origin, the arrival for a closure
 * of the destination.
 */
export function programMatters(
  p: Program,
  end: End,
  f: SweepFlight,
): boolean {
  if (!mattersAt(p.kind, end)) return false;
  const dep = Date.parse(f.estimated_out ?? f.scheduled_out ?? "");
  if (!Number.isFinite(dep)) return false;
  const arr = Date.parse(f.estimated_in ?? f.scheduled_in ?? "");
  const moment = end === "destination" && p.kind === "closure" &&
      Number.isFinite(arr)
    ? arr
    : dep;
  const starts = p.starts_at ? Date.parse(p.starts_at) : -Infinity;
  const ends = p.ends_at ? Date.parse(p.ends_at) : Infinity;
  return starts <= moment && ends > moment;
}

async function sweep(deps: Deps, now: Date) {
  const { db } = deps;
  const f = await feed(deps, now);
  const alerting = f.programs.filter((p) => ALERT_KINDS.has(p.kind));
  const out = {
    ok: true,
    mode: "sweep",
    stale: f.stale,
    programs: alerting.length,
    flights: 0,
    sent: 0,
    failed: 0,
  };
  // A stale feed announces nothing: what it holds was already seen by an earlier sweep.
  if (alerting.length === 0 || f.stale) return out;

  const codes = [...new Set(alerting.map((p) => p.airport))];
  const ports = await db.from("airports").select("icao, iata, country")
    .or(
      `iata.in.(${codes.join(",")}),icao.in.(${
        codes.map((c) => `K${c}`).join(",")
      })`,
    );
  if (ports.error) {
    throw new Error(`airports read failed: ${ports.error.message}`);
  }
  const airports = ((ports.data ?? []) as AirportRow[])
    .filter((a) => FAA_COUNTRIES.has(a.country ?? ""));
  const byIcao = new Map<string, { row: AirportRow; programs: Program[] }>();
  for (const a of airports) {
    const mine = alerting.filter((p) => sameAirport(p.airport, a));
    if (mine.length) byIcao.set(a.icao, { row: a, programs: mine });
  }
  if (byIcao.size === 0) return out;

  const icaos = [...byIcao.keys()].join(",");
  const t = now.getTime();
  const fl = await db.from("flights")
    .select(
      "id, origin_icao, destination_icao, scheduled_out, estimated_out, scheduled_in, estimated_in, user_flights!inner(notify)",
    )
    .eq("user_flights.notify", true)
    .in("status", ["scheduled", "unknown"])
    .is("actual_out", null)
    .gte(
      "scheduled_out",
      new Date(t - SWEEP_BEHIND_MS - 6 * 3600_000).toISOString(),
    )
    .lte("scheduled_out", new Date(t + SWEEP_AHEAD_MS).toISOString())
    .or(`origin_icao.in.(${icaos}),destination_icao.in.(${icaos})`)
    .limit(1000);
  if (fl.error) throw new Error(`flights read failed: ${fl.error.message}`);
  const flights = ((fl.data ?? []) as unknown as SweepFlight[]).filter((x) => {
    const dep = Date.parse(x.estimated_out ?? x.scheduled_out ?? "");
    return Number.isFinite(dep) && dep >= t - SWEEP_BEHIND_MS &&
      dep <= t + SWEEP_AHEAD_MS;
  });
  out.flights = flights.length;
  if (flights.length === 0) return out;

  const todo: { flightId: string; program: ProgramAlert }[] = [];
  for (const x of flights) {
    for (const end of ["origin", "destination"] as const) {
      const icao = end === "origin" ? x.origin_icao : x.destination_icao;
      const at = icao ? byIcao.get(icao) : undefined;
      if (!at) continue;
      for (const p of at.programs) {
        if (!programMatters(p, end, x)) continue;
        todo.push({
          flightId: x.id,
          program: {
            key: programKey(at.row.icao, p),
            kind: p.kind,
            end,
            code: at.row.iata ?? at.row.icao,
            reason: p.reason,
            average_minutes: p.average_minutes,
            ends_at: p.ends_at,
          },
        });
      }
    }
  }
  if (todo.length === 0) return out;

  // Keys already sent are skipped here; push-sender's claim stops any that slip through.
  const sent = new Set<string>();
  const ids = [...new Set(todo.map((x) => x.flightId))];
  for (let i = 0; i < ids.length; i += 200) {
    const log = await db.from("alert_log").select("flight_id, key")
      .in("flight_id", ids.slice(i, i + 200)).like("key", "airport_program:%");
    if (log.error) {
      throw new Error(`alert log read failed: ${log.error.message}`);
    }
    for (const r of log.data ?? []) sent.add(`${r.flight_id} ${r.key}`);
  }
  const push = deps.push ?? pushViaFunction(db);
  for (const x of todo) {
    if (sent.has(`${x.flightId} ${x.program.key}`)) continue;
    if (out.sent + out.failed >= MAX_SENDS) break;
    try {
      await push(x.flightId, x.program);
      out.sent++;
    } catch (e) {
      out.failed++;
      console.error(
        `faa-status: program alert failed for flight ${x.flightId}`,
        e instanceof Error ? e.message : e,
      );
    }
  }
  return out;
}

export async function handler(req: Request, deps: Deps): Promise<Response> {
  try {
    const now = (deps.now ?? (() => new Date()))();
    if (req.method === "GET") return json(await answer(deps, req, now));
    if (req.method !== "POST") {
      throw new ApiError("invalid_request", 405, "GET or POST only");
    }
    const key = (deps.serviceKey ?? (() =>
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")))();
    if (!(await isServiceCaller(req, key))) {
      throw new ApiError("unauthorized", 401, "Service role only");
    }
    if (new URL(req.url).searchParams.get("mode") !== "sweep") {
      throw new ApiError("invalid_request", 400, "mode must be sweep");
    }
    return json(await sweep(deps, now));
  } catch (e) {
    return errorResponse(e);
  }
}
