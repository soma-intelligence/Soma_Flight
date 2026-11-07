// Alert detection: which push alerts one flight event is worth, from the `changes` process_alert
// wrote into its payload and the flights row. Pure functions; push-sender reads the history
// (alert_log) and claims what this returns.
//
// Airport program alerts (airport_program: a ground stop, ground delay program or closure at either
// end) do not come from a flight event: faa-status finds them and hands each to push-sender
// (faa_nas.ts).
//
// Nothing here calls the provider. The inbound late alert reads the inbound leg's row only when
// flights already has it (inbound_provider_id, migration 20261030000012).

import type { ProgramAlert } from "./faa_nas.ts";

/** Every alert the server sends. Reminders (check-in, morning of, leave for the airport) are local. */
export type AlertKind =
  | "departure_delay"
  | "arrival_delay"
  | "schedule_change"
  | "inbound_late"
  | "predicted_delay"
  | "gate_assigned"
  | "gate_change"
  | "terminal_change"
  | "baggage_belt"
  | "departed"
  | "takeoff"
  | "landing"
  | "arrived"
  | "cancel"
  | "reinstated"
  | "diversion"
  | "connection_at_risk"
  | "airport_program"
  | "early_departure"
  | "taxi_long"
  | "aircraft_change"
  | "boarding_started"
  | "boarding_change";

/** Columns of notification_preferences. `reminders` is only read by the app. */
export type AlertCategory =
  | "delays"
  | "gates"
  | "takeoff_landing"
  | "baggage"
  | "cancellations"
  | "reminders"
  | "boarding"
  | "aircraft"
  | "favorite_airports";

export const CATEGORY: Record<AlertKind, AlertCategory> = {
  departure_delay: "delays",
  arrival_delay: "delays",
  schedule_change: "delays",
  inbound_late: "delays",
  predicted_delay: "delays",
  connection_at_risk: "delays",
  gate_assigned: "gates",
  gate_change: "gates",
  terminal_change: "gates",
  baggage_belt: "baggage",
  departed: "takeoff_landing",
  takeoff: "takeoff_landing",
  landing: "takeoff_landing",
  arrived: "takeoff_landing",
  cancel: "cancellations",
  reinstated: "cancellations",
  diversion: "cancellations",
  airport_program: "delays",
  early_departure: "delays",
  taxi_long: "delays",
  aircraft_change: "aircraft",
  boarding_started: "boarding",
  boarding_change: "boarding",
};

/**
 * Alerts whose Live Activity update goes at priority 10 when the event itself is an `update`. The
 * named event kinds keep their own rule (push-sender's IMMEDIATE_KINDS).
 */
export const IMMEDIATE_ALERTS = new Set<AlertKind>([
  "gate_assigned",
  "gate_change",
  "terminal_change",
  "departed",
  "takeoff",
  "landing",
  "arrived",
  "cancel",
  "reinstated",
  "diversion",
  "aircraft_change",
  "boarding_started",
  "boarding_change",
]);

/** A flight that pushes back this many minutes before its schedule is an early departure. */
export const EARLY_DEPARTURE_MIN = 10;
/** Pushed back and still on the ground this many minutes later: the taxi out is long. */
export const TAXI_LONG_MIN = 30;
/** A boarding time that moves this many minutes is worth a "boarding time change" alert. */
export const BOARDING_STEP_MIN = 10;

/** A delay alert fires once the delay reaches this, then whenever it moves this far from the last one sent. */
export const DELAY_STEP_MIN = 15;
/** At or under this many minutes late a flight counts as on time ("back on time"). */
export const ON_TIME_MAX_MIN = 5;
/** Shortest turn between the inbound leg's arrival and this departure, for the inbound late alert. */
export const MIN_TURN_MIN = 30;

export type Side = "departure" | "arrival";

