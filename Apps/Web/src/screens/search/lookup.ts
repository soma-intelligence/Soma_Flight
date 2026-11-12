import { callFunction } from "@/data/api";
import { decodeFlight } from "@/data/decode";
import { useFakes } from "@/data/flights";
import type { Flight } from "@/data/types";
import { airlineCode as rowAirline, designator } from "@/ui/format";
import type { FlightNumber } from "./parse";

/** A local calendar date as the backend reads it: `YYYY-MM-DD` of the day picked, `offset` days from `now`. */
export function dayString(now: Date, offset: number): string {
  const d = new Date(now.getFullYear(), now.getMonth(), now.getDate() + offset);
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
}

/**
 * Every flight with this number around `date` (`flight-lookup`, ident search), sorted as the backend
 * answers. In development with `?fakes=1` it matches the fake flights by airline code and number instead.
 */
export async function lookupFlights(num: FlightNumber, date: string): Promise<Flight[]> {
  const ident = num.airline + num.number;
  if (import.meta.env.DEV && useFakes()) {
    const { fakeFlights } = await import("@/fakes");
    return fakeFlights().filter((f) => {
      const d = designator(f.ident);
      return f.ident === ident || (f.ident.slice(d.length) === num.number && (rowAirline(f) === num.airline || f.operator === num.airline));
    });
  }
  const res = await callFunction<{ flights?: unknown[] }>("flight-lookup", { body: { ident, date } });
  const out: Flight[] = [];
  for (const row of res.flights ?? []) {
    try {
      out.push(decodeFlight(row));
    } catch {
      // one bad row never fails the answer
    }
  }
  return out;
}
