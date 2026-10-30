import { assert, assertEquals } from "jsr:@std/assert@1";
import {
  type AlertFlight,
  type AlertHistory,
  CATEGORY,
  delayWorthAlert,
  deliveryOf,
  detectAlerts,
  emptyHistory,
  type EventInput,
  inboundLate,
} from "./alerts.ts";

const flight: AlertFlight = {
  id: "f1",
  provider_id: "AFR84-1",
  ident: "AF84",
  status: "scheduled",
  origin_icao: "LFPG",
  origin_iata: "CDG",
  destination_icao: "KSFO",
  destination_iata: "SFO",
  scheduled_out: "2026-11-03T22:30:00Z",
  scheduled_in: "2026-11-04T09:00:00Z",
  estimated_out: "2026-11-03T22:30:00Z",
  estimated_in: "2026-11-04T09:00:00Z",
  actual_out: null,
  actual_off: null,
  actual_on: null,
  actual_in: null,
  gate_origin: "K36",
  gate_destination: null,
  terminal_origin: "2E",
  terminal_destination: null,
  baggage_belt: null,
};

const departed: AlertFlight = {
  ...flight,
  status: "en_route",
  actual_out: "2026-11-03T22:41:00Z",
  actual_off: "2026-11-03T22:58:00Z",
};

let n = 0;
/** An event with these changes, from delivery `hash` (a fresh one by default). */
function ev(
  changes: Record<string, [unknown, unknown]>,
  kind = "update",
  hash = `h${++n}`,
  extra: Record<string, unknown> = {},
): EventInput {
  return {
    id: `e-${hash}`,
    kind,
    providerEventId: hash,
    payload: {
      ...extra,
      changes: Object.fromEntries(
        Object.entries(changes).map(([k, [from, to]]) => [k, { from, to }]),
      ),
    },
  };
}

const kinds = (e: EventInput, f = flight, h?: AlertHistory) =>
  detectAlerts(e, f, h).map((a) => a.kind);

function history(
  keys: string[] = [],
  dep: number | null = null,
  arr: number | null = null,
): AlertHistory {
  return { keys: new Set(keys), lastDelay: { departure: dep, arrival: arr } };
}

Deno.test("delayWorthAlert: 15 to start, 15 either way, back on time", () => {
  assertEquals(delayWorthAlert(14, 0), false);
  assertEquals(delayWorthAlert(15, 0), true);
  assertEquals(delayWorthAlert(25, 15), false);
  assertEquals(delayWorthAlert(30, 15), true);
  assertEquals(delayWorthAlert(12, 30), true); // moved 18 down, still late
  assertEquals(delayWorthAlert(20, 30), false);
  assertEquals(delayWorthAlert(3, 12), true); // late to on time
  assertEquals(delayWorthAlert(0, 5), false); // was not late
  assertEquals(delayWorthAlert(-20, 0), false); // early is on time
  assertEquals(delayWorthAlert(-2, 40), true);
});

Deno.test("departure delay: new estimate 15 min off, then back on time", () => {
  const late = detectAlerts(
    ev({ estimated_out: ["2026-11-03T22:30:00Z", "2026-11-03T22:55:00Z"] }),
    flight,
  );
  assertEquals(late.map((a) => [a.kind, a.minutes, a.category]), [[
    "departure_delay",
    25,
    "delays",
  ]]);
  // 10 minutes off the last one sent: nothing.
  assertEquals(
    kinds(
      ev({ estimated_out: ["2026-11-03T22:55:00Z", "2026-11-03T23:05:00Z"] }),
      flight,
      history([], 25),
    ),
    [],
  );
  // Back on time from 25 late.
  const back = detectAlerts(
    ev({ estimated_out: ["2026-11-03T22:55:00Z", "2026-11-03T22:31:00Z"] }),
    flight,
    history([], 25),
  );
  assertEquals(back.map((a) => [a.kind, a.minutes]), [["departure_delay", 1]]);
});

Deno.test("arrival delay after the gate out, measured from the last delay told", () => {
  const e = ev({
    estimated_in: ["2026-11-04T09:25:00Z", "2026-11-04T09:30:00Z"],
  });
  // 30 late on arrival after a 25 late departure alert: nothing new to say.
  assertEquals(kinds(e, departed, history([], 25)), []);
  // 30 late with nothing sent: an arrival delay.
  assertEquals(kinds(e, departed), ["arrival_delay"]);
  // Before the gate out, arrival estimates alone make no alert.
  assertEquals(kinds(e, flight), []);
  // The departure side is done once the plane left.
  assertEquals(
    kinds(
      ev({ estimated_out: ["2026-11-03T22:30:00Z", "2026-11-03T23:30:00Z"] }),
      departed,
    ),
    [],
  );
});

