import { useEffect, useState } from "react";

/** What a row and the card need of an airport: its codes, name, city and IANA zone. */
export type AirportInfo = { icao: string; iata: string | null; name: string; city: string; tz: string | null };
export type AirportDirectory = (icao: string) => AirportInfo | null;

/** Parses the shared reference table (ICAO, IATA, name, city, country, lat, lon, zone; tab separated). */
export function parseAirportInfo(tsv: string): AirportDirectory {
  const at = new Map<string, AirportInfo>();
  for (const line of tsv.split("\n")) {
    const f = line.split("\t");
    if (!f[0]) continue;
    const icao = f[0].toUpperCase();
    at.set(icao, { icao, iata: f[1] || null, name: f[2] ?? "", city: f[3] || f[2] || icao, tz: f[7]?.trim() || null });
  }
  return (icao) => at.get(icao.toUpperCase()) ?? null;
}

const NONE: AirportDirectory = () => null;
let loading: Promise<AirportDirectory> | null = null;
let loaded: AirportDirectory | null = null;

/** The app's airport table (the file the iOS app bundles), fetched once in its own chunk. */
export function loadAirportInfo(): Promise<AirportDirectory> {
  loading ??= import("@flightkit/Reference/airports.tsv?raw").then(
    (m: { default: string }) => (loaded = parseAirportInfo(m.default)),
    (e: unknown) => {
      loading = null;
      throw e;
    },
  );
  return loading;
}

/** The airport directory once loaded; until then every lookup is null (rows show codes and the browser's zone). */
export function useAirports(): AirportDirectory {
  const [dir, setDir] = useState<AirportDirectory>(() => loaded ?? NONE);
  useEffect(() => {
    if (loaded) return;
    let live = true;
    loadAirportInfo().then(
      (d) => live && setDir(() => d),
      () => {},
    );
    return () => {
      live = false;
    };
  }, []);
  return dir;
}
