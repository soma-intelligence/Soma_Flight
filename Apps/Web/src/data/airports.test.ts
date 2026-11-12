// @vitest-environment jsdom
import { beforeEach, describe, expect, it, vi } from "vitest";

const callFunction = vi.fn();

vi.mock("./api", async (orig) => ({ ...(await orig<typeof import("./api")>()), callFunction: (...a: unknown[]) => callFunction(...a) }));

import {
  airportList,
  airportWeatherKey,
  fetchAirportWeather,
  fetchFaaStatus,
  FAVORITES_KEY,
  fetchFavorites,
  HUBS,
  isFaaCovered,
  setFavorite,
} from "./airports";

beforeEach(() => {
  vi.clearAllMocks();
  localStorage.clear();
});

describe("airportList", () => {
  it("puts favourites first, then the hubs, each code once, only codes the directory knows", () => {
    const known = (c: string) => c !== "KDEN" && c !== "ZZZZ";
    const list = airportList(["LFPG", "KSFO", "ZZZZ"], known);
    expect(list.slice(0, 2)).toEqual(["LFPG", "KSFO"]);
    expect(list).not.toContain("ZZZZ");
    expect(list).not.toContain("KDEN");
    expect(list.filter((c) => c === "KSFO")).toHaveLength(1);
    expect(list).toContain("KATL");
    expect(HUBS).toContain("KATL");
  });
});

describe("favourites (this browser only)", () => {
  it("starts empty", async () => {
    expect(await fetchFavorites()).toEqual([]);
  });

  it("adding persists the code in localStorage, upper case, once", async () => {
    await setFavorite("ksfo", true);
    await setFavorite("KSFO", true);
    await setFavorite("LFPG", true);
    expect(JSON.parse(localStorage.getItem(FAVORITES_KEY)!)).toEqual(["KSFO", "LFPG"]);
    expect(await fetchFavorites()).toEqual(["KSFO", "LFPG"]);
  });

  it("removing takes it out", async () => {
    localStorage.setItem(FAVORITES_KEY, JSON.stringify(["KSFO", "LFPG"]));
    await setFavorite("KSFO", false);
    expect(await fetchFavorites()).toEqual(["LFPG"]);
  });

  it("a corrupt value reads as empty and the next write replaces it", async () => {
    localStorage.setItem(FAVORITES_KEY, "{not json");
    expect(await fetchFavorites()).toEqual([]);
    localStorage.setItem(FAVORITES_KEY, JSON.stringify({ a: 1 }));
    expect(await fetchFavorites()).toEqual([]);
    await setFavorite("KSFO", true);
    expect(await fetchFavorites()).toEqual(["KSFO"]);
  });

  it("storage that throws gives an empty list and never throws", async () => {
    const get = vi.spyOn(Storage.prototype, "getItem").mockImplementation(() => {
      throw new Error("blocked");
    });
    const set = vi.spyOn(Storage.prototype, "setItem").mockImplementation(() => {
      throw new Error("blocked");
    });
    expect(await fetchFavorites()).toEqual([]);
    await expect(setFavorite("KSFO", true)).resolves.toBeUndefined();
    get.mockRestore();
    set.mockRestore();
  });

  it("never reads or writes the favorite_airports table", async () => {
    await setFavorite("KSFO", true);
    await fetchFavorites();
    expect(callFunction).not.toHaveBeenCalled();
  });
});

describe("airportWeatherKey", () => {
  it("is the same for any order and duplicates", () => {
    expect(airportWeatherKey(["KSFO", "LFPG"])).toEqual(airportWeatherKey(["LFPG", "KSFO", "KSFO"]));
    expect(airportWeatherKey(["KSFO"])).not.toEqual(airportWeatherKey(["KSFO", "LFPG"]));
  });
});

describe("airport-weather", () => {
  it("asks for the comma list and decodes the METAR, leaving a failed one null", async () => {
    callFunction.mockResolvedValueOnce({
      fetched_at: "2026-10-31T20:10:00.000Z",
      airports: [
        {
          icao: "KSFO",
          iata: "SFO",
          weather: {
            category: "VFR", ceiling_ft: null, visibility_sm: 10, wind_dir_deg: 290, wind_kt: 9, gust_kt: null,
            temp_c: 17, wx: null, condition: "Partly cloudy", summary: "Partly cloudy with light winds.",
            observed_at: "2026-10-31T20:00:00.000Z", metar_raw: "METAR KSFO", stale: false,
          },
          faa: null,
        },
        { icao: "EGLL", iata: "LHR", weather: null, faa: null },
      ],
    });
    const out = await fetchAirportWeather(["KSFO", "EGLL"]);
    expect(callFunction).toHaveBeenCalledWith("airport-weather", { method: "GET", query: { airports: "KSFO,EGLL" } });
    expect(out[0].weather).toMatchObject({ ceilingFt: null, visibilitySm: 10, windKt: 9, tempC: 17, condition: "Partly cloudy" });
    expect(out[0].weather?.observedAt).toEqual(new Date("2026-10-31T20:00:00.000Z"));
    expect(out[1].weather).toBeNull();
  });

  it("batches of more than 40 codes become several calls", async () => {
    callFunction.mockResolvedValue({ airports: [] });
    await fetchAirportWeather(Array.from({ length: 45 }, (_, i) => `K${i}`));
    expect(callFunction).toHaveBeenCalledTimes(2);
  });
});

describe("faa-status", () => {
  it("decodes the programs and drops what it does not know", async () => {
    callFunction.mockResolvedValueOnce({
      airport: "KSFO", iata: "SFO", available: true, reason: null, stale: false,
      programs: [
        { kind: "ground_delay", reason: "low clouds", average_minutes: 47, starts_at: "2026-10-31T16:00:00Z", ends_at: null },
        { kind: "mystery", reason: null },
      ],
    });
    const s = await fetchFaaStatus("KSFO");
    expect(callFunction).toHaveBeenCalledWith("faa-status", { method: "GET", query: { airport: "KSFO" } });
    expect(s.available).toBe(true);
    expect(s.programs).toHaveLength(1);
    expect(s.programs[0]).toMatchObject({ kind: "ground_delay", reason: "low clouds", averageMinutes: 47, endsAt: null });
  });

  it("covers the US and its territories only", () => {
    for (const c of ["US", "PR", "GU", "VI", "AS", "MP"]) expect(isFaaCovered(c)).toBe(true);
    expect(isFaaCovered("FR")).toBe(false);
  });
});
