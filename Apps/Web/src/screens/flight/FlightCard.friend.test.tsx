// @vitest-environment jsdom
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { cleanup, render, screen } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { MemoryRouter, Route, Routes } from "react-router";
import type { FriendFlight } from "@/data/friends";
import type { Flight, FollowedFlight } from "@/data/types";
import { ua990 } from "@/test/flight";

const fetchFriendFlights = vi.fn<(id: string | null) => Promise<FriendFlight[]>>();
const subscribeFlights = vi.fn(() => () => {});

vi.mock("@/data/flights", () => ({
  myFlightsKey: ["myFlights"],
  flightKey: (id: string) => ["flight", id],
  fetchFlight: () => Promise.resolve(null),
  fetchMyFlights: () => Promise.resolve([] as FollowedFlight[]),
  followFlight: () => Promise.resolve(),
  unfollowFlight: () => Promise.resolve(),
  useFakes: () => false,
}));
vi.mock("@/data/friends", async (orig) => ({
  ...(await orig<typeof import("@/data/friends")>()),
  fetchFriendFlights: (id: string | null) => fetchFriendFlights(id),
}));
vi.mock("@/data/realtime", () => ({ subscribeFlights: () => subscribeFlights() }));

import { FlightCard } from "./FlightCard";

function show(path: string, seed?: Flight) {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  if (seed) client.setQueryData(["friendFlights", "t-1"], [{ friendId: "t-1", flight: seed }]);
  return render(
    <QueryClientProvider client={client}>
      <MemoryRouter initialEntries={[path]}>
        <Routes>
          <Route path="/friend/:fid/flight/:id" element={<FlightCard />} />
        </Routes>
      </MemoryRouter>
    </QueryClientProvider>,
  );
}

beforeEach(() => {
  vi.clearAllMocks();
  fetchFriendFlights.mockResolvedValue([{ friendId: "t-1", flight: ua990() }]);
});
afterEach(cleanup);

describe("FlightCard opened from a friend", () => {
  it("shows the friend's flight, fetched when the page's cache is absent, with no Follow and no subscription", async () => {
    show("/friend/t-1/flight/00000000-0000-4000-8000-000000000990");
    expect(await screen.findByTestId("flight-card")).toBeTruthy();
    expect(await screen.findByText(/UA\s?990/)).toBeTruthy();
    expect(fetchFriendFlights).toHaveBeenCalledWith("t-1");
    expect(screen.queryByRole("button", { name: "Follow" })).toBeNull();
    expect(screen.queryByRole("button", { name: "Stop Following" })).toBeNull();
    expect(subscribeFlights).not.toHaveBeenCalled();
  });

  it("uses the cached friend flights without fetching", async () => {
    show("/friend/t-1/flight/00000000-0000-4000-8000-000000000990", ua990());
    expect(await screen.findByText(/UA\s?990/)).toBeTruthy();
    expect(fetchFriendFlights).not.toHaveBeenCalled();
  });
});
