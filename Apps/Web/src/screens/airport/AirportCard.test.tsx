// @vitest-environment jsdom
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { MemoryRouter, Route, Routes } from "react-router";
import { airportDir } from "@/test/airportDir";

const fetchFavorites = vi.fn<() => Promise<string[]>>();
const fetchAirportWeather = vi.fn();
const fetchFaaStatus = vi.fn();
const setFavorite = vi.fn<(icao: string, on: boolean) => Promise<void>>();
const flightCategory = vi.fn<(c: number | null, v: number) => string>();

vi.mock("@/data/airports", async (orig) => ({
  ...(await orig<typeof import("@/data/airports")>()),
  fetchFavorites: () => fetchFavorites(),
  fetchAirportWeather: (c: string[]) => fetchAirportWeather(c),
  fetchFaaStatus: (c: string) => fetchFaaStatus(c),
  setFavorite: (i: string, on: boolean) => setFavorite(i, on),
}));
vi.mock("@/ui/airports", async (orig) => ({
  ...(await orig<typeof import("@/ui/airports")>()),
  useAirports: () => airportDir,
}));
vi.mock("@/core/flightcore", () => ({
  initCore: () => Promise.resolve(),
  flightCategory: (c: number | null, v: number) => flightCategory(c, v),
}));

import { AirportCard } from "./AirportCard";

const sfoWeather = {
  icao: "KSFO",
  iata: "SFO",
  weather: {
    category: "VFR", ceilingFt: 2500, visibilitySm: 8, windDirDeg: 290, windKt: 14, gustKt: 22, tempC: 17,
    wx: null, condition: "Mostly cloudy", summary: "Mostly cloudy with a breezy west wind.",
    observedAt: new Date(), stale: false,
  },
};

function show(code: string) {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  return render(
    <QueryClientProvider client={client}>
      <MemoryRouter initialEntries={[`/airport/${code}`]}>
        <Routes>
          <Route path="airport/:code" element={<AirportCard />} />
        </Routes>
      </MemoryRouter>
    </QueryClientProvider>,
  );
}

beforeEach(() => {
  vi.clearAllMocks();
  fetchFavorites.mockResolvedValue([]);
  fetchAirportWeather.mockResolvedValue([sfoWeather]);
  fetchFaaStatus.mockResolvedValue({
    available: true,
    programs: [{ kind: "ground_delay", reason: "low clouds", averageMinutes: 47, trend: null, startsAt: null, endsAt: null }],
  });
  flightCategory.mockReturnValue("MVFR");
  setFavorite.mockResolvedValue();
});
afterEach(cleanup);

describe("AirportCard", () => {
  it("shows the header: codes, name, city and the local time", async () => {
    show("KSFO");
    expect(await screen.findByRole("heading", { name: "San Francisco International Airport" })).toBeTruthy();
    expect(screen.getByText("SFO")).toBeTruthy();
    expect(screen.getByText("KSFO")).toBeTruthy();
    expect(screen.getByText(/San Francisco, United States/i)).toBeTruthy();
    expect(screen.getByTestId("airport-local-time").textContent).toMatch(/^\d\d:\d\d/);
  });

  it("an IATA code in the URL opens the same airport", async () => {
    show("sfo");
    expect(await screen.findByRole("heading", { name: "San Francisco International Airport" })).toBeTruthy();
    await waitFor(() => expect(fetchAirportWeather).toHaveBeenCalledWith(["KSFO"]));
  });

  it("shows the weather and the flight category computed by the core from ceiling and visibility", async () => {
    show("KSFO");
    expect(await screen.findByText("Mostly cloudy")).toBeTruthy();
    expect(await screen.findByText("MVFR")).toBeTruthy(); // the core's answer, not the feed's VFR
    expect(flightCategory).toHaveBeenCalledWith(2500, 8);
    expect(screen.getByText("17°C")).toBeTruthy();
    expect(screen.getByText(/14 kt/)).toBeTruthy();
    expect(screen.getByText(/22 kt/)).toBeTruthy();
  });

  it("shows the FAA programs for a US airport", async () => {
    show("KSFO");
    expect(await screen.findByText("Ground delay program")).toBeTruthy();
    expect(screen.getByText(/low clouds/)).toBeTruthy();
    expect(fetchFaaStatus).toHaveBeenCalledWith("KSFO");
  });

  it("hides the FAA block, and never asks, for a non-US airport", async () => {
    fetchAirportWeather.mockResolvedValue([{ ...sfoWeather, icao: "LFPG", iata: "CDG" }]);
    show("LFPG");
    expect(await screen.findByText("Mostly cloudy")).toBeTruthy();
    expect(screen.queryByTestId("faa-block")).toBeNull();
    expect(fetchFaaStatus).not.toHaveBeenCalled();
  });

  it("a failed weather or FAA read shows nothing in its place", async () => {
    fetchAirportWeather.mockRejectedValue(new Error("down"));
    fetchFaaStatus.mockRejectedValue(new Error("down"));
    show("KSFO");
    expect(await screen.findByRole("heading", { name: "San Francisco International Airport" })).toBeTruthy();
    await waitFor(() => expect(fetchFaaStatus).toHaveBeenCalled());
    expect(screen.queryByTestId("weather-block")).toBeNull();
    expect(screen.queryByTestId("faa-block")).toBeNull();
    expect(screen.queryByRole("alert")).toBeNull();
  });

  it("the star adds the airport to the favourites", async () => {
    show("KSFO");
    fireEvent.click(await screen.findByRole("button", { name: "Add to favorites" }));
    await waitFor(() => expect(setFavorite).toHaveBeenCalledWith("KSFO", true));
    expect(await screen.findByRole("button", { name: "Remove from favorites" })).toBeTruthy();
  });

  it("the star of a favourite removes it", async () => {
    fetchFavorites.mockResolvedValue(["KSFO"]);
    show("KSFO");
    fireEvent.click(await screen.findByRole("button", { name: "Remove from favorites" }));
    await waitFor(() => expect(setFavorite).toHaveBeenCalledWith("KSFO", false));
  });

  it("a failed write puts the star back", async () => {
    setFavorite.mockRejectedValue(new Error("no"));
    show("KSFO");
    fireEvent.click(await screen.findByRole("button", { name: "Add to favorites" }));
    await waitFor(() => expect(setFavorite).toHaveBeenCalled());
    expect(await screen.findByRole("button", { name: "Add to favorites" })).toBeTruthy();
  });
});
