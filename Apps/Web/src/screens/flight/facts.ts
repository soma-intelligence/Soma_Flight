import type { Flight } from "@/data/types";
import { clock, delayLevel, headerDay, ident, span, type DelayLevel } from "@/ui/format";

type Zone = string | null | undefined;

/** "UA 990 · FRI, 30 OCT": the number, then the day it leaves in the origin's zone (DetailFacts.headerLine). */
export function headerLine(f: Flight, originTz: Zone): string {
  const id = ident(f.ident);
  const out = f.scheduledOut ?? f.estimatedOut ?? f.actualOut;
  return out ? `${id} · ${headerDay(out, originTz).toUpperCase()}` : id;
}

const minutesUntil = (to: Date, now: Date) => Math.trunc((to.getTime() - now.getTime()) / 60_000);

/** The countdown card's line (DetailFacts.countdown); a diversion's airport is not known here. */
export function countdown(f: Flight, now: Date): string {
  switch (f.status) {
    case "canceled":
      return "Canceled";
    case "diverted":
      return "Diverted";
    case "landed":
    case "arrived":
      return "Landed";
    case "departed":
    case "en_route": {
      const end = f.actualIn ?? f.estimatedIn ?? f.scheduledIn;
      if (!end) return "In the air";
      const m = minutesUntil(end, now);
      return m < 1 ? "Arriving now" : `Arrives in ${span(m)}`;
    }
    default: {
      const out = f.actualOut ?? f.estimatedOut ?? f.scheduledOut;
      if (!out) return "Scheduled";
      const s = (out.getTime() - now.getTime()) / 1000;
      if (s >= 86_400) {
        const days = Math.floor(s / 86_400);
        return `Departs in ${days} ${days === 1 ? "day" : "days"}`;
      }
      const m = Math.trunc(s / 60);
      return m < 1 ? "Departing now" : `Departs in ${span(m)}`;
    }
  }
}

/** The card's second line: the airline and where the flight stands, "United Airlines · In the air" (DetailFacts.countdownCaption). */
export function countdownCaption(f: Flight, airline: { name: string } | null): string {
  const status = statusWord(f);
  return airline ? `${airline.name} · ${status}` : status;
}

function statusWord(f: Flight): string {
  switch (f.status) {
    case "departed":
      return "Left the gate";
    case "en_route":
      return "In the air";
    case "landed":
      return "Landed";
    case "arrived":
      return "At the gate";
    case "canceled":
      return "Canceled";
    case "diverted":
      return "Diverted";
    default:
      return "Scheduled";
  }
}

function offsetMinutes(scheduled: Date | null, estimated: Date | null, actual: Date | null): number | null {
  const best = actual ?? estimated;
  if (!scheduled || !best) return null;
  return Math.round((best.getTime() - scheduled.getTime()) / 60_000);
}

function offsetWord(m: number | null): string | null {
  if (m === null) return null;
  if (m >= 1) return `${span(m)} Late`;
  if (m <= -1) return `${span(-m)} Early`;
  return "On Time";
}

/** "Arrived 32m Early", "Landed 3m Late"; null before landing (DetailFacts.landedTitle). */
export function landedTitle(f: Flight): string | null {
  if (f.status !== "landed" && f.status !== "arrived") return null;
  const word = offsetWord(offsetMinutes(f.scheduledIn, f.estimatedIn, f.actualIn ?? f.actualOn));
  return word ? `${f.status === "arrived" ? "Arrived" : "Landed"} ${word}` : null;
}

const KM_PER_MILE = 1.609_344;

/** "8,965 km" or "5,571 mi" (TravelFacts.distance), grouped the en-US way. */
export function distanceText(km: number, unit: "km" | "mi" = "km"): string {
  const value = unit === "km" ? km : Math.round(km / KM_PER_MILE);
  return `${value.toLocaleString("en-US")} ${unit}`;
}

/**
 * "Total 10h 50m · 8,965 km": gate to gate and the distance between the airports (whole km), for a flight
 * that is down (DetailFacts.landedCaption); parts drop out when unknown, null when nothing is known.
 */
export function landedCaption(f: Flight, km: number | null, unit: "km" | "mi" = "km"): string | null {
  const parts: string[] = [];
  const out = f.actualOut ?? f.estimatedOut ?? f.scheduledOut;
  const arr = f.actualIn ?? f.estimatedIn ?? f.scheduledIn;
  if (out && arr && arr > out) parts.push(`Total ${span(Math.trunc((arr.getTime() - out.getTime()) / 60_000))}`);
  if (km !== null) parts.push(distanceText(km, unit));
  return parts.length ? parts.join(" · ") : null;
}

/** Green early or on time, red late, once in the air with an arrival to measure; else none (DetailFacts.statusTone). */
export function statusTone(f: Flight): "on-time" | "very-late" | null {
  if (!["departed", "en_route", "landed", "arrived"].includes(f.status)) return null;
  const m = offsetMinutes(f.scheduledIn, f.estimatedIn, f.actualIn ?? f.actualOn);
  if (m === null) return null;
  return m >= 1 ? "very-late" : "on-time";
}

export type TimetableRow = {
  section: "depart" | "arrive" | "totals";
  title: string;
  scheduled: string;
  other: string;
  otherLabel: "Actual" | "Estimated";
  level: DelayLevel | null;
};

