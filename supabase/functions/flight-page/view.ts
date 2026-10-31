// What the share page says about a flight, worked out from its rows and the clock: the status and its
// colour, each side's times, how far along the trip is. Pure, so the page and its tests agree.
//
// The colours follow the app (Theme, DelayLevel): on time under 15 minutes late, late from 15, very late
// from 45; canceled and diverted win over any delay. The page only ever reads flight data: the flights row,
// its two airports and its airline. Nothing the sharer noted (seat, booking code, notes) reaches it.

/** The flights columns the page reads. */
export interface FlightRow {
  id: string;
  ident: string;
  operator: string | null;
  origin_icao: string | null;
  origin_iata: string | null;
  destination_icao: string | null;
  destination_iata: string | null;
  scheduled_out: string | null;
  estimated_out: string | null;
  actual_out: string | null;
  scheduled_in: string | null;
  estimated_in: string | null;
  actual_in: string | null;
  actual_off: string | null;
  scheduled_on: string | null;
  estimated_on: string | null;
  actual_on: string | null;
  gate_origin: string | null;
  gate_destination: string | null;
  terminal_origin: string | null;
  terminal_destination: string | null;
  baggage_belt: string | null;
  aircraft_type: string | null;
  status: string;
  position_lat: number | null;
  position_lon: number | null;
  position_at: string | null;
  updated_at: string;
}

export const FLIGHT_COLUMNS =
  "id, ident, operator, origin_icao, origin_iata, destination_icao, destination_iata, scheduled_out, estimated_out, actual_out, scheduled_in, estimated_in, actual_in, actual_off, scheduled_on, estimated_on, actual_on, gate_origin, gate_destination, terminal_origin, terminal_destination, baggage_belt, aircraft_type, status, position_lat, position_lon, position_at, updated_at";

export interface AirportRow {
  icao: string;
  iata: string | null;
  name: string;
  city: string | null;
  lat: number;
  lon: number;
  tz: string | null;
}

export interface AirlineRow {
  icao: string;
  iata: string | null;
  name: string;
  color_primary: string;
}

export type Tone = "onTime" | "late" | "veryLate" | "canceled" | "diverted";

/** The app's dark palette (Theme). */
export const TONE_COLOR: Record<Tone, string> = {
  onTime: "#12B76A",
  late: "#FDB022",
  veryLate: "#FF453A",
  canceled: "#96969D",
  diverted: "#BF5AF2",
};

const ms = (v: string | null | undefined): number | null => {
  if (!v) return null;
  const t = Date.parse(v);
  return Number.isFinite(t) ? t : null;
};

/** DelayLevel.for(delay:status:): whole minutes, truncated. */
export function toneFor(delayMs: number | null, status: string): Tone {
  if (status === "canceled") return "canceled";
  if (status === "diverted") return "diverted";
  if (delayMs === null) return "onTime";
  const m = Math.trunc(delayMs / 60_000);
  return m >= 45 ? "veryLate" : m >= 15 ? "late" : "onTime";
}

/** "2h 5m", "45m", "0m". */
export function duration(msLeft: number): string {
  const m = Math.max(0, Math.round(msLeft / 60_000));
  const h = Math.floor(m / 60);
  return h ? `${h}h ${m % 60}m` : `${m}m`;
}

/** One side of the trip as the page shows it. */
export interface Side {
  /** "CDG", else the ICAO code, else "---". */
  code: string;
  name: string | null;
  city: string | null;
  tz: string;
  /** The best time known (actual, else estimated, else scheduled), epoch ms; null when none. */
  time: number | null;
  /** The schedule, shown struck through when the best time differs by a minute or more. */
  scheduled: number | null;
  /** "Departed", "Estimated", "Scheduled", "Arrived", "Landed". */
  label: string;
  tone: Tone;
  terminal: string | null;
  gate: string | null;
  /** Arrival only. */
  belt: string | null;
}

export interface FlightView {
  /** "AF 84" (the app's Format.ident). */
  ident: string;
  airline: AirlineRow | null;
  origin: Side;
  destination: Side;
  status: { text: string; tone: Tone };
  /** "Departs in 2h 5m", "Lands in 1h 20m", "Landed 25m ago"; null when there is nothing to count. */
  countdown: string | null;
  /** 0 to 1 while in the air, null otherwise. */
  progress: number | null;
  /** How much of the route the map draws as flown: the progress, all of it once down, else none. */
  flown: number | null;
  /** Where the plane is: a fresh reported position, else its share of the trip along the route. */
  position: { lat: number; lon: number } | null;
  updatedAt: number;
}

