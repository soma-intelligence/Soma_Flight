import { greatCircle, type LatLon } from "@/core/flightcore";
import type { Flight } from "@/data/types";
import type { AirportLookup } from "./airports";

export type GlobeContent = {
  routes: LatLon[][];
  planes: { id: string; at: LatLon; heading: number }[];
  airports: { code: string; at: LatLon }[];
};

const SEGMENTS = 64;
/** A position older than this is a plane that has long landed or lost its signal. */
const STALE_MS = 6 * 3600_000;
const OVER = new Set(["landed", "arrived", "canceled"]);

/**
 * What the globe draws for a list of flights: one great-circle route per flight whose two airports are
 * known, a plane for each flight with a fresh position (rotated by its heading), and each known airport once.
 */
export function globeContent(flights: Flight[], now: Date, lookup: AirportLookup): GlobeContent {
  const routes: LatLon[][] = [];
  const planes: GlobeContent["planes"] = [];
  const airports = new Map<string, { code: string; at: LatLon }>();
  for (const f of flights) {
    const from = lookup(f.originIcao);
    const to = lookup(f.destinationIcao);
    if (from && to) {
      routes.push(greatCircle(from, to, SEGMENTS));
      airports.set(f.originIcao, { code: f.originIata ?? f.originIcao, at: from });
      airports.set(f.destinationIcao, { code: f.destinationIata ?? f.destinationIcao, at: to });
    }
    const p = f.position;
    if (p && !OVER.has(f.status) && now.getTime() - p.at.getTime() <= STALE_MS) {
      planes.push({ id: f.id, at: { lat: p.lat, lon: p.lon }, heading: p.heading ?? 0 });
    }
  }
  return { routes, planes, airports: [...airports.values()] };
}
