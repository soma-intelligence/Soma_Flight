// The words of every push alert, in one place. Short, specific English: the headline says what
// happened ("AF 84 is now 25m late", "Gate changed to G91"), the body gives the time and place.
// No dashes. Times are local to the airport they happen at (UTC, marked, when its zone is unknown).
import { type Alert, type AlertFlight, ON_TIME_MAX_MIN } from "./alerts.ts";
import rules from "./connection_rules.json" with { type: "json" };

/** Less time on the ground than this: boarding has closed (connection_rules.json). */
const GATE_CLOSE_MIN = rules.verdict.gate_close_minutes;

export interface CopyContext {
  /** IANA zones of the two airports. */
  originTz?: string | null;
  destinationTz?: string | null;
  /** The inbound leg, for inbound_late. */
  inbound?: AlertFlight | null;
  /** The onward flight, for connection_at_risk. */
  onward?: AlertFlight | null;
}

export interface AlertText {
  title: string;
  body: string;
}

/**
 * "AF 84", "B6 717", "EJM 444": airline code, space, number. The same rule as the app's
 * FlightActivityDisplay.ident: a third letter makes a three letter code.
 */
export function displayIdent(raw: string): string {
  const c = [...raw];
  if (c.length <= 2) return raw;
  const split = /[A-Za-z]/.test(c[2]) ? 3 : 2;
  if (split >= c.length) return raw;
  return `${c.slice(0, split).join("")} ${c.slice(split).join("")}`;
}

/** "25m", "1h 10m", "2h": the app's duration style. Sign dropped. */
export function span(minutes: number): string {
  const m = Math.abs(Math.round(minutes));
  const h = Math.floor(m / 60), r = m % 60;
  if (h === 0) return `${r}m`;
  return r === 0 ? `${h}h` : `${h}h ${r}m`;
}

/** "10:55 PM" at the airport, or "9:55 PM UTC" without a zone. */
export function clock(iso: string, tz: string | null | undefined): string {
  const fmt = (zone: string) =>
    new Intl.DateTimeFormat("en-US", {
      hour: "numeric",
      minute: "2-digit",
      timeZone: zone,
    }).format(new Date(iso));
  try {
    if (tz) return fmt(tz);
  } catch { /* unknown zone: fall through to UTC */ }
  return `${fmt("UTC")} UTC`;
}

const code = (iata?: string | null, icao?: string | null) =>
  iata ?? icao ?? null;

