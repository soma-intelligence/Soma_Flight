export type FlightStatus =
  | "scheduled"
  | "departed"
  | "en_route"
  | "landed"
  | "arrived"
  | "canceled"
  | "diverted"
  | "unknown";

export type Position = {
  lat: number;
  lon: number;
  altitudeFt: number | null;
  groundSpeedKt: number | null;
  heading: number | null;
  at: Date;
};

/** The `flights` table row, camelCase, dates as Date. */
export type Flight = {
  id: string;
  providerId: string;
  ident: string;
  operator: string | null;
  originIcao: string;
  originIata: string | null;
  destinationIcao: string;
  destinationIata: string | null;
  scheduledOut: Date | null;
  scheduledIn: Date | null;
  estimatedOut: Date | null;
  estimatedIn: Date | null;
  scheduledOff: Date | null;
  scheduledOn: Date | null;
  estimatedOff: Date | null;
  estimatedOn: Date | null;
  actualOut: Date | null;
  actualOff: Date | null;
  actualOn: Date | null;
  actualIn: Date | null;
  gateOrigin: string | null;
  gateDestination: string | null;
  terminalOrigin: string | null;
  terminalDestination: string | null;
  baggageBelt: string | null;
  aircraftType: string | null;
  registration: string | null;
  status: FlightStatus;
  position: Position | null;
  updatedAt: Date;
};

export type FollowedFlight = { createdAt: Date; flight: Flight };
