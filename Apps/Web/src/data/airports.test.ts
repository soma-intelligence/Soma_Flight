import { beforeEach, describe, expect, it, vi } from "vitest";

const getSession = vi.fn();
const order = vi.fn();
const select = vi.fn(() => ({ order }));
const insert = vi.fn();
const eq2 = vi.fn();
const eq1 = vi.fn(() => ({ eq: eq2 }));
const del = vi.fn(() => ({ eq: eq1 }));
const from = vi.fn(() => ({ select, insert, delete: del }));
const callFunction = vi.fn();

vi.mock("./client", () => ({ getSupabase: () => ({ from, auth: { getSession } }) }));
vi.mock("./api", async (orig) => ({ ...(await orig<typeof import("./api")>()), callFunction: (...a: unknown[]) => callFunction(...a) }));

import {
  airportList,
  fetchAirportWeather,
  fetchFaaStatus,
  fetchFavorites,
  HUBS,
  isFaaCovered,
  setFavorite,
} from "./airports";

beforeEach(() => vi.clearAllMocks());

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

describe("favourites", () => {
  it("reads the signed-in user's favorite_airports, oldest first", async () => {
    order.mockResolvedValueOnce({ data: [{ airport_icao: "KSFO" }, { airport_icao: "LFPG" }], error: null });
    expect(await fetchFavorites()).toEqual(["KSFO", "LFPG"]);
    expect(from).toHaveBeenCalledWith("favorite_airports");
    expect(order).toHaveBeenCalledWith("created_at");
  });

  it("adding inserts the user's row", async () => {
    getSession.mockResolvedValueOnce({ data: { session: { user: { id: "u-1" } } } });
    insert.mockResolvedValueOnce({ error: null });
    await setFavorite("KSFO", true);
    expect(insert).toHaveBeenCalledWith({ user_id: "u-1", airport_icao: "KSFO" });
  });

  it("removing deletes that airport's row", async () => {
    getSession.mockResolvedValueOnce({ data: { session: { user: { id: "u-1" } } } });
    eq2.mockResolvedValueOnce({ error: null });
    await setFavorite("KSFO", false);
    expect(del).toHaveBeenCalled();
    expect(eq1).toHaveBeenCalledWith("user_id", "u-1");
    expect(eq2).toHaveBeenCalledWith("airport_icao", "KSFO");
  });

  it("a write error throws", async () => {
    getSession.mockResolvedValueOnce({ data: { session: { user: { id: "u-1" } } } });
    insert.mockResolvedValueOnce({ error: { code: "54000", message: "too many favorite airports" } });
    await expect(setFavorite("KSFO", true)).rejects.toThrow();
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
