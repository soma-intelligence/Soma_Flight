// Delay statistics for an airport board. The maths lives in the Rust core (flightcore.ts);
// this file selects the rows that count and maps them into the core's input.
import type { FlightRow } from "./aeroapi.ts";
import {
  type BoardFlight,
  computeStats as coreComputeStats,
  type DelayStats,
} from "./flightcore.ts";

export type { DelayStats, Severity } from "./flightcore.ts";
export type BoardKind = "departures" | "arrivals";

function seconds(iso: string | null): number | null {
  if (!iso) return null;
  const ms = Date.parse(iso);
  return Number.isFinite(ms) ? Math.floor(ms / 1000) : null;
}

type StatsRow = Pick<
  FlightRow,
  | "ident"
  | "operator"
  | "status"
  | "origin_icao"
  | "destination_icao"
  | "scheduled_out"
  | "scheduled_in"
  | "estimated_out"
  | "estimated_in"
  | "actual_out"
  | "actual_in"
>;

/**
 * Departures read the out times and the destination, arrivals the in times and the origin.
 * Null when the row cannot count: no scheduled time, no other airport, or scheduled after `now`.
 */
export function toBoardFlight(
  r: StatsRow,
  kind: BoardKind,
  now: Date,
): BoardFlight | null {
  const dep = kind === "departures";
  const other = dep ? r.destination_icao : r.origin_icao;
  const scheduled = seconds(dep ? r.scheduled_out : r.scheduled_in);
  if (!other || scheduled === null) return null;
  if (scheduled > Math.floor(now.getTime() / 1000)) return null;
  return {
    ident: r.ident,
    operator: r.operator,
    other_icao: other,
    status: r.status,
    scheduled,
    estimated: seconds(dep ? r.estimated_out : r.estimated_in),
    actual: seconds(dep ? r.actual_out : r.actual_in),
  };
}

/**
 * Only flights scheduled at or before `now` count, so flights that have not left yet cannot pass
 * as on time or dilute the cancellation ratio (future canceled flights are excluded too). Rows
 * without a scheduled time or without the other airport are excluded from every figure, so
 * `total` is the number of counted flights. The core's semantics otherwise apply: perHour hours
 * are unix seconds of the UTC hour start (no room for a "scheduled" count, so future flights are
 * omitted), a delay is actual else estimated minus scheduled floored at 0, canceled 10% or more
 * is "major".
 */
export function computeStats(
  rows: StatsRow[],
  kind: BoardKind,
  now: Date,
): DelayStats {
  const counted: BoardFlight[] = [];
  for (const r of rows) {
    const b = toBoardFlight(r, kind, now);
    if (b) counted.push(b);
  }
  return coreComputeStats(counted);
}
