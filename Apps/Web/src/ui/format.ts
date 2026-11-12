import type { Flight, FlightStatus } from "@/data/types";

/**
 * The display formatters the My Flights row and the flight card use, after UI/Format.swift,
 * FlightActivityDisplay and DetailFacts in FlightKit. English only, like the app. A zone of null reads
 * in the browser's zone (the app's `.current`).
 */

type Zone = string | null | undefined;

function parts(date: Date, tz: Zone): Record<string, string> {
  const f = new Intl.DateTimeFormat("en-US", {
    timeZone: tz ?? undefined,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    hourCycle: "h23",
  });
  const out: Record<string, string> = {};
  for (const p of f.formatToParts(date)) out[p.type] = p.value;
  return out;
}

function safeZone(tz: Zone): Zone {
  if (!tz) return null;
  try {
    new Intl.DateTimeFormat("en-US", { timeZone: tz });
    return tz;
  } catch {
    return null;
  }
}

/** "18:25" in `tz`, or "6:25 PM" with `twelveHour`; "--:--" when unknown. */
export function clock(date: Date | null, tz: Zone, twelveHour = false): string {
  if (!date) return "--:--";
  const p = parts(date, safeZone(tz));
  const h = Number(p.hour) % 24;
  const m = p.minute;
  if (!twelveHour) return `${String(h).padStart(2, "0")}:${m}`;
  return `${h % 12 === 0 ? 12 : h % 12}:${m} ${h < 12 ? "AM" : "PM"}`;
}

/** "2h 37m", "50m", "2h". */
export function duration(total: number): string {
  const m = Math.abs(total);
  const h = Math.floor(m / 60);
  const r = m % 60;
  if (h === 0) return `${r}m`;
  return r === 0 ? `${h}h` : `${h}h ${r}m`;
}

/** "10h 55m", "3h 05m", "12m": hours and zero-padded minutes (DetailFacts.span). */
export function span(total: number): string {
  const m = Math.max(total, 0);
  const h = Math.floor(m / 60);
  const r = m % 60;
  return h === 0 ? `${r}m` : `${h}h ${r < 10 ? "0" : ""}${r}m`;
}

const isLetter = (c: string) => /\p{L}/u.test(c);

/** "AA 2178", "B6 717", "EJM 444": airline code, space, number. */
export function ident(raw: string): string {
  const chars = Array.from(raw);
  if (chars.length <= 2) return raw;
  const split = isLetter(chars[2]) ? 3 : 2;
  if (split >= chars.length) return raw;
  return chars.slice(0, split).join("") + " " + chars.slice(split).join("");
}

/** "AF" from "AF84", "B6" from "B6417" (TravelFacts.airlineCode). */
export function designator(raw: string): string {
  const chars = Array.from(raw);
  if (chars.length <= 2) return raw;
  return chars.slice(0, isLetter(chars[2]) ? 3 : 2).join("");
}

const IATA_OF: Record<string, string> = {
  AAL: "AA", UAL: "UA", DAL: "DL", SWA: "WN", ASA: "AS", JBU: "B6", AFR: "AF", BAW: "BA", NKS: "NK", FFT: "F9",
};

/** The short airline code a row shows: IATA where known, else the ICAO operator, else the number's prefix. */
export function airlineCode(f: Pick<Flight, "operator" | "ident">): string {
  return f.operator ? (IATA_OF[f.operator] ?? f.operator) : designator(f.ident);
}

export const originCode = (f: Flight) => f.originIata ?? f.originIcao;
export const destinationCode = (f: Flight) => f.destinationIata ?? f.destinationIcao;

/** Departure and arrival as best known: actual, else estimated, else scheduled gate times. */
export const bestOut = (f: Flight) => f.actualOut ?? f.estimatedOut ?? f.scheduledOut;
export const bestIn = (f: Flight) => f.actualIn ?? f.estimatedIn ?? f.scheduledIn;

/** Days since the epoch of the local date `date` falls on in `tz`. */
function localDay(date: Date, tz: Zone): number {
  const p = parts(date, safeZone(tz));
  return Math.floor(Date.UTC(Number(p.year), Number(p.month) - 1, Number(p.day)) / 86_400_000);
}

