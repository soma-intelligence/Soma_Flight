import { parseAirportInfo } from "@/ui/airports";

/** A few rows of the shared airport table, for screen tests (ICAO, IATA, name, city, country, lat, lon, zone). */
export const airportDir = parseAirportInfo(
  [
    "KSFO\tSFO\tSan Francisco International Airport\tSan Francisco\tUS\t37.6189\t-122.3750\tAmerica/Los_Angeles",
    "LFPG\tCDG\tParis Charles de Gaulle Airport\tParis\tFR\t49.0097\t2.5479\tEurope/Paris",
    "KJFK\tJFK\tJohn F Kennedy International Airport\tNew York\tUS\t40.6398\t-73.7789\tAmerica/New_York",
    "EGLL\tLHR\tLondon Heathrow Airport\tLondon\tGB\t51.4706\t-0.4619\tEurope/London",
  ].join("\n"),
);
