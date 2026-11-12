import type { Flight, FlightStatus } from "@/data/types";

export type GroupTitle = "In the Air" | "Upcoming" | "Recent";
export type FlightGroup = { title: GroupTitle; rows: Flight[] };

/** How long a finished flight stays in My Flights after its arrival (LandedFlights.grace). */
const GRACE_MS = 60 * 60 * 1000;
const FINISHED: readonly FlightStatus[] = ["arrived", "landed", "canceled", "diverted"];

/** Departed or en route (MyFlightsStore.isLive). */
export function isLive(f: Flight): boolean {
  return f.status === "departed" || f.status === "en_route";
}

/**
 * True once `f` has arrived, landed, been canceled or diverted and its arrival (actual, else estimated,
 * else scheduled) is more than an hour ago (LandedFlights.isOver). A finished flight with no arrival stays.
 */
export function isOver(f: Flight, now: Date): boolean {
  const end = f.actualIn ?? f.actualOn ?? f.estimatedIn ?? f.scheduledIn;
  if (!FINISHED.includes(f.status) || !end) return false;
  return end.getTime() + GRACE_MS < now.getTime();
}

/** Scheduled out, a missing one last (Swift's `.distantFuture`), ties by id (MyFlightsStore.byOut). */
function byOut(a: Flight, b: Flight): number {
  const x = a.scheduledOut?.getTime() ?? Number.POSITIVE_INFINITY;
  const y = b.scheduledOut?.getTime() ?? Number.POSITIVE_INFINITY;
  if (x === y) {
    const p = a.id.toUpperCase();
    const q = b.id.toUpperCase();
    return p < q ? -1 : p > q ? 1 : 0;
  }
  return x < y ? -1 : 1;
}

/**
 * The My Flights groups in order: in the air, upcoming (scheduled or unknown), then recent (landed,
 * arrived, canceled, diverted) until they are over. Empty groups are left out (MyFlightsView.groups
 * without planned flights).
 */
export function groupMyFlights(flights: Flight[], now: Date): FlightGroup[] {
  const live = flights.filter(isLive).sort(byOut);
  const rest = flights.filter((f) => !isLive(f) && !isOver(f, now)).sort(byOut);
  const waiting = (f: Flight) => f.status === "scheduled" || f.status === "unknown";
  const groups: FlightGroup[] = [
    { title: "In the Air", rows: live },
    { title: "Upcoming", rows: rest.filter(waiting) },
    { title: "Recent", rows: rest.filter((f) => !waiting(f)) },
  ];
  return groups.filter((g) => g.rows.length > 0);
}