/** The text of one alert. Never null: every alert detection returns has words. */
export function alertText(
  a: Alert,
  f: AlertFlight,
  ctx: CopyContext = {},
): AlertText {
  const id = displayIdent(f.ident);
  const orig = code(f.origin_iata, f.origin_icao);
  const dest = code(f.destination_iata, f.destination_icao);
  // A missing or unreadable time leaves the time out of the sentence.
  const at = (iso: string | null | undefined, tz: string | null | undefined) =>
    iso && Number.isFinite(Date.parse(iso)) ? clock(iso, tz) : null;
  const atOrig = (iso: string | null | undefined) => at(iso, ctx.originTz);
  const atDest = (iso: string | null | undefined) => at(iso, ctx.destinationTz);
  const from = (place: string | null) => (place ? ` from ${place}` : "");
  const toDest = dest ? ` to ${dest}` : "";
  const inPlace = (place: string | null) => (place ? ` at ${place}` : "");
  const was = a.from ? `, was ${a.from}` : "";
  const sentence = (s: string) => `${s.charAt(0).toUpperCase()}${s.slice(1)}.`;

  switch (a.kind) {
    case "departure_delay": {
      const min = a.minutes ?? 0;
      const when = atOrig(a.to ?? f.estimated_out);
      const sched = atOrig(f.scheduled_out);
      if (min <= ON_TIME_MAX_MIN) {
        return {
          title: `${id} is back on time`,
          body: when
            ? sentence(`departs${from(orig)} at ${when}`)
            : "Departing on schedule.",
        };
      }
      return {
        title: `${id} is now ${span(min)} late`,
        body: when
          ? sentence(
            `now departs${from(orig)} at ${when}${
              sched ? ` instead of ${sched}` : ""
            }`,
          )
          : sentence(`now running ${span(min)} late`),
      };
    }
    case "arrival_delay": {
      const min = a.minutes ?? 0;
      const when = atDest(a.to ?? f.estimated_in);
      const sched = atDest(f.scheduled_in);
      if (min <= ON_TIME_MAX_MIN) {
        return {
          title: `${id} now arrives on time`,
          body: when
            ? sentence(`arrives${inPlace(dest)} at ${when}`)
            : "Arriving on schedule.",
        };
      }
      return {
        title: `${id} now arrives ${span(min)} late`,
        body: when
          ? sentence(
            `now arrives${inPlace(dest)} at ${when}${
              sched ? ` instead of ${sched}` : ""
            }`,
          )
          : sentence(`now arriving ${span(min)} late`),
      };
    }
    case "schedule_change": {
      const dep = a.side !== "arrival";
      const when = dep ? atOrig(a.to) : atDest(a.to);
      const before = dep ? atOrig(a.from) : atDest(a.from);
      const what = dep ? `departs${from(orig)}` : `arrives${inPlace(dest)}`;
      return {
        title: `${id} schedule changed`,
        body: when
          ? sentence(
            `the airline moved it: now ${what} at ${when}${
              before ? `, was ${before}` : ""
            }`,
          )
          : "The airline changed the schedule. Open the app for the new times.",
      };
    }
    case "inbound_late": {
      const inb = ctx.inbound;
      const lands = atOrig(a.to);
      const dep = atOrig(f.scheduled_out);
      const plane = inb
        ? `${displayIdent(inb.ident)}, the plane for this flight,`
        : "The plane for this flight";
      return {
        title: `${id} inbound plane is late`,
        body: lands && dep
          ? `${plane} arrives${
            inPlace(orig)
          } at ${lands}, too late for the ${dep} departure. Expect a delay.`
          : `${plane} is running late. Expect a delay.`,
      };
    }
    case "predicted_delay": {
      // The core's summary reads "Likely 25 min late: inbound aircraft running late".
      const cause = a.note?.split(": ").slice(1).join(": ") ?? "";
      const why = cause ? `${sentence(cause)} ` : "";
      return {
        title: `${id} likely ${a.minutes ?? 0} min late`,
        body: `${why}The airline has not changed its departure time yet.`,
      };
    }
    case "gate_assigned": {
      if (a.side === "arrival") {
        return {
          title: `Arrival gate ${a.to}`,
          body: `${id} arrives at gate ${a.to}${inPlace(dest)}.`,
        };
      }
      return {
        title: `Gate ${a.to} assigned`,
        body: `${id}${toDest} departs from gate ${a.to}${inPlace(orig)}.`,
      };
    }
    case "gate_change": {
      if (!a.to) {
        return {
          title: `${id} gate change`,
          body: "Your gate changed. Open the app for the new one.",
        };
      }
      if (a.side === "arrival") {
        return {
          title: `Arrival gate changed to ${a.to}`,
          body: `${id} now arrives at gate ${a.to}${inPlace(dest)}${was}.`,
        };
      }
      return {
        title: `Gate changed to ${a.to}`,
        body: `${id}${toDest} now departs from gate ${a.to}${was}.`,
      };
    }
    case "terminal_change": {
      if (a.side === "arrival") {
        return {
          title: `Arrival terminal changed to ${a.to}`,
          body: `${id} now arrives at terminal ${a.to}${inPlace(dest)}${was}.`,
        };
      }
      return {
        title: `Terminal changed to ${a.to}`,
        body: `${id}${toDest} now departs from terminal ${a.to}${was}.`,
      };
    }
    case "baggage_belt":
      return a.from
        ? {
          title: `Baggage belt changed to ${a.to}`,
          body: `Bags from ${id} now come out on belt ${a.to}${
            inPlace(dest)
          }${was}.`,
        }
        : {
          title: `Bags on belt ${a.to}`,
          body: `Bags from ${id} come out on belt ${a.to}${inPlace(dest)}.`,
        };
    case "departed": {
      const when = atOrig(a.to ?? f.actual_out);
      return {
        title: `${id} left the gate`,
        body: when
          ? sentence(`pushed back${from(orig)} at ${when}`)
          : sentence(`pushed back${from(orig)}`),
      };
    }
    case "takeoff": {
      const when = atOrig(a.to ?? f.actual_off);
      const eta = atDest(f.estimated_in ?? f.scheduled_in);
      const off = when
        ? sentence(`took off${from(orig)} at ${when}`)
        : sentence(`took off${from(orig)}`);
      return {
        title: `${id} took off`,
        body: eta && dest ? `${off} Arrives ${dest} at ${eta}.` : off,
      };
    }
    case "landing": {
      const when = atDest(a.to ?? f.actual_on);
      const gate = f.gate_destination
        ? ` Heading to gate ${f.gate_destination}.`
        : "";
      return {
        title: `${id} landed`,
        body: `${
          when
            ? sentence(`landed${inPlace(dest)} at ${when}`)
            : sentence(`landed${inPlace(dest)}`)
        }${gate}`,
      };
    }
    case "arrived": {
      const gate = f.gate_destination
        ? `At gate ${f.gate_destination}`
        : "At the gate";
      const belt = f.baggage_belt ? ` Bags on belt ${f.baggage_belt}.` : "";
      return {
        title: `${id} arrived at the gate`,
        body: `${gate}${inPlace(dest)}.${belt}`,
      };
    }
    case "cancel":
      return {
        title: `${id} canceled`,
        body: orig && dest
          ? `The flight from ${orig} to ${dest} was canceled.`
          : "The flight was canceled.",
      };
    case "reinstated": {
      const when = atOrig(f.estimated_out ?? f.scheduled_out);
      return {
        title: `${id} is back on the schedule`,
        body: `The airline reinstated the flight${
          orig && dest ? ` from ${orig} to ${dest}` : ""
        }.${when ? ` Departs at ${when}.` : ""}`,
      };
    }
    case "connection_at_risk": {
      // minutes: the layover now expected; from: the airport's usual minimum, in minutes.
      const next = ctx.onward
        ? displayIdent(ctx.onward.ident)
        : "your next flight";
      const hub = dest ? ` at ${dest}` : "";
      const layover = a.minutes ?? null;
      const mct = a.from ? Number(a.from) : NaN;
      if (layover === null || layover < GATE_CLOSE_MIN) {
        return {
          title: `${id} connection may be missed`,
          body:
            `${id} now lands too late to make ${next}${hub}. Open the app for other flights.`,
        };
      }
      return {
        title: `${id} connection at risk`,
        body: `Only ${span(layover)} to make ${next}${hub}${
          Number.isFinite(mct) ? `, where it usually takes ${span(mct)}` : ""
        }. Tell the crew you are connecting.`,
      };
    }
    case "diversion":
      return a.to
        ? {
          title: `${id} diverted to ${a.to}`,
          body: `The flight is landing at ${a.to}${
            a.from && a.from !== a.to ? ` instead of ${a.from}` : ""
          }.`,
        }
        : {
          title: `${id} diverted`,
          body:
            "The flight is landing at a different airport. Open the app for details.",
        };
    case "airport_program":
      return programText(a, id, ctx);
  }
}

