// @vitest-environment jsdom
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { MemoryRouter, Route, Routes, useLocation } from "react-router";
import type { Friend, FriendFlight, FriendInvite, FriendsMe } from "@/data/friends";
import { airportDir } from "@/test/airportDir";
import { ua990 } from "@/test/flight";

const fetchFriends = vi.fn<() => Promise<Friend[]>>();
const fetchFriendsMe = vi.fn<() => Promise<FriendsMe>>();
const fetchFriendFlights = vi.fn<(id: string | null) => Promise<FriendFlight[]>>();
const createInvite = vi.fn<() => Promise<FriendInvite>>();

vi.mock("@/data/friends", async (orig) => ({
  ...(await orig<typeof import("@/data/friends")>()),
  fetchFriends: () => fetchFriends(),
  fetchFriendsMe: () => fetchFriendsMe(),
  fetchFriendFlights: (id: string | null) => fetchFriendFlights(id),
  createInvite: () => createInvite(),
}));
vi.mock("@/ui/airports", async (orig) => ({
  ...(await orig<typeof import("@/ui/airports")>()),
  useAirports: () => airportDir,
}));

import { Friends } from "./Friends";

const maya: Friend = {
  id: "a-1",
  displayName: "Maya",
  emoji: "🌿",
  since: new Date("2026-08-01T10:00:00Z"),
  shareFlights: true,
  sharePassport: false,
  alerts: false,
  sharesFlights: true,
  sharesPassport: false,
};

function Where() {
  return <p data-testid="where">{useLocation().pathname}</p>;
}

function show() {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  return render(
    <QueryClientProvider client={client}>
      <MemoryRouter initialEntries={["/friends"]}>
        <Routes>
          <Route path="friends" element={<Friends />} />
          <Route path="friend/:id" element={<Where />} />
        </Routes>
      </MemoryRouter>
    </QueryClientProvider>,
  );
}

const writeText = vi.fn<(t: string) => Promise<void>>();

beforeEach(() => {
  vi.clearAllMocks();
  writeText.mockResolvedValue();
  Object.defineProperty(navigator, "clipboard", { value: { writeText }, configurable: true });
  fetchFriendsMe.mockResolvedValue({ friendCode: "K7M2X9QP", sharingPaused: false, displayName: "Quentin", emoji: null });
  fetchFriendFlights.mockResolvedValue([]);
  createInvite.mockResolvedValue({ id: "i-1", url: "https://somalabs.me/i/abc123", expiresAt: new Date("2026-11-18T00:00:00Z") });
});
afterEach(cleanup);

describe("Friends", () => {
  it("lists friends with their next flight and opens a friend's card", async () => {
    fetchFriends.mockResolvedValue([maya]);
    fetchFriendFlights.mockResolvedValue([{ friendId: "a-1", flight: ua990({ status: "en_route" }) }]);
    show();
    const row = await screen.findByTestId("friend-row");
    expect(row.textContent).toContain("Maya");
    await waitFor(() => expect(row.textContent).toContain("UA 990 · San Francisco → Paris"));
    expect(row.textContent).toContain("in the air");
    expect(screen.getByRole("region", { name: "In the Air" })).toBeTruthy();
    fireEvent.click(row);
    expect(screen.getByTestId("where").textContent).toBe("/friend/a-1");
  });

  it("copy link makes an invitation and puts the somalabs.me link on the clipboard", async () => {
    fetchFriends.mockResolvedValue([maya]);
    show();
    fireEvent.click(await screen.findByRole("button", { name: /Copy Invitation Link/ }));
    await waitFor(() => expect(writeText).toHaveBeenCalledWith("https://somalabs.me/i/abc123"));
    expect(createInvite).toHaveBeenCalledTimes(1);
    expect(await screen.findByRole("button", { name: /Link Copied/ })).toBeTruthy();
  });

  it("copies the friend code", async () => {
    fetchFriends.mockResolvedValue([maya]);
    show();
    expect(await screen.findByText("K7M2 X9QP")).toBeTruthy();
    fireEvent.click(screen.getByRole("button", { name: /Copy Code/ }));
    await waitFor(() => expect(writeText).toHaveBeenCalledWith("K7M2X9QP"));
  });

  it("keeps the link on screen when the clipboard refuses", async () => {
    fetchFriends.mockResolvedValue([maya]);
    writeText.mockRejectedValue(new Error("denied"));
    show();
    fireEvent.click(await screen.findByRole("button", { name: /Copy Invitation Link/ }));
    expect((await screen.findByText(/https:\/\/somalabs\.me\/i\/abc123/)).textContent).toContain("Couldn't copy it");
  });

  it("with no friend shows the invitation, and Invite a Friend copies a link", async () => {
    fetchFriends.mockResolvedValue([]);
    show();
    const empty = await screen.findByTestId("friends-empty");
    expect(empty.textContent).toContain("Fly apart, stay close");
    fireEvent.click(screen.getByRole("button", { name: "Invite a Friend" }));
    await waitFor(() => expect(writeText).toHaveBeenCalledWith("https://somalabs.me/i/abc123"));
  });

  it("shows the app's error copy and a retry when the list cannot load", async () => {
    fetchFriends.mockRejectedValue(Object.assign(new Error("x"), { code: "provider_unavailable" }));
    show();
    expect((await screen.findByRole("alert")).textContent).toContain("temporarily unavailable");
    expect(screen.queryByTestId("friends-empty")).toBeNull();
  });
});
