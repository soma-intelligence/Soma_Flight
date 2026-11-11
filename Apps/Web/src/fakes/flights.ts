import type { Flight, FollowedFlight } from "@/data/types";

export const FAKE_FLIGHT_MARKER = "FAKE_FLIGHT_MARKER";

const H = 3600_000;

type Seed = Partial<Flight> &
  Pick<Flight, "id" | "ident" | "originIcao" | "destinationIcao" | "status">;

function make(now: Date, s: Seed): Flight {
  const t = (offsetH: number | null) => (offsetH === null ? null : new Date(now.getTime() + offsetH * H));
  return {
    providerId: `${FAKE_FLIGHT_MARKER}-${s.ident}`,
    operator: null,
    originIata: null,
    destinationIata: null,
    scheduledOut: t(0),
    scheduledIn: t(5),
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
    position: null,
    updatedAt: now,
    ...s,
  };
}

/** Six flights relative to `now`: one in the air, three upcoming (today, tomorrow, in a few days), two landed. */
export function fakeFlights(now: Date = new Date()): Flight[] {
  const at = (h: number) => new Date(now.getTime() + h * H);
  return [
    make(now, {
      id: "f0000000-0000-4000-8000-000000000001",
      ident: "UA85",
      operator: "UAL",
      originIcao: "KSFO",
      originIata: "SFO",
      destinationIcao: "KJFK",
      destinationIata: "JFK",
      status: "en_route",
      scheduledOut: at(-2.5),
      scheduledIn: at(2.5),
      actualOut: at(-2.4),
      actualOff: at(-2.2),
      estimatedIn: at(2.6),
      gateOrigin: "F11",
      terminalOrigin: "3",
      gateDestination: "C34",
      terminalDestination: "7",
      aircraftType: "B789",
      registration: "N29961",
      position: { lat: 40.4, lon: -98.7, altitudeFt: 38000, groundSpeedKt: 492, heading: 82, at: at(-0.02) },
    }),
    make(now, {
      id: "f0000000-0000-4000-8000-000000000002",
      ident: "AF65",
      operator: "AFR",
      originIcao: "LFPG",
      originIata: "CDG",
      destinationIcao: "KLAX",
      destinationIata: "LAX",
      status: "scheduled",
      scheduledOut: at(3),
      scheduledIn: at(14),
      estimatedOut: at(3.4),
      gateOrigin: "K43",
      terminalOrigin: "2E",
      aircraftType: "A388",
    }),
    make(now, {
      id: "f0000000-0000-4000-8000-000000000003",
      ident: "BA286",
      operator: "BAW",
      originIcao: "EGLL",
      originIata: "LHR",
      destinationIcao: "KSFO",
      destinationIata: "SFO",
      status: "scheduled",
      scheduledOut: at(26),
      scheduledIn: at(37),
      terminalOrigin: "5",
      aircraftType: "B772",
    }),
    make(now, {
      id: "f0000000-0000-4000-8000-000000000004",
      ident: "NH105",
      operator: "ANA",
      originIcao: "RJTT",
      originIata: "HND",
      destinationIcao: "KLAX",
      destinationIata: "LAX",
      status: "scheduled",
      scheduledOut: at(72),
      scheduledIn: at(81),
      aircraftType: "B789",
    }),
    make(now, {
      id: "f0000000-0000-4000-8000-000000000005",
      ident: "DL401",
      operator: "DAL",
      originIcao: "KJFK",
      originIata: "JFK",
      destinationIcao: "KSFO",
      destinationIata: "SFO",
      status: "landed",
      scheduledOut: at(-30),
      scheduledIn: at(-24.5),
      actualOut: at(-29.8),
      actualOff: at(-29.5),
      actualOn: at(-24.7),
      actualIn: at(-24.6),
      gateDestination: "E7",
      baggageBelt: "3",
      aircraftType: "A321",
    }),
    make(now, {
      id: "f0000000-0000-4000-8000-000000000006",
      ident: "LH455",
      operator: "DLH",
      originIcao: "EDDF",
      originIata: "FRA",
      destinationIcao: "EGLL",
      destinationIata: "LHR",
      status: "arrived",
      scheduledOut: at(-70),
      scheduledIn: at(-68.6),
      actualOut: at(-69.9),
      actualOn: at(-68.7),
      actualIn: at(-68.6),
      aircraftType: "A320",
    }),
  ];
}

export function fakeFollowed(now: Date = new Date()): FollowedFlight[] {
  return fakeFlights(now).map((flight, i) => ({
    createdAt: new Date(now.getTime() - (i + 1) * 24 * H),
    flight,
  }));
}
