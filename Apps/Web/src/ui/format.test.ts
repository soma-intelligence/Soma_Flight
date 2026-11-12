import { describe, expect, it } from "vitest";
import type { Flight } from "@/data/types";
import { ua990 } from "./testFlight";
import {
  clock,
  countdownColumn,
  dayMarker,
  delayLevel,
  duration,
  ident,
  rowDay,
  rowMarker,
  span,
} from "./format";

const d = (s: string) => new Date(s);
const SFO = "America/Los_Angeles";
const CDG = "Europe/Paris";
const HND = "Asia/Tokyo";

describe("format", () => {
  // ScreenReviewFixTests.clockStyles
  it("clock reads the time in the zone, 24 or 12 hour", () => {
    expect(clock(d("2026-10-28T00:05:00Z"), "UTC")).toBe("00:05");
    expect(clock(d("2026-10-28T00:05:00Z"), "UTC", true)).toBe("12:05 AM");
    expect(clock(d("2026-10-28T12:00:00Z"), "UTC", true)).toBe("12:00 PM");
    expect(clock(d("2026-10-28T18:25:00Z"), "UTC", true)).toBe("6:25 PM");
    expect(clock(d("2026-10-28T18:25:00Z"), "UTC")).toBe("18:25");
    expect(clock(d("2026-10-28T23:59:00Z"), "America/Chicago", true)).toBe("6:59 PM");
    expect(clock(null, "UTC")).toBe("--:--");
  });

  // FlightActivityDisplay.duration and ident
  it("duration and ident", () => {
    expect(duration(157)).toBe("2h 37m");
    expect(duration(50)).toBe("50m");
    expect(duration(120)).toBe("2h");
    expect(ident("AA2178")).toBe("AA 2178");
    expect(ident("B6717")).toBe("B6 717");
    expect(ident("EJM444")).toBe("EJM 444");
    expect(ident("UA")).toBe("UA");
  });

  // DetailPart2Tests timetable spans
  it("span pads minutes after hours", () => {
    expect(span(607)).toBe("10h 07m");
    expect(span(33)).toBe("33m");
    expect(span(-5)).toBe("0m");
  });

  // DetailPart1Tests.dayMarkerAcrossDateLine and dayMarkerOnClockChangeDays
  it("day marker reads each side in its own zone", () => {
    const f = ua990();
    expect(dayMarker(f.scheduledOut!, SFO, f.scheduledIn!, CDG)).toBe("+1");
    const dep = d("2026-10-30T15:30:00Z");
    const arr = d("2026-10-30T23:30:00Z");
    expect(dayMarker(dep, HND, arr, SFO)).toBe("-1");
    expect(dayMarker(dep, "UTC", arr, "UTC")).toBeNull();
    expect(dayMarker(d("2026-10-30T06:30:00Z"), SFO, d("2026-10-30T21:30:00Z"), "Australia/Sydney")).toBe("+2");
    expect(dayMarker(d("2026-10-30T16:00:00Z"), SFO, d("2026-10-30T19:00:00Z"), SFO)).toBeNull();
    expect(dayMarker(d("2026-11-01T06:30:00Z"), SFO, d("2026-11-01T09:30:00Z"), SFO)).toBe("+1");
    expect(dayMarker(d("2026-11-01T08:30:00Z"), SFO, d("2026-11-01T09:10:00Z"), SFO)).toBeNull();
    expect(dayMarker(d("2026-10-24T21:00:00Z"), CDG, d("2026-10-24T23:30:00Z"), "Europe/London")).toBe("+1");
    expect(dayMarker(d("2026-10-24T23:30:00Z"), CDG, d("2026-10-25T01:45:00Z"), "Europe/London")).toBeNull();
  });

  // MyFlightRowTests.countdownColumnCases
  it("countdown column cases", () => {
    const f = ua990();
    const out = f.scheduledOut!.getTime();
    const arr = f.scheduledIn!.getTime();
    const col = (g: Flight, now: number) => {
      const c = countdownColumn(g, new Date(now));
      return `${c.value}|${c.unit}`;
    };
    expect(col(f, out - 86_400_000)).toBe("1|DAY");
    expect(col(f, out - 47 * 3600_000)).toBe("1|DAY");
    expect(col(f, out - (3 * 86_400 + 60) * 1000)).toBe("3|DAYS");
    expect(col(f, out - (5 * 3600 + 59) * 1000)).toBe("5|HRS");
    expect(col(f, out - 3600_000)).toBe("1|HR");
    expect(col(f, out - (40 * 60 + 10) * 1000)).toBe("40|MIN");
    expect(col(f, out - 90_000)).toBe("1|MIN");
    expect(col(f, out + 30_000)).toBe("|DEPARTING");
    expect(col(ua990({ scheduledOut: null }), out)).toBe("|SCHEDULED");

    const air = ua990({ status: "en_route", actualOut: f.scheduledOut });
    expect(col(air, arr - (2 * 3600 + 300) * 1000)).toBe("2h|LEFT");
    expect(col(air, arr - 40 * 60_000)).toBe("40m|LEFT");
    expect(col(air, arr + 60_000)).toBe("|ARRIVING");
    expect(col({ ...air, scheduledIn: null }, out)).toBe("|IN AIR");

    for (const [status, word] of [
      ["landed", "LANDED"],
      ["arrived", "LANDED"],
      ["canceled", "CANCELED"],
      ["diverted", "DIVERTED"],
    ] as const) {
      expect(col(ua990({ status }), out)).toBe(`|${word}`);
    }
  });

  // MyFlightRowTests.rowDateAndTimes
  it("row day and arrival marker", () => {
    const f = ua990();
    expect(rowDay(f, SFO)).toBe("Fri, Oct 30");
    expect(rowMarker(f, SFO, CDG)).toBe("+1");
    expect(rowDay(ua990({ estimatedOut: d("2026-10-31T08:30:00Z") }), SFO)).toBe("Sat, Oct 31");
    const short = ua990({ scheduledIn: new Date(f.scheduledOut!.getTime() + 2 * 3600_000) });
    expect(rowMarker(short, SFO, SFO)).toBeNull();
  });

  // DelayColorTests
  it("delay level thresholds", () => {
    const m = (x: number) => x * 60_000;
    expect(delayLevel(null, "scheduled")).toBe("on-time");
    expect(delayLevel(m(10), "departed")).toBe("on-time");
    expect(delayLevel(m(20), "en_route")).toBe("late");
    expect(delayLevel(m(50), "scheduled")).toBe("very-late");
    expect(delayLevel(m(50), "canceled")).toBe("canceled");
    expect(delayLevel(null, "diverted")).toBe("diverted");
    expect(delayLevel(m(14) + 59_000, "scheduled")).toBe("on-time");
    expect(delayLevel(m(15), "scheduled")).toBe("late");
    expect(delayLevel(m(44) + 59_000, "scheduled")).toBe("late");
    expect(delayLevel(m(45), "scheduled")).toBe("very-late");
    expect(delayLevel(m(-5), "scheduled")).toBe("on-time");
  });
});

