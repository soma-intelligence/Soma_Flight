// @vitest-environment jsdom
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { act, cleanup, render, screen, within } from "@testing-library/react";
import { QueryClientProvider } from "@tanstack/react-query";
import { MemoryRouter } from "react-router";
import { makeQueryClient } from "@/app/query";
import type { Flight, FollowedFlight } from "@/data/types";
import { ua990 } from "@/ui/testFlight";

const fetchMyFlights = vi.fn<() => Promise<FollowedFlight[]>>();
let onRow: ((f: Flight) => void) | null = null;
const subscribeFlights = vi.fn((_ids: string[], cb: (f: Flight) => void) => {
  onRow = cb;
  return () => {
    onRow = null;
  };
});

vi.mock("@/data/flights", () => ({
  myFlightsKey: ["myFlights"],
  flightKey: (id: string) => ["flight", id],
  fetchMyFlights: () => fetchMyFlights(),
  useFakes: () => false,
}));
vi.mock("@/data/realtime", () => ({
  subscribeFlights: (ids: string[], cb: (f: Flight) => void) => subscribeFlights(ids, cb),
}));

import { MyFlights } from "./MyFlights";

const H = 3600_000;

function show() {
  return render(
    <QueryClientProvider client={makeQueryClient()}>
      <MemoryRouter>
        <MyFlights />
      </MemoryRouter>
    </QueryClientProvider>,
  );
}

beforeEach(() => {
  vi.clearAllMocks();
  onRow = null;
});
afterEach(cleanup);

describe("MyFlights", () => {
  it("shows the empty state with the jet illustration when there are no rows", async () => {
    fetchMyFlights.mockResolvedValue([]);
    show();
    expect(await screen.findByText("Where to next?")).toBeTruthy();
    expect(screen.getByTestId("empty-jet")).toBeTruthy();
    expect(screen.getByText("Add a flight you're taking by number, route or airport.")).toBeTruthy();
    expect(screen.getByRole("button", { name: "Search" })).toBeTruthy();
  });

  it("a realtime row update moves a flight from Upcoming to In the Air without a reload", async () => {
    const now = Date.now();
    const f = ua990({ scheduledOut: new Date(now + 2 * H), scheduledIn: new Date(now + 7 * H) });
    fetchMyFlights.mockResolvedValue([{ createdAt: new Date(now - H), flight: f }]);
    show();
    const upcoming = await screen.findByRole("region", { name: "Upcoming" });
    expect(within(upcoming).getAllByTestId("flight-row")).toHaveLength(1);
    expect(screen.queryByRole("region", { name: "In the Air" })).toBeNull();
    expect(subscribeFlights).toHaveBeenCalledWith([f.id], expect.any(Function));

    act(() => onRow!({ ...f, status: "en_route", actualOut: new Date(now - 60_000) }));

    const air = await screen.findByRole("region", { name: "In the Air" });
    expect(within(air).getAllByTestId("flight-row")).toHaveLength(1);
    expect(screen.queryByRole("region", { name: "Upcoming" })).toBeNull();
    expect(fetchMyFlights).toHaveBeenCalledTimes(1);
  });

  it("groups rows under caps headers with their counts", async () => {
    const now = Date.now();
    const at = (id: string, h: number) =>
      ua990({ id, scheduledOut: new Date(now + h * H), scheduledIn: new Date(now + (h + 3) * H) });
    fetchMyFlights.mockResolvedValue([
      { createdAt: new Date(now), flight: at("a", 2) },
      { createdAt: new Date(now), flight: at("b", 30) },
    ]);
    show();
    const upcoming = await screen.findByRole("region", { name: "Upcoming" });
    expect(within(upcoming).getByText("2 flights")).toBeTruthy();
  });

  it("a failed load with nothing shown keeps the error banner and its retry", async () => {
    fetchMyFlights.mockRejectedValue(Object.assign(new Error("x"), { code: "provider_unavailable" }));
    show();
    expect(await screen.findByRole("alert", undefined, { timeout: 4000 })).toBeTruthy();
    expect(screen.getByRole("button", { name: "Try again" })).toBeTruthy();
    expect(screen.queryByText("Where to next?")).toBeNull();
  });
});