export interface Alert {
  kind: AlertKind;
  category: AlertCategory;
  /** Unique per flight in alert_log: a fixed key for once-only alerts, else the kind and the delivery. */
  key: string;
  side?: Side;
  /** The delay a delay alert announces (negative is early). */
  minutes?: number;
  /** Old and new value of what changed (gate, terminal, belt, airport, ISO time). */
  from?: string | null;
  to?: string | null;
  /** predicted_delay: the prediction's summary and reason (core predict.rs). */
  note?: string;
  reason?: string;
  /** airport_program only: the program, as faa-status sent it. */
  program?: ProgramAlert;
}

/** What the event's payload says about one column. */
interface Change {
  from: unknown;
  to: unknown;
}

export interface EventInput {
  id: string;
  kind: string;
  payload: Record<string, unknown> | null;
  /**
   * flight_events.provider_event_id: the delivery hash, with ':delay' on the second event of a
   * delivery. Both events of one delivery carry the same changes, so alert keys use the delivery.
   */
  providerEventId?: string | null;
}

/** The flights columns detection reads. */
export interface AlertFlight {
  id?: string;
  provider_id?: string | null;
  ident: string;
  status: string;
  origin_icao?: string | null;
  origin_iata?: string | null;
  destination_icao?: string | null;
  destination_iata?: string | null;
  scheduled_out: string | null;
  scheduled_in: string | null;
  estimated_out: string | null;
  estimated_in: string | null;
  actual_out: string | null;
  actual_off?: string | null;
  actual_on?: string | null;
  actual_in: string | null;
  gate_origin?: string | null;
  gate_destination?: string | null;
  terminal_origin?: string | null;
  terminal_destination?: string | null;
  baggage_belt?: string | null;
  aircraft_type?: string | null;
  registration?: string | null;
  /**
   * Boarding times. No provider adapter fills these today (AeroAPI and the free providers give no
   * boarding time), and process_alert does not track them, so the boarding alerts below never fire
   * until a source and a flights column exist. The detection is ready and tested.
   */
  boarding_estimated?: string | null;
  boarding_actual?: string | null;
  inbound_provider_id?: string | null;
}

/** What was sent before for this flight (alert_log). */
export interface AlertHistory {
  /** Every key already claimed. */
  keys: Set<string>;
  /** The minutes of the newest delay alert of each side, null when none was sent. */
  lastDelay: { departure: number | null; arrival: number | null };
}

export const emptyHistory = (): AlertHistory => ({
  keys: new Set(),
  lastDelay: { departure: null, arrival: null },
});

const ms = (v: unknown): number | null => {
  if (typeof v !== "string" || v === "") return null;
  const t = Date.parse(v);
  return Number.isFinite(t) ? t : null;
};

const text = (v: unknown): string | null =>
  typeof v === "string" && v !== "" ? v : null;

function minutesBetween(a: unknown, b: unknown): number | null {
  const x = ms(a), y = ms(b);
  return x === null || y === null ? null : Math.round((x - y) / 60_000);
}

function changesOf(
  payload: Record<string, unknown> | null,
): Record<string, Change> {
  const c = payload?.changes;
  if (!c || typeof c !== "object" || Array.isArray(c)) return {};
  const out: Record<string, Change> = {};
  for (const [k, v] of Object.entries(c as Record<string, unknown>)) {
    if (v && typeof v === "object" && !Array.isArray(v)) {
      const e = v as Record<string, unknown>;
      out[k] = { from: e.from ?? null, to: e.to ?? null };
    }
  }
  return out;
}

/** The delivery an event came from: its provider event id without the ':delay' suffix, else its id. */
export function deliveryOf(ev: EventInput): string {
  const p = ev.providerEventId;
  if (typeof p === "string" && p !== "") return p.replace(/:delay$/, "");
  return ev.id;
}

/**
 * Whether a delay of `minutes` is worth an alert, given the last one sent on that side (`last`, 0
 * when none). Late means more than ON_TIME_MAX_MIN. From on time, an alert needs DELAY_STEP_MIN; from
 * late, a move of DELAY_STEP_MIN either way, or a return to on time.
 */
