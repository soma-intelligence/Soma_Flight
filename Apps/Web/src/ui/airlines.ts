import { useEffect, useState } from "react";
import type { Flight } from "@/data/types";
import { designator } from "./format";

/** What the screens need of an airline: its codes and name. */
export type Airline = { icao: string; iata: string | null; name: string };
export type AirlineDirectory = ((code: string) => Airline | null) & {
  /** The code flight numbers use (IATA, else ICAO) of the airline named by `phrase`: its whole name, or the name without a generic tail ("delta"). */
  named(phrase: string): string | null;
};

type Row = { icao?: unknown; iata?: unknown; name?: unknown };

/** Lower case, accents and apostrophes dropped, anything else but letters and digits a space (SearchText.fold). */
export function fold(s: string): string {
  return s
    .normalize("NFD")
    .replace(/\p{M}/gu, "")
    .replace(/['\u2019]/g, "")
    .toLowerCase()
    .replace(/[^\p{L}\p{N}]+/gu, " ")
    .trim();
}

/** Generic tails an airline is often named without (SearchSuggester.airlineTails). */
const TAILS = [" air lines", " airlines", " airline", " airways"];

/** The shared airline table (airlines.json), keyed by ICAO and IATA code, any case (ReferenceData.airline). */
export function parseAirlines(rows: readonly Row[]): AirlineDirectory {
  const byCode = new Map<string, Airline>();
  const byIata = new Map<string, Airline>();
  const exact = new Map<string, string>();
  const short = new Map<string, string>();
  for (const r of rows) {
    if (typeof r.icao !== "string" || r.icao === "" || typeof r.name !== "string") continue;
    const a: Airline = { icao: r.icao.toUpperCase(), iata: typeof r.iata === "string" && r.iata ? r.iata.toUpperCase() : null, name: r.name };
    byCode.set(a.icao, a);
    if (a.iata && !byIata.has(a.iata)) byIata.set(a.iata, a);
    const name = fold(a.name);
    if (!name) continue;
    const code = a.iata ?? a.icao;
    if (!exact.has(name)) exact.set(name, code);
    const tail = TAILS.find((t) => name.endsWith(t));
    const bare = tail ? name.slice(0, -tail.length) : "";
    if (bare && !short.has(bare)) short.set(bare, code);
  }
  const dir = (code: string): Airline | null => {
    const k = code.trim().toUpperCase();
    if (!k) return null;
    return byCode.get(k) ?? byIata.get(k) ?? null;
  };
  return Object.assign(dir, {
    named(phrase: string): string | null {
      const q = fold(phrase);
      return q ? (exact.get(q) ?? short.get(q) ?? null) : null;
    },
  });
}

/** A flight's airline: by its operator, else by its number's designator ("UA" of "UA990"). */
export function airlineOf(f: Pick<Flight, "operator" | "ident">, dir: AirlineDirectory): Airline | null {
  return (f.operator ? dir(f.operator) : null) ?? dir(designator(f.ident));
}

const NONE: AirlineDirectory = Object.assign((): Airline | null => null, { named: (): string | null => null });
let loading: Promise<AirlineDirectory> | null = null;
let loaded: AirlineDirectory | null = null;

/** The app's airline table (the file the iOS app bundles), fetched once in its own chunk. */
export function loadAirlines(): Promise<AirlineDirectory> {
  loading ??= import("@flightkit/Reference/airlines.json").then(
    (m: { default: readonly Row[] }) => (loaded = parseAirlines(m.default)),
    (e: unknown) => {
      loading = null;
      throw e;
    },
  );
  return loading;
}

/** The airline directory once loaded; until then every lookup is null (marks show the flight's own code). */
export function useAirlines(): AirlineDirectory {
  const [dir, setDir] = useState<AirlineDirectory>(() => loaded ?? NONE);
  useEffect(() => {
    if (loaded) {
      if (dir !== loaded) setDir(() => loaded!);
      return;
    }
    let live = true;
    loadAirlines().then(
      (d) => live && setDir(() => d),
      () => {},
    );
    return () => {
      live = false;
    };
  }, []); // eslint-disable-line react-hooks/exhaustive-deps
  return dir;
}
