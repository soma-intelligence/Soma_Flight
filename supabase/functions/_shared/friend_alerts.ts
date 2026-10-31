// Alerts about a friend's flight: which of a flight's alerts a friend hears (take-off, landing, a big delay)
// and their words. push-sender sends them to friends who turned alerts on for that person
// (friend_alert_watchers, migration 20261031000022), in the Delays and Take-off and Landing categories.
// Pure functions.
import type { Alert, AlertFlight } from "./alerts.ts";
import { type AlertText, displayIdent } from "./alert_copy.ts";

/** A delay worth telling a friend about, in minutes. */
export const FRIEND_DELAY_MIN = 30;

/** What a friend hears about: took off, landed, and a delay of FRIEND_DELAY_MIN or more. */
export function forFriends(alerts: Alert[]): Alert[] {
  return alerts.filter((a) => {
    switch (a.kind) {
      case "takeoff":
      case "landing":
        return true;
      // Gate out and in only stand in when the flight has no runway time at all.
      case "departed":
        return !alerts.some((b) => b.kind === "takeoff");
      case "arrived":
        return !alerts.some((b) => b.kind === "landing");
      case "departure_delay":
      case "arrival_delay":
        return (a.minutes ?? 0) >= FRIEND_DELAY_MIN;
      default:
        return false;
    }
  });
}

function code(iata: unknown, icao: unknown): string | null {
  const v = typeof iata === "string" && iata ? iata : icao;
  return typeof v === "string" && v ? v : null;
}

function span(min: number): string {
  if (min < 60) return `${min} min`;
  const h = Math.floor(min / 60), m = min % 60;
  return m === 0 ? `${h} h` : `${h} h ${m} min`;
}

/** The friend as the alert names them: emoji and name, "A friend" when they set no name. */
export function friendLabel(
  name: string | null | undefined,
  emoji?: string | null,
): string {
  const n = name?.trim() || "A friend";
  return emoji ? `${emoji} ${n}` : n;
}

/** Title and body of a friend alert. */
export function friendAlertText(
  a: Alert,
  f: AlertFlight,
  name: string | null | undefined,
  emoji?: string | null,
): AlertText {
  const who = friendLabel(name, emoji);
  const id = displayIdent(f.ident);
  const orig = code(f.origin_iata, f.origin_icao);
  const dest = code(f.destination_iata, f.destination_icao);
  const route = orig && dest ? ` ${orig} to ${dest}` : "";
  switch (a.kind) {
    case "takeoff":
    case "departed":
      return { title: `${who} is on the way`, body: `${id}${route} took off.` };
    case "landing":
    case "arrived":
      return {
        title: `${who} has landed`,
        body: `${id}${route} is on the ground${dest ? ` in ${dest}` : ""}.`,
      };
    default: {
      const side = a.kind === "arrival_delay" ? "arriving" : "leaving";
      return {
        title: `${who}'s flight is late`,
        body: `${id}${route} is ${side} ${span(a.minutes ?? 0)} late.`,
      };
    }
  }
}