/**
 * An FAA program at one end of the flight. At the destination a ground stop or ground delay program
 * holds the flight before it leaves; at the origin it says the airport is struggling. The end time is
 * the airport's own clock.
 */
function programText(a: Alert, id: string, ctx: CopyContext): AlertText {
  const p = a.program;
  if (!p) {
    return {
      title: `${id} may be delayed`,
      body: "The FAA is holding flights. Open the app for details.",
    };
  }
  const tz = p.end === "origin" ? ctx.originTz : ctx.destinationTz;
  const until = p.ends_at ? ` until ${clock(p.ends_at, tz)}` : "";
  const because = p.reason ? ` because of ${p.reason}` : "";
  const after = p.end === "destination"
    ? ` ${id} may leave late.`
    : " Departures may run late too.";
  switch (p.kind) {
    case "ground_stop":
      return {
        title: `Ground stop at ${p.code}`,
        body:
          `Flights to ${p.code} are held before take-off${because}${until}.${after}`,
      };
    case "ground_delay": {
      const avg = p.average_minutes
        ? `, about ${span(p.average_minutes)} on average`
        : "";
      return {
        title: `Ground delay program at ${p.code}`,
        body: `Flights to ${p.code} are held before take-off${avg}${
          avg && because ? "," : ""
        }${because}.${after}`,
      };
    }
    default:
      return {
        title: `${p.code} airport closed`,
        body:
          `The FAA lists ${p.code} as closed${until}. Check with your airline about ${id}.`,
      };
  }
}
