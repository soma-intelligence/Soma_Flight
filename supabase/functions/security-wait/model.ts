// The estimate security-wait gives when no live source covers an airport: wait minutes from the
// passengers a checkpoint usually screens in each hour of the week, through a small queue model. It is a
// model, not a measurement, and every answer built from it says so (live: false).
//
// The queue model, per checkpoint:
// 1. Lanes. TSA does not publish lane counts, so the checkpoint is assumed to have enough standard lanes,
//    each screening LANE_PAX_PER_HOUR, to carry its busiest hour of a typical week at PEAK_OVER_CAPACITY
//    (demand above capacity: TSA staffs for the day, and the sharpest peaks queue), rounded up, so at
//    least one lane. Capacity is lanes times LANE_PAX_PER_HOUR.
// 2. Backlog. Hour by hour through the week, passengers above capacity carry over to the next hour and
//    capacity left over clears them (a fluid queue). Waiting for the backlog is the hour's average backlog
//    over the capacity. The week is run twice from its quietest hour, so Sunday morning sees Saturday
//    night's queue.
// 3. Random arrivals. Even under capacity, queues form: each lane is an M/D/1 queue at the hour's
//    utilisation (capped at MAX_UTILISATION), which waits rho / (2 (1 - rho)) service times, times
//    BUNCHING because passengers arrive in groups and in waves after each check-in rush, not one by one.
// 4. BASE_MINUTES for the walk through the line and the document check.
// The standard wait is the sum, at most MAX_MINUTES. PreCheck lanes wait PRECHECK_SHARE of it. Both are
// rounded to 5 minutes, never below 5: an estimate is not precise to the minute and should not read as
// if it were.
//
// Calibration (docs/data-sources.md): with the TSA throughput of 30 August to 24 October 2026 (591
// checkpoints), checkpoints whose busiest hour passes 1,000 passengers wait 15 to 30 minutes at that hour
// (median 20) and mostly 5 to 10 through the day, small checkpoints mostly 5 to 15 at their peak, and no
// checkpoint passes 35 minutes. That matches TSA's own figures: nearly all passengers wait under 30
// minutes in standard lanes and under 10 in PreCheck.

/** Passengers one standard lane screens in an hour (TSA plans around 150 to 200). */
export const LANE_PAX_PER_HOUR = 150;
/** The busiest hour of a typical week against the lanes' capacity. */
export const PEAK_OVER_CAPACITY = 1.15;
/** Utilisation above which the random-arrivals term stops growing (the backlog takes over). */
export const MAX_UTILISATION = 0.95;
/** How much bunched arrivals lengthen the M/D/1 wait of one-by-one arrivals. */
export const BUNCHING = 3;
/** The walk through the line and the document check, in minutes. */
export const BASE_MINUTES = 4;
/** The longest standard wait the model gives, in minutes. */
export const MAX_MINUTES = 60;
/** PreCheck lanes against standard ones. */
export const PRECHECK_SHARE = 0.35;
/** The busiest hour given to the typical week (the airport-wide fallback), in passengers. */
export const TYPICAL_PEAK_PASSENGERS = 1200;

/**
 * A typical US checkpoint by local hour, 0 to 1: quiet overnight, the first wave of departures from
 * 05:00 to 07:00, a long plateau, a smaller afternoon peak. Used when TSA throughput is not loaded for
 * the airport.
 */
export const TYPICAL_HOURS: readonly number[] = [
  0.05,
  0.03,
  0.03,
  0.08,
  0.45,
  0.9,
  1.0,
  0.85,
  0.7,
  0.6,
  0.6,
  0.62,
  0.65,
  0.6,
  0.62,
  0.7,
  0.72,
  0.65,
  0.55,
  0.45,
  0.35,
  0.25,
  0.15,
  0.08,
];
/** Weekday against the busiest day, Sunday first (as extract(dow)). */
export const TYPICAL_WEEKDAYS: readonly number[] = [
  1.0,
  0.95,
  0.8,
  0.8,
  0.95,
  1.0,
  0.8,
];

/** Rounded to 5 minutes, never below 5. */
export function roundToFive(minutes: number): number {
  return Math.max(5, Math.round(minutes / 5) * 5);
}

