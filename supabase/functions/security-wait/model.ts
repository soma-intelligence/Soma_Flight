// The estimate security-wait gives when no live source covers an airport: wait minutes from how busy a
// checkpoint usually is at this hour. It is a model, not a measurement, and every answer built from it
// says so (live: false).
//
// Load is the passengers a checkpoint usually screens in the hour against its busiest hour of the week
// (0 to 1). Standard lanes wait MIN_MINUTES when the checkpoint is empty and MAX_MINUTES at its weekly
// peak, rising with the load to the power 1.5 (queues grow faster than traffic once lanes fill up).
// PreCheck lanes wait PRECHECK_SHARE of the standard wait. Both are rounded to 5 minutes, never below 5:
// an estimate is not precise to the minute and should not read as if it were.

/** The wait of an empty checkpoint, in minutes. */
export const MIN_MINUTES = 4;
/** The wait at a checkpoint's busiest hour of a typical week, in minutes. */
export const MAX_MINUTES = 28;
/** PreCheck lanes against standard ones. */
export const PRECHECK_SHARE = 0.35;

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

/** Standard and PreCheck minutes for a load (clamped to 0 to 1). */
export function waitForLoad(
  load: number,
): { standard: number; precheck: number } {
  const l = Math.min(1, Math.max(0, Number.isFinite(load) ? load : 0));
  const raw = MIN_MINUTES + (MAX_MINUTES - MIN_MINUTES) * Math.pow(l, 1.5);
  return {
    standard: roundToFive(raw),
    precheck: roundToFive(raw * PRECHECK_SHARE),
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

/** One hour of a typical week: [weekday][hour] passengers (or any relative figure). */
export type Week = number[][];

/**
 * The load at a local time from a week of hourly figures: the hour now blended with the next one by
 * the minutes gone, against the busiest hour of the week. 0 for an empty week.
 */
export function loadAt(
  week: Week,
  t: { weekday: number; hour: number; minute: number },
): number {
  const peak = Math.max(0, ...week.flat());
  if (peak <= 0) return 0;
  const now = week[t.weekday]?.[t.hour] ?? 0;
  const nextHour = (t.hour + 1) % 24;
  const nextDay = t.hour === 23 ? (t.weekday + 1) % 7 : t.weekday;
  const next = week[nextDay]?.[nextHour] ?? 0;
  const f = t.minute / 60;
  return (now * (1 - f) + next * f) / peak;
}

/** The typical US week, for an airport with no throughput loaded. */
export function typicalWeek(): Week {
  return TYPICAL_WEEKDAYS.map((d) => TYPICAL_HOURS.map((h) => h * d));
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
