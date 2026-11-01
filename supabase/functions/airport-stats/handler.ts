// GET /airport-stats?airport=SFO  -> one airport's live numbers (the airport card)
// GET /airport-stats?airports=SFO,JFK -> a short summary per airport (the Airports list)
//
// The paid half of the airport screens, in one provider-agnostic shape: on time, delayed and
// canceled per direction, the average delay, the delay trend by hour (actual, then estimated), and
// the day's traffic (departures, airlines, airports and countries served, busiest airlines and
// routes). Everything is aggregated here from the airport-board provider interface
// (BOARD_PROVIDER: AeroAPI, Aviationstack or FlightLabs, _shared/providers), reading the same
// 5 minute board snapshots airport-board keeps, so a list, a card and a board share one provider
// call per airport and direction.
//
// With BOARD_PROVIDER=none (today) nothing is asked of anyone and the answer says so:
// { available: false, reason: "no_provider" }. The app then shows its "needs a data plan" note; it
// never makes numbers up. `next_7_days` needs a schedules feed no adapter has yet: always null.
// docs/airports.md lists what each provider gives and what a refresh costs.
import {
  type AirportRow,
  inAskedOrder,
  parseCodes,
} from "../_shared/airport_codes.ts";
import { requireUser, type TokenVerifier } from "../_shared/auth.ts";
import type { BoardRow } from "../_shared/board_rows.ts";
import { computeStats } from "../_shared/delay_stats.ts";
import { ApiError, errorResponse, json } from "../_shared/errors.ts";
import type { ProviderName } from "../_shared/providers/types.ts";

export const MAX_AIRPORTS = 20;
export const TOP = 5;
export const STATS_MAX_PER_HOUR = 120;

export type Direction = "departures" | "arrivals";

/** One direction's board as airport-board serves it. */
export interface Board {
  flights: BoardRow[];
  fetchedAt: string;
  stale: boolean;
}

export interface Deps {
  verifier?: TokenVerifier;
  now?: () => Date;
  /** Who answers boards (`chosen("board", env)`); "none" answers available: false. */
  provider: ProviderName;
  airports: (codes: string[]) => Promise<AirportRow[]>;
  /** One direction's board for an airport: the shared snapshot, refreshed when older than 5 minutes. */
  board: (icao: string, kind: Direction, now: Date) => Promise<Board>;
  rate?: (userId: string) => Promise<void>;
}

/** On time, delayed 15 minutes or more, canceled: the list's three columns. */
export interface Brief {
  total: number;
  on_time: number;
  delayed: number;
  canceled: number;
  avg_delay_minutes: number;
}

/** One hour of the delay trend. `estimated` when no flight in it has an actual time yet. */
export interface TrendHour {
  hour: string;
  avg_delay_minutes: number;
  flights: number;
  estimated: boolean;
}

export interface Summary extends Brief {
  trend: TrendHour[];
  /** The routes and airlines with the most delayed (15 min+) and canceled flights, worst first. */
  worst_routes: { icao: string; delayed: number; canceled: number }[];
  worst_airlines: { operator: string; delayed: number; canceled: number }[];
}

export interface Traffic {
  departures: number;
  airlines: number;
  airports_served: number;
  countries_served: number;
  busiest_airlines: { operator: string; flights: number }[];
  busiest_routes: { icao: string; flights: number }[];
}

export interface Detail {
  available: boolean;
  reason: "no_provider" | null;
  provider: ProviderName;
  icao: string;
  fetched_at: string | null;
  stale: boolean;
  departures: Summary | null;
  arrivals: Summary | null;
  today: Traffic | null;
  next_7_days: Traffic | null;
}

export interface ListItem {
  icao: string;
  iata: string | null;
  fetched_at: string | null;
  stale: boolean;
  departures: Brief | null;
  arrivals: Brief | null;
  /** Set when the provider failed for this airport and nothing was kept. */
  error: "provider_unavailable" | null;
}

export interface List {
  available: boolean;
  reason: "no_provider" | null;
  provider: ProviderName;
  airports: ListItem[];
}

const MINUTE = 60_000;

function ms(iso: string | null | undefined): number | null {
  if (!iso) return null;
  const t = Date.parse(iso);
  return Number.isFinite(t) ? t : null;
}

/** The core's counts over the flights already due (flights ahead are not on time yet). */
export function brief(flights: BoardRow[], kind: Direction, now: Date): Brief {
  const s = computeStats(flights, kind, now);
  return {
    total: s.total,
    on_time: s.onTime,
    delayed: s.delayed15,
    canceled: s.canceled,
    avg_delay_minutes: Math.round(s.avgDelayMinutes),
  };
}

/** The full direction: counts, the trend and the most disrupted routes and airlines (the Rust core). */
export function summary(
  flights: BoardRow[],
  kind: Direction,
  now: Date,
): Summary {
  const s = computeStats(flights, kind, now);
  return {
    total: s.total,
    on_time: s.onTime,
    delayed: s.delayed15,
    canceled: s.canceled,
    avg_delay_minutes: Math.round(s.avgDelayMinutes),
    trend: trend(flights, kind),
    worst_routes: s.worstRoutes.slice(0, TOP),
    worst_airlines: s.worstAirlines.slice(0, TOP),
  };
}

/**
 * Average delay per UTC hour of the scheduled time, every flight on the board (past and ahead).
 * A flight's delay is its actual time, else its estimate, minus the schedule, floored at 0. Canceled
 * flights have no delay and are left out.
 */
