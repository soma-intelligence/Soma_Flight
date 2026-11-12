import type { LatLon } from "@/core/flightcore";

/** Where an airport is, by ICAO code; null when the directory does not know it. */
export type AirportLookup = (icao: string) => LatLon | null;

/** Parses the shared reference table (ICAO, IATA, name, city, country, lat, lon, zone; tab separated). */
export function parseAirports(tsv: string): AirportLookup {
  const at = new Map<string, LatLon>();
  for (const line of tsv.split("\n")) {
    const f = line.split("\t");
    const lat = Number(f[5]);
    const lon = Number(f[6]);
    if (f[0] && f[5] !== "" && f[6] !== "" && Number.isFinite(lat) && Number.isFinite(lon)) {
      at.set(f[0].toUpperCase(), { lat, lon });
    }
  }
  return (icao) => at.get(icao.toUpperCase()) ?? null;
}

let loading: Promise<AirportLookup> | null = null;

/** The app's airport table (the same file the iOS app bundles), fetched once, in its own chunk. */
export function loadAirports(): Promise<AirportLookup> {
  loading ??= import("@flightkit/Reference/airports.tsv?raw").then(
    (m: { default: string }) => parseAirports(m.default),
    (e: unknown) => {
      loading = null;
      throw e;
    },
  );
  return loading;
}