/** FlightActivityDisplay.ident: a space after the airline code ("AF 84", "U2 1234", "EZY 12"). */
export function formatIdent(raw: string): string {
  if (raw.length <= 2) return raw;
  const split = /[A-Za-z]/.test(raw[2]) ? 3 : 2;
  return split < raw.length
    ? `${raw.slice(0, split)} ${raw.slice(split)}`
    : raw;
}

const IN_AIR = new Set(["departed", "en_route"]);
/** A reported position older than this is not drawn; the plane goes where the clock says. */
export const POSITION_FRESH_MS = 30 * 60_000;

function side(
  airport: AirportRow | null,
  icao: string | null,
  iata: string | null,
): Pick<Side, "code" | "name" | "city" | "tz"> {
  return {
    code: airport?.iata ?? iata ?? airport?.icao ?? icao ?? "---",
    name: airport?.name ?? null,
    // "Paris (Roissy-en-France, Val-d'Oise)" reads as "Paris".
    city: airport?.city?.replace(/\s*\(.*\)\s*$/, "") || null,
    tz: airport?.tz ?? "UTC",
  };
}

export function buildView(
  f: FlightRow,
  origin: AirportRow | null,
  destination: AirportRow | null,
  airline: AirlineRow | null,
  now: Date,
): FlightView {
  const t = now.getTime();
  const sOut = ms(f.scheduled_out), sIn = ms(f.scheduled_in);
  const aOut = ms(f.actual_out), eOut = ms(f.estimated_out);
  const aIn = ms(f.actual_in), eIn = ms(f.estimated_in);
  const aOn = ms(f.actual_on), aOff = ms(f.actual_off);
  const depTime = aOut ?? eOut ?? sOut;
  const arrTime = aIn ?? eIn ?? sIn;
  const depDelay = depTime !== null && sOut !== null ? depTime - sOut : null;
  const arrDelay = arrTime !== null && sIn !== null ? arrTime - sIn : null;

  const dep: Side = {
    ...side(origin, f.origin_icao, f.origin_iata),
    time: depTime,
    scheduled: sOut,
    label: aOut !== null
      ? "Departed"
      : eOut !== null
      ? "Estimated"
      : "Scheduled",
    tone: toneFor(depDelay, f.status),
    terminal: f.terminal_origin,
    gate: f.gate_origin,
    belt: null,
  };
  const arr: Side = {
    ...side(destination, f.destination_icao, f.destination_iata),
    time: arrTime,
    scheduled: sIn,
    label: aIn !== null
      ? "Arrived"
      : aOn !== null
      ? "Landed"
      : eIn !== null
      ? "Estimated"
      : "Scheduled",
    tone: toneFor(arrDelay, f.status),
    terminal: f.terminal_destination,
    gate: f.gate_destination,
    belt: f.baggage_belt,
  };

  const airborne = IN_AIR.has(f.status) && aOn === null && aIn === null;
  let status: FlightView["status"];
  let countdown: string | null = null;
  switch (f.status) {
    case "canceled":
      status = { text: "Canceled", tone: "canceled" };
      break;
    case "diverted":
      status = { text: "Diverted", tone: "diverted" };
      break;
    case "arrived":
    case "landed": {
      status = {
        text: f.status === "arrived" ? "Arrived" : "Landed",
        tone: arr.tone,
      };
      const down = aIn ?? aOn;
      if (down !== null && t >= down) {
        countdown = `Landed ${duration(t - down)} ago`;
      }
      break;
    }
    default:
      if (airborne) {
        status = {
          text: f.status === "en_route" ? "In the air" : "Departed",
          tone: arr.tone,
        };
        if (arrTime !== null && arrTime > t) {
          countdown = `Lands in ${duration(arrTime - t)}`;
        }
      } else {
        const late = dep.tone !== "onTime";
        status = {
          text: late ? "Delayed" : depTime !== null ? "On time" : "Scheduled",
          tone: dep.tone,
        };
        if (depTime !== null && depTime > t) {
          countdown = `Departs in ${duration(depTime - t)}`;
        }
      }
  }

  let progress: number | null = null;
  if (airborne) {
    const start = aOff ?? aOut;
    const end = ms(f.estimated_on) ?? arrTime;
    progress = start !== null && end !== null && end > start
      ? Math.min(0.98, Math.max(0.02, (t - start) / (end - start)))
      : 0.5;
  }
  const posAt = ms(f.position_at);
  const fresh = airborne && f.position_lat !== null &&
    f.position_lon !== null &&
    posAt !== null && t - posAt <= POSITION_FRESH_MS;
  return {
    ident: formatIdent(f.ident),
    airline,
    origin: dep,
    destination: arr,
    status,
    countdown,
    progress,
    flown: progress ?? (aOn !== null || aIn !== null ? 1 : null),
    position: fresh ? { lat: f.position_lat!, lon: f.position_lon! } : null,
    updatedAt: ms(f.updated_at) ?? t,
  };
}
