// @vitest-environment jsdom
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { MemoryRouter, Route, Routes, useLocation } from "react-router";
import type { Friend, FriendFlight } from "@/data/friends";
import { airportDir } from "@/test/airportDir";
import { ua990 } from "@/test/flight";

const fetchFriends = vi.fn<() => Promise<Friend[]>>();
const fetchFriendFlights = vi.fn<(id: string | null) => Promise<FriendFlight[]>>();

vi.mock("@/data/friends", async (orig) => ({
  ...(await orig<typeof import("@/data/friends")>()),
  fetchFriends: () => fetchFriends(),
  fetchFriendFlights: (id: string | null) => fetchFriendFlights(id),
}));
vi.mock("@/ui/airports", async (orig) => ({
  ...(await orig<typeof import("@/ui/airports")>()),
  useAirports: () => airportDir,
}));

import { FriendCard } from "./FriendCard";

const theo: Friend = {
  id: "t-1",
  displayName: "Theo Martin",
  emoji: null,
  since: new Date("2026-10-15T12:00:00Z"),
  shareFlights: true,
  sharePassport: false,
  alerts: false,
  sharesFlights: true,
  sharesPassport: false,
};

function Where() {
  return <p data-testid="where">{useLocation().pathname}</p>;
}

function show(id = "t-1") {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  return render(
    <QueryClientProvider client={client}>
      <MemoryRouter initialEntries={[`/friend/${id}`]}>
        <Routes>
          <Route path="friend/:id" element={<FriendCard />} />
          <Route path="friend/:fid/flight/:id" element={<Where />} />
        </Routes>
      </MemoryRouter>
    </QueryClientProvider>,
  );
}

beforeEach(() => vi.clearAllMocks());
afterEach(cleanup);

describe("FriendCard", () => {
  it("shows the friend's name and the flights the server returns as flight rows", async () => {
    fetchFriends.mockResolvedValue([theo]);
    fetchFriendFlights.mockResolvedValue([{ friendId: "t-1", flight: ua990() }]);
    show();
    expect((await screen.findByRole("heading", { name: "Theo Martin" })).textContent).toBe("Theo Martin");
    expect(screen.getByText("Friends since October 2026")).toBeTruthy();
    expect(fetchFriendFlights).toHaveBeenCalledWith("t-1");
    const row = await screen.findByTestId("flight-row");
    fireEvent.click(row);
    expect(screen.getByTestId("where").textContent).toBe("/friend/t-1/flight/00000000-0000-4000-8000-000000000990");
  });

  it("says nothing is coming up, or that the friend is not sharing", async () => {
    fetchFriends.mockResolvedValue([theo]);
    fetchFriendFlights.mockResolvedValue([]);
    show();
    expect(await screen.findByText("Nothing coming up.")).toBeTruthy();
    cleanup();
    fetchFriends.mockResolvedValue([{ ...theo, sharesFlights: false }]);
    show();
    expect(await screen.findByText("Theo Martin is not sharing flights with you right now.")).toBeTruthy();
  });

  it("says so when the friend is gone", async () => {
    fetchFriends.mockResolvedValue([theo]);
    fetchFriendFlights.mockResolvedValue([]);
    show("nobody");
    await waitFor(() => expect(screen.getByRole("heading").textContent).toBe("No longer friends"));
  });
});
