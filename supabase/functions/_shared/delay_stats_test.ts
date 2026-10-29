import { assertEquals } from "jsr:@std/assert@1";
import type { FlightRow } from "./aeroapi.ts";
import { computeStats } from "./delay_stats.ts";

const BASE = Date.parse("2026-11-03T14:00:00Z");
const iso = (ms: number) => new Date(ms).toISOString();

function row(
  i: number,
  over: Partial<FlightRow> & { lateMin?: number } = {},
): FlightRow {
  const sched = BASE + i * 20 * 60_000;
  const late = over.lateMin ?? 0;
  const { lateMin: _l, ...rest } = over;
  return {
    provider_id: `p${i}`,
    ident: `UA${100 + i}`,
    operator: "UA",
    origin_icao: "KDEN",
    origin_iata: "DEN",
    destination_icao: "KAUS",
    destination_iata: "AUS",
    scheduled_out: iso(sched),
    scheduled_in: iso(sched),
    estimated_out: null,
    estimated_in: null,
    actual_out: iso(sched + late * 60_000),
    actual_off: null,
    actual_on: null,
    actual_in: iso(sched + late * 60_000),
    gate_origin: null,
    gate_destination: null,
    terminal_origin: null,
    terminal_destination: null,
    baggage_belt: null,
    aircraft_type: null,
    registration: null,
    status: "departed",
    updated_at: iso(BASE),
    ...rest,
  };
}

Deno.test("computeStats: 10 departures, one canceled is major (10% rule)", () => {
  const rows = [
    ...[0, 1, 2, 3, 4].map((i) => row(i)),
    ...[5, 6, 7].map((i) => row(i, { lateMin: 20 })),
    row(8, { lateMin: 50 }),
    row(9, { status: "canceled", actual_out: null, actual_in: null }),
  ];
  const s = computeStats(rows, "departures");
  assertEquals(s.total, 10);
  assertEquals(s.onTime, 5);
  assertEquals(s.delayed15, 4);
  assertEquals(s.canceled, 1);
  assertEquals(s.severity, "major");
  const buckets = s.perHour.reduce(
    (n, h) => n + h.onTime + h.late15 + h.late45 + h.canceled + h.diverted,
    0,
  );
  assertEquals(buckets, 10);
  assertEquals(s.worstRoutes[0], { icao: "KAUS", delayed: 4, canceled: 1 });
  assertEquals(s.worstAirlines[0], { operator: "UA", delayed: 4, canceled: 1 });
});

Deno.test("computeStats: average delay of 15 minutes or more is moderate", () => {
  const rows = [0, 1, 2, 3, 4].map((i) => row(i, { lateMin: 20 }));
  const s = computeStats(rows, "departures");
  assertEquals(s.avgDelayMinutes, 20);
  assertEquals(s.severity, "moderate");
});

Deno.test("computeStats: average delay of 45 minutes or more is major", () => {
  const rows = [0, 1, 2].map((i) => row(i, { lateMin: 50 }));
  assertEquals(computeStats(rows, "departures").severity, "major");
});

Deno.test("computeStats: arrivals read the in times and the origin", () => {
  const rows = [
    row(0, { actual_out: null, actual_in: iso(BASE + 30 * 60_000) }),
    row(1),
  ];
  const s = computeStats(rows, "arrivals");
  assertEquals(s.delayed15, 1);
  assertEquals(s.worstRoutes[0].icao, "KDEN");
  // The same rows as departures: actual_out is null on the first, so it has no delay.
  assertEquals(computeStats(rows, "departures").delayed15, 0);
});

Deno.test("computeStats: an estimate stands in until the flight has actuals", () => {
  const sched = BASE;
  const rows = [row(0, {
    status: "scheduled",
    actual_out: null,
    estimated_out: iso(sched + 25 * 60_000),
  })];
  assertEquals(computeStats(rows, "departures").delayed15, 1);
});

Deno.test("computeStats: empty list has zero totals, normal, no NaN", () => {
  const s = computeStats([], "departures");
  assertEquals(s.total, 0);
  assertEquals(s.onTime, 0);
  assertEquals(s.delayed15, 0);
  assertEquals(s.canceled, 0);
  assertEquals(s.avgDelayMinutes, 0);
  assertEquals(s.perHour, []);
  assertEquals(s.severity, "normal");
  assertEquals(Number.isNaN(s.avgDelayMinutes), false);
});
