import type { Flight } from "@/data/types";

const d = (s: string) => new Date(s);

/** UA 990, SFO 15:20 Friday 30 October 2026 to CDG 10:15 the next morning (MyFlightRowTests.ua990). */
export function ua990(over: Partial<Flight> = {}): Flight {
  return {
    id: "00000000-0000-4000-8000-000000000990",
    providerId: "p",
    ident: "UA990",
    operator: "UAL",
    originIcao: "KSFO",
    originIata: "SFO",
    destinationIcao: "LFPG",
    destinationIata: "CDG",
    scheduledOut: d("2026-10-30T22:20:00Z"),
    scheduledIn: d("2026-10-31T09:15:00Z"),
    estimatedOut: null,
    estimatedIn: null,
    scheduledOff: null,
    scheduledOn: null,
    estimatedOff: null,
    estimatedOn: null,
    actualOut: null,
    actualOff: null,
    actualOn: null,
    actualIn: null,
    gateOrigin: null,
    gateDestination: null,
    terminalOrigin: null,
    terminalDestination: null,
    baggageBelt: null,
    aircraftType: null,
    registration: null,
    status: "scheduled",
    position: null,
    updatedAt: d("2026-10-30T12:00:00Z"),
    ...over,
  };
}