Deno.test("schedule change by the airline", () => {
  const a = detectAlerts(
    ev({
      scheduled_out: ["2026-11-03T22:30:00Z", "2026-11-03T23:30:00Z"],
      estimated_out: ["2026-11-03T22:30:00Z", "2026-11-03T23:30:00Z"],
    }),
    { ...flight, scheduled_out: "2026-11-03T23:30:00Z" },
  );
  // The new estimate matches the new schedule, so no delay alert.
  assertEquals(a.map((x) => [x.kind, x.side, x.to]), [[
    "schedule_change",
    "departure",
    "2026-11-03T23:30:00Z",
  ]]);
  // A first scheduled time is not a change.
  assertEquals(
    kinds(ev({ scheduled_in: [null, "2026-11-04T09:00:00Z"] })),
    [],
  );
});

Deno.test("gates: first assignment once, later moves, arrival side too", () => {
  const first = detectAlerts(ev({ gate_origin: [null, "K36"] }), flight);
  assertEquals(first.map((a) => [a.kind, a.key, a.to]), [[
    "gate_assigned",
    "gate_assigned:departure",
    "K36",
  ]]);
  assertEquals(
    kinds(
      ev({ gate_origin: [null, "K36"] }),
      flight,
      history(["gate_assigned:departure"]),
    ),
    [],
  );
  const moved = detectAlerts(ev({ gate_origin: ["K36", "G91"] }), flight);
  assertEquals(moved.map((a) => [a.kind, a.from, a.to]), [[
    "gate_change",
    "K36",
    "G91",
  ]]);
  assertEquals(
    detectAlerts(ev({ gate_destination: ["B20", "B24"] }), departed).map((
      a,
    ) => [a.kind, a.side]),
    [["gate_change", "arrival"]],
  );
  // No departure gate news once the plane has left it.
  assertEquals(kinds(ev({ gate_origin: ["K36", "K40"] }), departed), []);
});

Deno.test("terminal change and baggage belt", () => {
  assertEquals(
    detectAlerts(ev({ terminal_origin: ["2E", "2F"] }), flight).map((
      a,
    ) => [a.kind, a.category]),
    [["terminal_change", "gates"]],
  );
  // A first terminal is not a change.
  assertEquals(kinds(ev({ terminal_destination: [null, "3"] })), []);
  assertEquals(
    detectAlerts(ev({ baggage_belt: [null, "4"] }), departed).map((
      a,
    ) => [a.kind, a.category, a.from, a.to]),
    [["baggage_belt", "baggage", null, "4"]],
  );
  assertEquals(kinds(ev({ baggage_belt: ["4", "5"] }), departed), [
    "baggage_belt",
  ]);
});

Deno.test("milestones: gate out, take-off, landing, gate in, once each", () => {
  const e = ev({
    actual_out: [null, "2026-11-03T22:41:00Z"],
    actual_off: [null, "2026-11-03T22:58:00Z"],
    status: ["scheduled", "en_route"],
  });
  assertEquals(kinds(e, departed), ["departed", "takeoff"]);
  assertEquals(kinds(e, departed, history(["departed", "takeoff"])), []);
  const arrived: AlertFlight = {
    ...departed,
    status: "arrived",
    actual_on: "2026-11-04T08:50:00Z",
    actual_in: "2026-11-04T08:58:00Z",
  };
  assertEquals(
    kinds(
      ev({
        actual_on: [null, "2026-11-04T08:50:00Z"],
        actual_in: [null, "2026-11-04T08:58:00Z"],
        status: ["en_route", "arrived"],
      }),
      arrived,
    ),
    ["landing", "arrived"],
  );
  for (const k of ["departed", "takeoff", "landing", "arrived"] as const) {
    assertEquals(CATEGORY[k], "takeoff_landing");
  }
});