/** Standard and PreCheck minutes for an unrounded standard wait. */
export function rounded(
  minutes: number,
): { standard: number; precheck: number } {
  const m = Math.min(
    MAX_MINUTES,
    Math.max(0, Number.isFinite(minutes) ? minutes : 0),
  );
  return {
    standard: roundToFive(m),
    precheck: roundToFive(m * PRECHECK_SHARE),
  };
}

/** The weekday (0 Sunday), hour and minute of `at` on the airport's clock. */
export function localTime(
  at: Date,
  tz: string | null,
): { weekday: number; hour: number; minute: number } {
  const parts = new Intl.DateTimeFormat("en-US", {
    timeZone: tz ?? "UTC",
    weekday: "short",
    hour: "2-digit",
    minute: "2-digit",
    hourCycle: "h23",
  }).formatToParts(at);
  const get = (t: string) => parts.find((p) => p.type === t)?.value ?? "";
  const weekday = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"].indexOf(
    get("weekday"),
  );
  return {
    weekday: Math.max(0, weekday),
    hour: Number(get("hour")) % 24,
    minute: Number(get("minute")),
  };
}

/** One hour of a typical week: [weekday][hour] passengers. */
export type Week = number[][];

/** The standard lanes assumed for a checkpoint whose busiest hour screens `peak` passengers. */
export function lanesFor(peak: number): number {
  return Math.max(
    1,
    Math.ceil(peak / (LANE_PAX_PER_HOUR * PEAK_OVER_CAPACITY)),
  );
}

/**
 * The unrounded standard wait in minutes for every hour of the week, [weekday][hour], by the queue
 * model in the header. An empty week waits BASE_MINUTES everywhere.
 */
export function weekWaits(week: Week): number[][] {
  const flat = Array.from(
    { length: 168 },
    (_, i) => Math.max(0, week[Math.floor(i / 24)]?.[i % 24] ?? 0),
  );
  const peak = Math.max(...flat);
  const out = Array.from({ length: 7 }, () => new Array(24).fill(BASE_MINUTES));
  if (!(peak > 0)) return out;
  const capacity = lanesFor(peak) * LANE_PAX_PER_HOUR;
  const serviceMinutes = 60 / LANE_PAX_PER_HOUR;
  const start = flat.indexOf(Math.min(...flat));
  let backlog = 0;
  for (let lap = 0; lap < 2; lap++) {
    for (let k = 0; k < 168; k++) {
      const i = (start + k) % 168;
      const before = backlog;
      backlog = Math.max(0, before + flat[i] - capacity);
      if (lap === 0) continue;
      const rho = Math.min(MAX_UTILISATION, flat[i] / capacity);
      const queued = ((before + backlog) / 2 / capacity) * 60;
      const random = BUNCHING * serviceMinutes * rho / (2 * (1 - rho));
      out[Math.floor(i / 24)][i % 24] = Math.min(
        MAX_MINUTES,
        BASE_MINUTES + random + queued,
      );
    }
  }
  return out;
}

/**
 * The unrounded standard wait at a local time: the hour's wait blended with the next hour's by the
 * minutes gone.
 */
export function waitAt(
  waits: number[][],
  t: { weekday: number; hour: number; minute: number },
): number {
  const now = waits[t.weekday]?.[t.hour] ?? BASE_MINUTES;
  const nextHour = (t.hour + 1) % 24;
  const nextDay = t.hour === 23 ? (t.weekday + 1) % 7 : t.weekday;
  const next = waits[nextDay]?.[nextHour] ?? BASE_MINUTES;
  const f = t.minute / 60;
  return now * (1 - f) + next * f;
}

/** The typical US week in passengers, for an airport with no throughput loaded. */
export function typicalWeek(): Week {
  return TYPICAL_WEEKDAYS.map((d) =>
    TYPICAL_HOURS.map((h) => Math.round(h * d * TYPICAL_PEAK_PASSENGERS))
  );
}

/** A week from security_throughput rows of one checkpoint; hours with no row count as 0. */
export function weekFromRows(
  rows: { weekday: number; hour: number; passengers: number }[],
): Week {
  const week = Array.from({ length: 7 }, () => new Array(24).fill(0));
  for (const r of rows) {
    if (r.weekday >= 0 && r.weekday < 7 && r.hour >= 0 && r.hour < 24) {
      week[r.weekday][r.hour] = r.passengers;
    }
  }
  return week;
}
