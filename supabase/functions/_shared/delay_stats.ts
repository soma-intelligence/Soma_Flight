// Delay statistics for an airport board. The maths lives in the Rust core (flightcore.ts);
// this file only maps board rows into the core's input.
import type { FlightRow } from "./aeroapi.ts";
import {
  type BoardFlight,
  computeStats as coreComputeStats,
  type DelayStats,
} from "./flightcore.ts";

export type { DelayStats, Severity } from "./flightcore.ts";
export type BoardKind = "departures" | "arrivals";

const UNKNOWN_AIRPORT = "UNKN";

function seconds(iso: string | null): number | null {
  if (!iso) return null;
  const ms = Date.parse(iso);
  return Number.isFinite(ms) ? Math.floor(ms / 1000) : null;
}

/** Departures read the out times and the destination, arrivals the in times and the origin. */
export function toBoardFlight(r: FlightRow, kind: BoardKind): BoardFlight {
  const dep = kind === "departures";
  return {
    ident: r.ident,
    operator: r.operator,
    other_icao: (dep ? r.destination_icao : r.origin_icao) ?? UNKNOWN_AIRPORT,
    status: r.status,
    scheduled: seconds(dep ? r.scheduled_out : r.scheduled_in),
    estimated: seconds(dep ? r.estimated_out : r.estimated_in),
    actual: seconds(dep ? r.actual_out : r.actual_in),
  };
}

/**
 * Core semantics apply, not the plan's draft: hour buckets are unix seconds (UTC hour start),
 * a delay is actual else estimated minus scheduled floored at 0, canceled flights are 10% or
 * more of the board means "major", rows without a scheduled time are skipped, and `total` counts
 * every row given.
 */
export function computeStats(rows: FlightRow[], kind: BoardKind): DelayStats {
  return coreComputeStats(rows.map((r) => toBoardFlight(r, kind)));
}