export function delayWorthAlert(minutes: number, last: number): boolean {
  const lastLate = last > ON_TIME_MAX_MIN;
  if (minutes <= ON_TIME_MAX_MIN) return lastLate;
  return lastLate
    ? Math.abs(minutes - last) >= DELAY_STEP_MIN
    : minutes >= DELAY_STEP_MIN;
}

const ENDED = new Set(["canceled", "diverted"]);

/**
 * The alerts one event is worth. `flight` is the row as push-sender reads it (after the delivery).
 * Values come from the event's changes where it has them, so a later delivery cannot change what an
 * older event says. Once-only alerts already in `history.keys` are left out; alert_log's unique key
 * stops the rest when push-sender is retried.
 *
 * Events written before process_alert carried changes (and tests) still get their kind's alert:
 * departure is the take-off, arrival the landing, delay the side's delay from `delay_minutes`.
 */
export function detectAlerts(
  ev: EventInput,
  flight: AlertFlight,
  history: AlertHistory = emptyHistory(),
): Alert[] {
  const ch = changesOf(ev.payload);
  const delivery = deliveryOf(ev);
  const out: Alert[] = [];
  const add = (a: Omit<Alert, "category">) => {
    if (history.keys.has(a.key) || out.some((x) => x.key === a.key)) return;
    out.push({ ...a, category: CATEGORY[a.kind] });
  };
  const per = (kind: AlertKind, side?: Side) =>
    side ? `${kind}:${side}:${delivery}` : `${kind}:${delivery}`;
  const set = (k: string) =>
    k in ch && ch[k].from === null && ch[k].to !== null;
  const moved = (k: string) =>
    k in ch && ch[k].from !== null && ch[k].to !== null &&
    ch[k].from !== ch[k].to;

  const statusTo = text(ch.status?.to);
  const statusFrom = text(ch.status?.from);
  const status = statusTo ?? flight.status;

  // Cancellations and diversions first: once a flight is canceled nothing else about it matters.
  if (statusTo === "canceled" || (ev.kind === "cancel" && !("status" in ch))) {
    add({ kind: "cancel", key: per("cancel") });
    return out;
  }
  if (statusFrom === "canceled" && statusTo !== null) {
    add({ kind: "reinstated", key: per("reinstated") });
  }
  if (
    statusTo === "diverted" || (ev.kind === "diversion" && !("status" in ch))
  ) {
    const to = text(ch.destination_icao?.to) ?? text(ev.payload?.destination) ??
      null;
    add({
      kind: "diversion",
      key: per("diversion"),
      from: text(ch.destination_icao?.from),
      to,
    });
    return out;
  }
  if (status === "diverted") {
    // The diversion airport became known or moved after the diversion alert.
    if ("destination_icao" in ch && text(ch.destination_icao.to)) {
      add({
        kind: "diversion",
        key: per("diversion"),
        from: text(ch.destination_icao.from),
        to: text(ch.destination_icao.to),
      });
    }
    return out;
  }
  if (ENDED.has(status)) return out;

  // Schedule moved by the airline (both sides in one alert).
  if (moved("scheduled_out") || moved("scheduled_in")) {
    const side: Side = moved("scheduled_out") ? "departure" : "arrival";
    add({
      kind: "schedule_change",
      key: per("schedule_change"),
      side,
      from: text(
        ch[side === "departure" ? "scheduled_out" : "scheduled_in"].from,
      ),
      to: text(ch[side === "departure" ? "scheduled_out" : "scheduled_in"].to),
    });
  }

  // Delays, one side at a time: the departure until the plane leaves the gate, then the arrival.
  const departed = (text(ch.actual_out?.to) ?? flight.actual_out) !== null;
  const arrived = (text(ch.actual_in?.to) ?? flight.actual_in) !== null;
  const legacyDelay =
    ev.kind === "delay" && typeof ev.payload?.delay_minutes === "number"
      ? Math.round(ev.payload.delay_minutes as number)
      : null;
  if (!departed && status !== "arrived" && status !== "landed") {
    const est = text(ch.estimated_out?.to) ?? flight.estimated_out;
    const sched = text(ch.scheduled_out?.to) ?? flight.scheduled_out;
    const touched = "estimated_out" in ch || "scheduled_out" in ch;
    const min = touched ? minutesBetween(est, sched) : legacyDelay ??
      (ev.kind === "delay" ? minutesBetween(est, sched) : null);
    if (
      min !== null && delayWorthAlert(min, history.lastDelay.departure ?? 0)
    ) {
      add({
        kind: "departure_delay",
        key: per("departure_delay"),
        side: "departure",
        minutes: min,
        to: est,
      });
    }
  } else if (departed && !arrived && status !== "arrived") {
    const est = text(ch.estimated_in?.to) ?? flight.estimated_in;
    const sched = text(ch.scheduled_in?.to) ?? flight.scheduled_in;
    const touched = "estimated_in" in ch || "scheduled_in" in ch;
    const min = touched ? minutesBetween(est, sched) : legacyDelay ??
      (ev.kind === "delay" ? minutesBetween(est, sched) : null);
    // Until an arrival delay was sent, the last departure delay told the user how late they are.
    const last = history.lastDelay.arrival ?? history.lastDelay.departure ?? 0;
    if (min !== null && delayWorthAlert(min, last)) {
      add({
        kind: "arrival_delay",
        key: per("arrival_delay"),
        side: "arrival",
        minutes: min,
        to: est,
      });
    }
  }

  // Gates and terminals. The first departure (or arrival) gate is announced once.
  for (const side of ["departure", "arrival"] as const) {
    const g = side === "departure" ? "gate_origin" : "gate_destination";
    const t = side === "departure" ? "terminal_origin" : "terminal_destination";
    // No departure gate news once the plane has left it.
    if (side === "departure" && departed && !("actual_out" in ch)) continue;
    if (set(g)) {
      add({
        kind: "gate_assigned",
        key: `gate_assigned:${side}`,
        side,
        from: null,
        to: text(ch[g].to),
      });
    } else if (moved(g)) {
      add({
        kind: "gate_change",
        key: per("gate_change", side),
        side,
        from: text(ch[g].from),
        to: text(ch[g].to),
      });
    } else if (
      ev.kind === "gate_change" && !(g in ch) && Object.keys(ch).length === 0 &&
      side === (departed ? "arrival" : "departure")
    ) {
      // An event without changes: the gate of the leg that is next.
      const gate = side === "departure"
        ? flight.gate_origin
        : flight.gate_destination;
      add({
        kind: "gate_change",
        key: per("gate_change", side),
        side,
        from: null,
        to: gate ?? null,
      });
    }
    if (moved(t)) {
      add({
        kind: "terminal_change",
        key: per("terminal_change", side),
        side,
        from: text(ch[t].from),
        to: text(ch[t].to),
      });
    }
  }

  // Baggage belt: the first one, then any move.
  if (set("baggage_belt") || moved("baggage_belt")) {
    add({
      kind: "baggage_belt",
      key: `baggage_belt:${delivery}`,
      from: text(ch.baggage_belt.from),
      to: text(ch.baggage_belt.to),
    });
  }

  // Aircraft swap: the type or the registration changed on a flight that has not left yet.
  if (!departed) {
    const typeMoved = moved("aircraft_type");
    const regMoved = moved("registration");
    if (typeMoved || regMoved) {
      add({
        kind: "aircraft_change",
        key: per("aircraft_change"),
        from: text(ch[typeMoved ? "aircraft_type" : "registration"].from),
        to: text(ch[typeMoved ? "aircraft_type" : "registration"].to),
        reason: typeMoved ? "type" : "registration",
      });
    }
  }

  // Boarding (dormant until a source gives a boarding time, see AlertFlight).
  if (!departed) {
    if (set("boarding_actual")) {
      add({
        kind: "boarding_started",
        key: "boarding_started",
        to: text(ch.boarding_actual.to),
      });
    } else if (moved("boarding_estimated")) {
      const step = Math.abs(
        minutesBetween(ch.boarding_estimated.to, ch.boarding_estimated.from) ??
          0,
      );
      if (step >= BOARDING_STEP_MIN) {
        add({
          kind: "boarding_change",
          key: per("boarding_change"),
          from: text(ch.boarding_estimated.from),
          to: text(ch.boarding_estimated.to),
        });
      }
    }
  }

  // Left the gate early.
  if (set("actual_out")) {
    const early = minutesBetween(
      text(ch.scheduled_out?.to) ?? flight.scheduled_out,
      ch.actual_out.to,
    );
    if (early !== null && early >= EARLY_DEPARTURE_MIN) {
      add({
        kind: "early_departure",
        key: "early_departure",
        minutes: early,
        to: text(ch.actual_out.to),
      });
    }
  }

  // Long taxi out: wheels up long after pushback.
  if (set("actual_off")) {
    const out = text(ch.actual_out?.to) ?? flight.actual_out;
    const taxi = minutesBetween(ch.actual_off.to, out);
    if (taxi !== null && taxi >= TAXI_LONG_MIN) {
      add({
        kind: "taxi_long",
        key: "taxi_long",
        minutes: taxi,
        to: text(ch.actual_off.to),
      });
    }
  }

  // Milestones, each once per flight.
  const milestone = (col: string, kind: AlertKind) => {
    if (set(col)) add({ kind, key: kind, to: text(ch[col].to) });
  };
  milestone("actual_out", "departed");
  milestone("actual_off", "takeoff");
  milestone("actual_on", "landing");
  milestone("actual_in", "arrived");
  if (Object.keys(ch).length === 0) {
    if (ev.kind === "departure") {
      add({ kind: "takeoff", key: "takeoff", to: flight.actual_off ?? null });
    }
    if (ev.kind === "arrival") {
      add({ kind: "landing", key: "landing", to: flight.actual_on ?? null });
    }
  }
  return out;
}