export function trend(flights: BoardRow[], kind: Direction): TrendHour[] {
  const dep = kind === "departures";
  const bins = new Map<number, { sum: number; n: number; actual: boolean }>();
  for (const f of flights) {
    if (f.status === "canceled") continue;
    const scheduled = ms(dep ? f.scheduled_out : f.scheduled_in);
    const actual = ms(dep ? f.actual_out : f.actual_in);
    const estimated = ms(dep ? f.estimated_out : f.estimated_in);
    const best = actual ?? estimated;
    if (scheduled === null || best === null) continue;
    const hour = Math.floor(scheduled / 3_600_000) * 3_600_000;
    const b = bins.get(hour) ?? { sum: 0, n: 0, actual: false };
    b.sum += Math.max(0, (best - scheduled) / MINUTE);
    b.n += 1;
    b.actual ||= actual !== null;
    bins.set(hour, b);
  }
  return [...bins.entries()].sort((a, b) => a[0] - b[0]).map(([hour, b]) => ({
    hour: new Date(hour).toISOString(),
    avg_delay_minutes: Math.round(b.sum / b.n),
    flights: b.n,
    estimated: !b.actual,
  }));
}

function top<K>(counts: Map<K, number>): [K, number][] {
  return [...counts.entries()].sort((a, b) => b[1] - a[1]).slice(0, TOP);
}

/** The day's traffic from the departures board; countries from the served airports' rows. */
export function traffic(
  departures: BoardRow[],
  countryOf: (icao: string) => string | null,
): Traffic {
  const flying = departures.filter((f) => f.status !== "canceled");
  const airlines = new Map<string, number>();
  const routes = new Map<string, number>();
  for (const f of flying) {
    if (f.operator) {
      airlines.set(f.operator, (airlines.get(f.operator) ?? 0) + 1);
    }
    routes.set(
      f.destination_icao,
      (routes.get(f.destination_icao) ?? 0) + 1,
    );
  }
  const countries = new Set(
    [...routes.keys()].map(countryOf).filter((c): c is string => c !== null),
  );
  return {
    departures: flying.length,
    airlines: airlines.size,
    airports_served: routes.size,
    countries_served: countries.size,
    busiest_airlines: top(airlines).map(([operator, flights]) => ({
      operator,
      flights,
    })),
    busiest_routes: top(routes).map(([icao, flights]) => ({ icao, flights })),
  };
}

async function detail(
  deps: Deps,
  row: AirportRow,
  now: Date,
): Promise<Detail> {
  const [dep, arr] = await Promise.all([
    deps.board(row.icao, "departures", now),
    deps.board(row.icao, "arrivals", now),
  ]);
  const served = [...new Set(dep.flights.map((f) => f.destination_icao))];
  const rows = served.length ? await deps.airports(served) : [];
  const country = new Map(rows.map((r) => [r.icao, r.country]));
  return {
    available: true,
    reason: null,
    provider: deps.provider,
    icao: row.icao,
    fetched_at: dep.fetchedAt < arr.fetchedAt ? dep.fetchedAt : arr.fetchedAt,
    stale: dep.stale || arr.stale,
    departures: summary(dep.flights, "departures", now),
    arrivals: summary(arr.flights, "arrivals", now),
    today: traffic(dep.flights, (icao) => country.get(icao) ?? null),
    next_7_days: null,
  };
}

async function listItem(
  deps: Deps,
  row: AirportRow,
  now: Date,
): Promise<ListItem> {
  try {
    const [dep, arr] = await Promise.all([
      deps.board(row.icao, "departures", now),
      deps.board(row.icao, "arrivals", now),
    ]);
    return {
      icao: row.icao,
      iata: row.iata,
      fetched_at: dep.fetchedAt < arr.fetchedAt ? dep.fetchedAt : arr.fetchedAt,
      stale: dep.stale || arr.stale,
      departures: brief(dep.flights, "departures", now),
      arrivals: brief(arr.flights, "arrivals", now),
      error: null,
    };
  } catch (e) {
    if (!(e instanceof ApiError) || e.code !== "provider_unavailable") throw e;
    return {
      icao: row.icao,
      iata: row.iata,
      fetched_at: null,
      stale: false,
      departures: null,
      arrivals: null,
      error: "provider_unavailable",
    };
  }
}

export async function handler(req: Request, deps: Deps): Promise<Response> {
  try {
    if (req.method !== "GET") {
      throw new ApiError("invalid_request", 405, "GET only");
    }
    const { userId } = await requireUser(req, deps.verifier);
    const now = (deps.now ?? (() => new Date()))();
    const url = new URL(req.url);
    const many = url.searchParams.get("airports");
    const codes = parseCodes(
      many ?? url.searchParams.get("airport"),
      many === null ? 1 : MAX_AIRPORTS,
    );
    // No provider: say so before anything costs a call (the rate limit included).
    if (deps.provider === "none") {
      if (many !== null) {
        return json(
          {
            available: false,
            reason: "no_provider",
            provider: "none",
            airports: [],
          } satisfies List,
        );
      }
      const [row] = inAskedOrder(codes, await deps.airports(codes));
      return json(
        {
          available: false,
          reason: "no_provider",
          provider: "none",
          icao: row?.icao ?? codes[0],
          fetched_at: null,
          stale: false,
          departures: null,
          arrivals: null,
          today: null,
          next_7_days: null,
        } satisfies Detail,
      );
    }
    await deps.rate?.(userId);
    const rows = inAskedOrder(codes, await deps.airports(codes));
    if (many === null) {
      if (rows.length === 0) {
        throw new ApiError(
          "invalid_request",
          400,
          `Unknown airport ${codes[0]}`,
        );
      }
      return json(await detail(deps, rows[0], now));
    }
    const airports = await Promise.all(rows.map((r) => listItem(deps, r, now)));
    return json(
      {
        available: true,
        reason: null,
        provider: deps.provider,
        airports,
      } satisfies List,
    );
  } catch (e) {
    return errorResponse(e);
  }
}
