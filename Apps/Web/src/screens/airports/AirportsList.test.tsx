// @vitest-environment jsdom
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { cleanup, fireEvent, render, screen, within } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { MemoryRouter, Route, Routes, useLocation } from "react-router";
import { airportDir } from "@/test/airportDir";

const fetchFavorites = vi.fn<() => Promise<string[]>>();
const fetchAirportWeather = vi.fn();

vi.mock("@/data/airports", async (orig) => ({
  ...(await orig<typeof import("@/data/airports")>()),
  fetchFavorites: () => fetchFavorites(),
  fetchAirportWeather: (c: string[]) => fetchAirportWeather(c),
}));
vi.mock("@/ui/airports", async (orig) => ({
  ...(await orig<typeof import("@/ui/airports")>()),
  useAirports: () => airportDir,
}));

import { AirportsList } from "./AirportsList";

function Where() {
  return <p data-testid="where">{useLocation().pathname}</p>;
}

function show() {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  return render(
    <QueryClientProvider client={client}>
      <MemoryRouter initialEntries={["/airports"]}>
        <Routes>
          <Route path="airports" element={<AirportsList />} />
          <Route path="airport/:code" element={<Where />} />
        </Routes>
      </MemoryRouter>
    </QueryClientProvider>,
  );
}

beforeEach(() => {
  vi.clearAllMocks();
  fetchAirportWeather.mockResolvedValue([]);
});
afterEach(cleanup);

describe("AirportsList", () => {
  it("lists favourites first under their own heading, then the busiest hubs, each with code, name and city", async () => {
    fetchFavorites.mockResolvedValue(["LFPG", "EGLL"]);
    show();
    const favs = await screen.findByRole("region", { name: "Favorites" });
    const rows = within(favs).getAllByRole("button");
    expect(rows).toHaveLength(2);
    expect(rows[0].textContent).toContain("CDG");
    expect(rows[0].textContent).toContain("Paris Charles de Gaulle Airport");
    expect(rows[0].textContent).toContain("Paris");
    expect(rows[1].textContent).toContain("LHR");
    const hubs = screen.getByRole("region", { name: "Busiest hubs" });
    const hubRows = within(hubs).getAllByRole("button").map((r) => r.textContent ?? "");
    expect(hubRows.some((t) => t.includes("SFO") && t.includes("San Francisco"))).toBe(true);
    expect(hubRows.some((t) => t.includes("CDG"))).toBe(false); // a favourite is not listed twice
  });

  it("without favourites shows only the hubs", async () => {
    fetchFavorites.mockResolvedValue([]);
    show();
    expect(await screen.findByRole("region", { name: "Busiest hubs" })).toBeTruthy();
    expect(screen.queryByRole("region", { name: "Favorites" })).toBeNull();
  });

  it("a row opens the airport card over the list", async () => {
    fetchFavorites.mockResolvedValue(["KSFO"]);
    show();
    const favs = await screen.findByRole("region", { name: "Favorites" });
    fireEvent.click(within(favs).getAllByRole("button")[0]);
    expect((await screen.findByTestId("where")).textContent).toBe("/airport/KSFO");
  });

  it("a row shows the flight category when the weather came, and nothing when it did not", async () => {
    fetchFavorites.mockResolvedValue(["KSFO", "LFPG"]);
    fetchAirportWeather.mockResolvedValue([
      { icao: "KSFO", iata: "SFO", weather: { category: "MVFR", tempC: 17, windKt: 9, gustKt: null } },
      { icao: "LFPG", iata: "CDG", weather: null },
    ]);
    show();
    const favs = await screen.findByRole("region", { name: "Favorites" });
    const [sfo, cdg] = within(favs).getAllByRole("button");
    expect(await within(sfo).findByText("MVFR")).toBeTruthy();
    expect(within(cdg).queryByText(/VFR|IFR/)).toBeNull();
  });

  it("a failed favourites read still lists the hubs", async () => {
    fetchFavorites.mockRejectedValue(new Error("x"));
    show();
    expect(await screen.findByRole("region", { name: "Busiest hubs" })).toBeTruthy();
  });
});
