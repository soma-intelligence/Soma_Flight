import { useEffect, useState } from "react";

/** What a row and the card need of an airport: its codes, name, city and IANA zone. */
export type AirportInfo = {
  icao: string;
  iata: string | null;
  name: string;
  city: string;
  tz: string | null;
  lat: number | null;
  lon: number | null;
};
export type AirportDirectory = (icao: string) => AirportInfo | null;

/** Parses the shared reference table (ICAO, IATA, name, city, country, lat, lon, zone; tab separated). */
export function parseAirportInfo(tsv: string): AirportDirectory {
  const at = new Map<string, AirportInfo>();
  for (const line of tsv.split("\n")) {
    const f = line.split("\t");
    if (!f[0]) continue;
    const icao = f[0].toUpperCase();
    const lat = f[5] ? Number(f[5]) : NaN;
    const lon = f[6] ? Number(f[6]) : NaN;
    at.set(icao, {
      icao,
      iata: f[1] || null,
      name: f[2] ?? "",
      city: f[3] || f[2] || icao,
      tz: f[7]?.trim() || null,
      lat: Number.isFinite(lat) ? lat : null,
      lon: Number.isFinite(lon) ? lon : null,
    });
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

/** True once `dir` is the loaded table, not the empty stand-in: times can be read in the airports' zones. */
export function airportsReady(dir: AirportDirectory): boolean {
  return dir !== NONE;
}

/** The airport directory once loaded; until then every lookup is null (rows show codes and "--:--"). */
export function useAirports(): AirportDirectory {
  const [dir, setDir] = useState<AirportDirectory>(() => loaded ?? NONE);
  useEffect(() => {
    if (loaded) {
      if (dir !== loaded) setDir(() => loaded!);
      return;
    }
    let live = true;
    loadAirportInfo().then(
      (d) => live && setDir(() => d),
      () => {},
    );
    return () => {
      live = false;
    };
  }, []); // eslint-disable-line react-hooks/exhaustive-deps
  return dir;
}