/**
 * Inbound aircraft late: the leg bringing the plane arrives too late for this flight's schedule
 * (arrival plus MIN_TURN_MIN after the scheduled departure). Nothing when this flight has left, is
 * canceled or diverted, when the airline already moved the departure past that point (the delay
 * alert said it), or when the inbound leg does not end where this one starts. Once per flight.
 */
export function inboundLate(
  flight: AlertFlight,
  inbound: AlertFlight | null,
  history: AlertHistory = emptyHistory(),
): Alert | null {
  if (!inbound || history.keys.has("inbound_late")) return null;
  if (flight.actual_out || !["scheduled", "unknown"].includes(flight.status)) {
    return null;
  }
  if (ENDED.has(inbound.status)) return null;
  if (
    inbound.destination_icao && flight.origin_icao &&
    inbound.destination_icao !== flight.origin_icao
  ) return null;
  const arrival = ms(inbound.actual_in ?? inbound.estimated_in);
  const scheduled = ms(flight.scheduled_out);
  if (arrival === null || scheduled === null) return null;
  const ready = arrival + MIN_TURN_MIN * 60_000;
  if (ready <= scheduled) return null;
  const estimated = ms(flight.estimated_out);
  if (estimated !== null && estimated >= ready) return null;
  return {
    kind: "inbound_late",
    category: CATEGORY.inbound_late,
    key: "inbound_late",
    minutes: Math.round((ready - scheduled) / 60_000),
    to: inbound.actual_in ?? inbound.estimated_in,
  };
}
