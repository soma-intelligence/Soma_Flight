import type { AirportConditions, AirportWeather, FaaStatus } from "@/data/airports";

/** What fakes mode starts with when the browser has no favourites yet. */
export const fakeFavorites = (): string[] => ["KSFO", "LFPG"];

const KSFO: AirportConditions = {
  category: "MVFR",
  ceilingFt: 2500,
  visibilitySm: 8,
  windDirDeg: 290,
  windKt: 14,
  gustKt: 22,
  tempC: 17,
  wx: null,
  condition: "Mostly cloudy",
  summary: "Mostly cloudy with a breezy west wind.",
  observedAt: new Date(Date.now() - 12 * 60_000),
  stale: false,
};
const LFPG: AirportConditions = {
  category: "IFR",
  ceilingFt: 900,
  visibilitySm: 4,
  windDirDeg: 220,
  windKt: 8,
  gustKt: null,
  tempC: 11,
  wx: "-RA",
  condition: "Light rain",
  summary: "Light rain with a gentle wind.",
  observedAt: new Date(Date.now() - 20 * 60_000),
  stale: false,
};
const GENERIC: AirportConditions = {
  category: "VFR",
  ceilingFt: null,
  visibilitySm: 10,
  windDirDeg: 270,
  windKt: 7,
  gustKt: null,
  tempC: 20,
  wx: null,
  condition: "Clear skies",
  summary: "Clear skies with light winds.",
  observedAt: new Date(Date.now() - 8 * 60_000),
  stale: false,
};

/** METAR-like weather for any code; LFPG has no reading to show the failed-METAR case. */
export function fakeWeather(codes: readonly string[]): AirportWeather[] {
  return codes.map((c) => {
    const icao = c.toUpperCase();
    const weather = icao === "KSFO" ? KSFO : icao === "LFPG" ? LFPG : icao === "EGLL" ? null : GENERIC;
    return { icao, iata: null, weather };
  });
}

/** One US airport (SFO) with a ground delay program; the others calm. */
export function fakeFaa(code: string): FaaStatus {
  const c = code.toUpperCase();
  if (c !== "KSFO" && c !== "SFO") return { available: true, programs: [] };
  const now = Date.now();
  return {
    available: true,
    programs: [
      {
        kind: "ground_delay",
        reason: "low clouds",
        averageMinutes: 47,
        trend: null,
        startsAt: new Date(now - 2 * 3600_000),
        endsAt: new Date(now + 6 * 3600_000),
      },
    ],
  };
}
