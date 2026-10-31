// The queue model and local-time helpers (model.ts): pure functions, no database.
import { assert, assertAlmostEquals, assertEquals } from "jsr:@std/assert@1";
import {
  BASE_MINUTES,
  BUNCHING,
  LANE_PAX_PER_HOUR,
  lanesFor,
  localTime,
  MAX_MINUTES,
  PEAK_OVER_CAPACITY,
  rounded,
  roundToFive,
  TYPICAL_PEAK_PASSENGERS,
  typicalWeek,
  waitAt,
  weekFromRows,
  weekWaits,
} from "./model.ts";

// Tuesday 3 November 2026, 07:30 in San Francisco (PST) and 09:30 in Austin (CST): the morning rush.
const NOW = new Date("2026-11-03T15:30:00Z");

Deno.test("waits round to five minutes, never below five, never above the cap", () => {
  assertEquals([0, 2, 2.4, 2.5, 7.4, 7.6, 31].map(roundToFive), [
    5,
    5,
    5,
    5,
    5,
    10,
    30,
  ]);
  assertEquals(rounded(0), { standard: 5, precheck: 5 });
  assertEquals(rounded(24), { standard: 25, precheck: 10 });
  assertEquals(rounded(500), rounded(MAX_MINUTES));
  assertEquals(rounded(-1), rounded(0));
  assertEquals(rounded(Number.NaN), rounded(0));
});

Deno.test("lanes carry the busiest hour a little over capacity", () => {
  assertEquals(lanesFor(0), 1);
  assertEquals(lanesFor(100), 1);
  // 1,380 passengers at 150 a lane and 1.15 over capacity: exactly 8 lanes; one more passenger is 9.
  assertEquals(LANE_PAX_PER_HOUR * PEAK_OVER_CAPACITY * 8, 1380);
  assertEquals(lanesFor(1380), 8);
  assertEquals(lanesFor(1381), 9);
});

Deno.test("the queue builds over a busy morning and clears after it", () => {
  // One checkpoint with 8 lanes (1,200 an hour): a Tuesday morning over capacity, quiet otherwise.
  const week = weekFromRows([
    { weekday: 2, hour: 5, passengers: 1300 },
    { weekday: 2, hour: 6, passengers: 1380 },
    { weekday: 2, hour: 7, passengers: 1300 },
    { weekday: 2, hour: 8, passengers: 600 },
    { weekday: 2, hour: 12, passengers: 600 },
  ]);
  const w = weekWaits(week);
  const service = 60 / LANE_PAX_PER_HOUR;
  const random = (rho: number) => BUNCHING * service * rho / (2 * (1 - rho));
  // 05:00: 100 over capacity, average backlog 50 over 1,200 an hour.
  assertAlmostEquals(
    w[2][5],
    BASE_MINUTES + random(0.95) + (50 / 1200) * 60,
  );
  // 07:00: the backlog went from 280 to 380 passengers.
  assertAlmostEquals(
    w[2][7],
    BASE_MINUTES + random(0.95) + (330 / 1200) * 60,
  );
  // 08:00 clears it (600 under capacity): from 380 to 0.
  assertAlmostEquals(
    w[2][8],
    BASE_MINUTES + random(0.5) + (190 / 1200) * 60,
  );
  // The same 600 at noon, with nothing queued, waits less.
  assertAlmostEquals(w[2][12], BASE_MINUTES + random(0.5));
  assert(w[2][7] > w[2][6] && w[2][6] > w[2][5] && w[2][8] < w[2][7]);
  // An empty hour waits the base.
  assertEquals(w[3][3], BASE_MINUTES);
  // Every hour of an empty week waits the base too.
  assert(weekWaits(weekFromRows([])).flat().every((m) => m === BASE_MINUTES));
});

Deno.test("Saturday night's queue carries into Sunday morning", () => {
  const sunday = { weekday: 0, hour: 0, passengers: 100 };
  const busy = weekWaits(weekFromRows([
    { weekday: 6, hour: 23, passengers: 1380 },
    sunday,
  ]));
  const quiet = weekWaits(weekFromRows([
    { weekday: 6, hour: 22, passengers: 1380 },
    { weekday: 6, hour: 23, passengers: 0 },
    sunday,
  ]));
  // 8 lanes (1,200 an hour): Saturday 23:00 ends with 180 queued, which Sunday 00:00 clears.
  assertAlmostEquals(busy[0][0] - quiet[0][0], (90 / 1200) * 60);
});

Deno.test("small checkpoints wait less than big ones at the same share of their peak", () => {
  const shape = (peak: number) =>
    weekWaits(weekFromRows(
      [0.5, 0.9, 1, 0.8, 0.6].map((f, i) => ({
        weekday: 1,
        hour: 5 + i,
        passengers: Math.round(peak * f),
      })),
    ));
  // 120 at the peak fits one lane (150): no backlog.
  const small = shape(120);
  const big = shape(2000);
  assert(small[1][7] < big[1][7]);
  assert(rounded(small[1][7]).standard <= 10);
});

Deno.test("local time follows the airport's clock", () => {
  assertEquals(localTime(NOW, "America/Los_Angeles"), {
    weekday: 2,
    hour: 7,
    minute: 30,
  });
  assertEquals(localTime(NOW, "America/Chicago").hour, 9);
  // Saturday 23:30 in Los Angeles is Sunday in UTC.
  assertEquals(
    localTime(new Date("2026-11-08T07:30:00Z"), "America/Los_Angeles"),
    { weekday: 6, hour: 23, minute: 30 },
  );
  assertEquals(localTime(NOW, null), { weekday: 2, hour: 15, minute: 30 });
});

Deno.test("the wait blends the hour with the next by the minutes gone", () => {
  const waits = Array.from(
    { length: 7 },
    (_, d) => Array.from({ length: 24 }, (_, h) => d * 100 + h),
  );
  assertEquals(waitAt(waits, { weekday: 2, hour: 7, minute: 0 }), 207);
  assertEquals(waitAt(waits, { weekday: 2, hour: 7, minute: 30 }), 207.5);
  // Saturday 23:30 blends into Sunday 00:00.
  assertEquals(waitAt(waits, { weekday: 6, hour: 23, minute: 30 }), 311.5);
  // Out of range rows are ignored when building a week.
  assertEquals(
    weekFromRows([{ weekday: 9, hour: 7, passengers: 5000 }]).flat()
      .every((p) => p === 0),
    true,
  );
});

Deno.test("the typical week peaks on Sunday at 06:00 and gives believable waits", () => {
  const week = typicalWeek();
  assertEquals(week[0][6], TYPICAL_PEAK_PASSENGERS);
  const w = weekWaits(week);
  const peak = rounded(w[0][6]).standard;
  assert(peak >= 15 && peak <= 30, `peak ${peak}`);
  assertEquals(rounded(w[3][2]).standard, 5);
});