Deno.test("cancel, reinstated, diversion and its destination", () => {
  assertEquals(
    kinds(
      ev(
        { status: ["scheduled", "canceled"], gate_origin: ["K36", "K40"] },
        "cancel",
      ),
      {
        ...flight,
        status: "canceled",
      },
    ),
    ["cancel"], // nothing else about a canceled flight
  );
  assertEquals(
    kinds(ev({ status: ["canceled", "scheduled"] }), flight),
    ["reinstated"],
  );
  const div = detectAlerts(
    ev(
      { status: ["en_route", "diverted"], destination_icao: ["KSFO", "KOAK"] },
      "diversion",
    ),
    { ...departed, status: "diverted", destination_icao: "KOAK" },
  );
  assertEquals(div.map((a) => [a.kind, a.from, a.to, a.category]), [[
    "diversion",
    "KSFO",
    "KOAK",
    "cancellations",
  ]]);
  // The destination of a diversion made known later.
  assertEquals(
    detectAlerts(ev({ destination_icao: ["KSFO", "KSJC"] }), {
      ...departed,
      status: "diverted",
    }).map((a) => a.to),
    ["KSJC"],
  );
  // Take-off news for a diverted flight is not sent.
  assertEquals(
    kinds(ev({ actual_on: [null, "2026-11-04T08:50:00Z"] }), {
      ...departed,
      status: "diverted",
    }),
    [],
  );
});

Deno.test("dedupe: the two events of one delivery share their keys", () => {
  const changes = {
    gate_origin: ["K36", "K50"] as [string, string],
    estimated_out: ["2026-11-03T22:30:00Z", "2026-11-03T23:10:00Z"] as [
      string,
      string,
    ],
  };
  const a = detectAlerts(ev(changes, "gate_change", "abc"), flight);
  const b = detectAlerts(ev(changes, "delay", "abc:delay"), flight);
  assertEquals(a.map((x) => x.key).sort(), b.map((x) => x.key).sort());
  assertEquals(
    deliveryOf({
      id: "x",
      kind: "delay",
      payload: {},
      providerEventId: "abc:delay",
    }),
    "abc",
  );
  assertEquals(deliveryOf({ id: "x", kind: "delay", payload: {} }), "x");
  // Two moves of the same gate in two deliveries are two alerts (different keys).
  const c = detectAlerts(ev({ gate_origin: ["K50", "K36"] }), flight);
  assert(c[0].key !== a.find((x) => x.kind === "gate_change")!.key);
});

Deno.test("events without changes keep their kind's alert", () => {
  assertEquals(kinds({ id: "1", kind: "departure", payload: {} }, departed), [
    "takeoff",
  ]);
  assertEquals(kinds({ id: "2", kind: "arrival", payload: {} }, departed), [
    "landing",
  ]);
  assertEquals(kinds({ id: "3", kind: "cancel", payload: {} }), ["cancel"]);
  assertEquals(
    kinds({ id: "4", kind: "diversion", payload: { destination: "KOAK" } }),
    [
      "diversion",
    ],
  );
  assertEquals(
    detectAlerts(
      { id: "5", kind: "delay", payload: { delay_minutes: 30 } },
      flight,
    )
      .map((a) => [a.kind, a.minutes]),
    [["departure_delay", 30]],
  );
  assertEquals(
    kinds({ id: "6", kind: "delay", payload: { delay_minutes: 10 } }),
    [],
  );
  assertEquals(kinds({ id: "7", kind: "gate_change", payload: {} }), [
    "gate_change",
  ]);
  assertEquals(kinds({ id: "8", kind: "position", payload: {} }), []);
});

Deno.test("inbound late: needs the inbound row, skips cleanly without it", () => {
  const inbound: AlertFlight = {
    ...flight,
    id: "in1",
    ident: "AF83",
    status: "en_route",
    origin_icao: "KSFO",
    destination_icao: "LFPG",
    scheduled_in: "2026-11-03T21:30:00Z",
    estimated_in: "2026-11-03T22:20:00Z",
  };
  assertEquals(inboundLate(flight, null), null);
  const late = inboundLate(flight, inbound)!;
  assertEquals([late.kind, late.category, late.key, late.minutes], [
    "inbound_late",
    "delays",
    "inbound_late",
    20, // ready at 22:50, scheduled 22:30
  ]);
  // On time inbound: 21:50 plus 30 minutes is 22:20, before 22:30.
  assertEquals(
    inboundLate(flight, { ...inbound, estimated_in: "2026-11-03T21:50:00Z" }),
    null,
  );
  // Already sent, already delayed by the airline, already gone, or a leg to elsewhere.
  assertEquals(inboundLate(flight, inbound, history(["inbound_late"])), null);
  assertEquals(
    inboundLate({ ...flight, estimated_out: "2026-11-03T23:00:00Z" }, inbound),
    null,
  );
  assertEquals(inboundLate(departed, inbound), null);
  assertEquals(
    inboundLate(flight, { ...inbound, destination_icao: "EGLL" }),
    null,
  );
  assertEquals(inboundLate(flight, { ...inbound, status: "canceled" }), null);
  assertEquals(inboundLate(flight, { ...inbound, estimated_in: null }), null);
  assertEquals(emptyHistory().keys.size, 0);
});