const UNKNOWN = "--";
type Point = { date: Date; actual: boolean };
const best = (actual: Date | null, estimated: Date | null): Point | null =>
  actual ? { date: actual, actual: true } : estimated ? { date: estimated, actual: false } : null;

function wholeMinutes(a: Date | null | undefined, b: Date | null | undefined): number | null {
  if (!a || !b || b < a) return null;
  return Math.round((b.getTime() - a.getTime()) / 60_000);
}

/**
 * The detailed timetable (Timetable.rows): gate and runway times in their airport's zone, the spans between.
 * With `zonesKnown` false (the airport table is not in yet) known times read "--:--" rather than the
 * browser's zone; the spans do not depend on a zone.
 */
export function timetableRows(
  f: Flight,
  originTz: Zone,
  destinationTz: Zone,
  twelveHour = false,
  zonesKnown = true,
): TimetableRow[] {
  const at = (d: Date, tz: Zone) => (zonesKnown ? clock(d, tz, twelveHour) : "--:--");
  const out = best(f.actualOut, f.estimatedOut);
  const off = best(f.actualOff, f.estimatedOff);
  const on = best(f.actualOn, f.estimatedOn);
  const inn = best(f.actualIn, f.estimatedIn);

  const time = (section: TimetableRow["section"], title: string, scheduled: Date | null, other: Point | null, tz: Zone): TimetableRow => ({
    section,
    title,
    scheduled: scheduled ? at(scheduled, tz) : UNKNOWN,
    other: other ? at(other.date, tz) : UNKNOWN,
    otherLabel: other?.actual ? "Actual" : "Estimated",
    level: zonesKnown && scheduled && other ? delayLevel(other.date.getTime() - scheduled.getTime(), "scheduled") : null,
  });
  const spanRow = (
    section: TimetableRow["section"],
    title: string,
    s: [Date | null, Date | null],
    o: [Point | null, Point | null],
  ): TimetableRow => {
    const sm = wholeMinutes(s[0], s[1]);
    const om = wholeMinutes(o[0]?.date, o[1]?.date);
    return {
      section,
      title,
      scheduled: sm === null ? UNKNOWN : span(sm),
      other: om === null ? UNKNOWN : span(om),
      otherLabel: o[0]?.actual && o[1]?.actual ? "Actual" : "Estimated",
      level: null,
    };
  };

  return [
    time("depart", "Gate Departure", f.scheduledOut, out, originTz),
    spanRow("depart", "Taxi", [f.scheduledOut, f.scheduledOff], [out, off]),
    time("depart", "Take Off", f.scheduledOff, off, originTz),
    time("arrive", "Land", f.scheduledOn, on, destinationTz),
    spanRow("arrive", "Taxi", [f.scheduledOn, f.scheduledIn], [on, inn]),
    time("arrive", "Gate Arrival", f.scheduledIn, inn, destinationTz),
    spanRow("totals", "Air Time", [f.scheduledOff, f.scheduledOn], [off, on]),
    spanRow("totals", "Total Time", [f.scheduledOut, f.scheduledIn], [out, inn]),
  ];
}

/** Fraction of the trip elapsed from the best known times, 0...1 (Flight.progress(at:)). */
export function progress(f: Flight, now: Date): number {
  const start = f.actualOff ?? f.actualOut ?? f.estimatedOut ?? f.scheduledOut;
  const end = f.actualIn ?? f.actualOn ?? f.estimatedIn ?? f.scheduledIn;
  if (!start || !end || end <= start) return 0;
  const p = (now.getTime() - start.getTime()) / (end.getTime() - start.getTime());
  return Math.min(1, Math.max(0, p));
}

export type Estimate = { reason: "offline" | "stale"; progress: number; lastUpdate: Date; probablyLanded: boolean };

/** An update older than this, in the air, is no longer live (FlightEstimate.staleAfter). */
const STALE_MS = 5 * 60_000;

/**
 * Where a flight probably is when the app cannot hear about it (FlightEstimate.make, without the map
 * position): in the air and offline, or online with no update for five minutes. Null otherwise.
 */
export function estimate(f: Flight, now: Date, online: boolean): Estimate | null {
  switch (f.status) {
    case "departed":
    case "en_route":
      break;
    case "scheduled":
    case "unknown": {
      const out = f.actualOut ?? f.estimatedOut ?? f.scheduledOut;
      const inn = f.estimatedIn ?? f.scheduledIn;
      if (online || !out || out > now || !inn || now.getTime() >= inn.getTime() + 3 * 3600_000) return null;
      break;
    }
    default:
      return null;
  }
  const lastUpdate = new Date(Math.max(f.updatedAt.getTime(), f.position?.at.getTime() ?? 0));
  const stale = now.getTime() - lastUpdate.getTime() > STALE_MS;
  if (online && !stale) return null;
  const due = f.actualOn ?? f.estimatedOn ?? f.estimatedIn ?? f.scheduledIn;
  return {
    reason: online ? "stale" : "offline",
    progress: progress(f, now),
    lastUpdate,
    probablyLanded: due ? now >= due : false,
  };
}

/** One line under the estimate: what it rests on (FlightEstimate.detail). */
export function estimateDetail(e: Estimate): string {
  if (e.probablyLanded) return "Probably landed. Times and gates will update when you are back online.";
  return e.reason === "offline"
    ? "No connection. Progress is worked out from the last known times."
    : "No live update for a while. Progress is worked out from the last known times.";
}