/** "+1", "+2", "-1": the arrival's local date against the departure's, each in its own zone; null on the same date. */
export function dayMarker(departure: Date, depTz: Zone, arrival: Date, arrTz: Zone): string | null {
  const days = localDay(arrival, arrTz) - localDay(departure, depTz);
  if (days === 0) return null;
  return days > 0 ? `+${days}` : `${days}`;
}

/** "Fri, Oct 30": the day it leaves as best known, in the origin's zone (MyFlightRow.day). */
export function rowDay(f: Flight, originTz: Zone): string | null {
  const out = bestOut(f);
  if (!out) return null;
  return new Intl.DateTimeFormat("en-US", {
    timeZone: safeZone(originTz) ?? undefined,
    weekday: "short",
    month: "short",
    day: "numeric",
  }).format(out);
}

/** The arrival's day marker on a row (MyFlightRow.marker). */
export function rowMarker(f: Flight, originTz: Zone, destinationTz: Zone): string | null {
  const out = bestOut(f);
  const arr = bestIn(f);
  if (!out || !arr) return null;
  return dayMarker(out, originTz, arr, destinationTz);
}

/** "FRI, 30 OCT" style day for the card header: "Fri, 30 Oct" in `tz` (DetailFacts.headerDay). */
export function headerDay(date: Date, tz: Zone): string {
  const p = new Intl.DateTimeFormat("en-US", {
    timeZone: safeZone(tz) ?? undefined,
    weekday: "short",
    day: "numeric",
    month: "short",
  }).formatToParts(date);
  const get = (t: string) => p.find((x) => x.type === t)?.value ?? "";
  return `${get("weekday")}, ${get("day")} ${get("month")}`;
}

/**
 * The big figure and the word under it at the start of a row (DetailFacts.countdownColumn): time to the
 * gate departure, time left in the air, or a word with no figure. Whole units, rounded down.
 */
export function countdownColumn(f: Flight, now: Date): { value: string; unit: string } {
  switch (f.status) {
    case "canceled":
      return { value: "", unit: "CANCELED" };
    case "diverted":
      return { value: "", unit: "DIVERTED" };
    case "landed":
    case "arrived":
      return { value: "", unit: "LANDED" };
    case "departed":
    case "en_route": {
      const end = bestIn(f);
      if (!end) return { value: "", unit: "IN AIR" };
      const m = Math.trunc((end.getTime() - now.getTime()) / 60_000);
      if (m < 1) return { value: "", unit: "ARRIVING" };
      return { value: m >= 60 ? `${Math.floor(m / 60)}h` : `${m}m`, unit: "LEFT" };
    }
    default: {
      const out = bestOut(f);
      if (!out) return { value: "", unit: "SCHEDULED" };
      const s = (out.getTime() - now.getTime()) / 1000;
      if (s < 60) return { value: "", unit: "DEPARTING" };
      if (s >= 86_400) {
        const d = Math.floor(s / 86_400);
        return { value: `${d}`, unit: d === 1 ? "DAY" : "DAYS" };
      }
      if (s >= 3600) {
        const h = Math.floor(s / 3600);
        return { value: `${h}`, unit: h === 1 ? "HR" : "HRS" };
      }
      return { value: `${Math.floor(s / 60)}`, unit: "MIN" };
    }
  }
}

export type DelayLevel = "on-time" | "late" | "very-late" | "canceled" | "diverted";

/** On time under 15 min, late 15 to 44, very late 45 or more; canceled and diverted win. Delay in ms. */
export function delayLevel(delayMs: number | null, status: FlightStatus): DelayLevel {
  if (status === "canceled") return "canceled";
  if (status === "diverted") return "diverted";
  if (delayMs === null) return "on-time";
  const m = Math.trunc(delayMs / 60_000);
  if (m >= 45) return "very-late";
  if (m >= 15) return "late";
  return "on-time";
}

/** The theme token for a level. */
export const LEVEL_COLOR: Record<DelayLevel, string> = {
  "on-time": "var(--sf-on-time)",
  late: "var(--sf-late)",
  "very-late": "var(--sf-very-late)",
  canceled: "var(--sf-canceled)",
  diverted: "var(--sf-diverted)",
};
