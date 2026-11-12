import { beforeEach, describe, expect, it, vi } from "vitest";

const rpc = vi.fn();
const callFunction = vi.fn();

vi.mock("./client", () => ({ getSupabase: () => ({ rpc }) }));
vi.mock("./api", async (orig) => ({ ...(await orig<typeof import("./api")>()), callFunction: (...a: unknown[]) => callFunction(...a) }));

import {
  createInvite,
  decodeFriend,
  fetchFriendFlights,
  fetchFriends,
  fetchFriendsMe,
  friendInitials,
  friendName,
  spacedCode,
} from "./friends";

beforeEach(() => vi.clearAllMocks());

const row = {
  friend_id: "a-1",
  display_name: "Maya Lin",
  emoji: "🌿",
  since: "2026-08-01T10:00:00Z",
  share_flights: true,
  share_passport: false,
  alerts: false,
  shares_flights: true,
  shares_passport: false,
};

describe("friends", () => {
  it("decodes a friends_list row", () => {
    const f = decodeFriend(row);
    expect(f).toMatchObject({ id: "a-1", displayName: "Maya Lin", emoji: "🌿", sharesFlights: true });
    expect(f.since.toISOString()).toBe("2026-08-01T10:00:00.000Z");
  });

  it("names a friend 'Friend' without a name and takes up to two initials", () => {
    expect(friendName({ displayName: "  " })).toBe("Friend");
    expect(friendName({ displayName: "Theo Martin" })).toBe("Theo Martin");
    expect(friendInitials("maya lin jr")).toBe("ML");
    expect(friendInitials(null)).toBe("?");
  });

  it("reads the list through rpc/friends_list and leaves out a row it cannot decode", async () => {
    rpc.mockResolvedValueOnce({ data: [row, { friend_id: null }], error: null });
    const list = await fetchFriends();
    expect(rpc).toHaveBeenCalledWith("friends_list");
    expect(list.map((f) => f.id)).toEqual(["a-1"]);
  });

  it("reads the caller's code through rpc/friends_me", async () => {
    rpc.mockResolvedValueOnce({
      data: [{ friend_code: "K7M2X9QP", sharing_paused: false, display_name: "Quentin", emoji: null }],
      error: null,
    });
    expect(await fetchFriendsMe()).toEqual({ friendCode: "K7M2X9QP", sharingPaused: false, displayName: "Quentin", emoji: null });
    expect(spacedCode("K7M2X9QP")).toBe("K7M2 X9QP");
  });

  it("reads one friend's flights with p_friend, and every friend's with null", async () => {
    const flight = {
      friend_id: "a-1",
      id: "f-1",
      provider_id: "p",
      ident: "AF84",
      origin_icao: "LFPG",
      destination_icao: "KSFO",
      status: "scheduled",
      updated_at: "2026-11-11T00:00:00Z",
    };
    rpc.mockResolvedValueOnce({ data: [flight], error: null });
    const one = await fetchFriendFlights("a-1");
    expect(rpc).toHaveBeenCalledWith("friend_flights", { p_friend: "a-1" });
    expect(one[0]).toMatchObject({ friendId: "a-1", flight: { ident: "AF84" } });
    rpc.mockResolvedValueOnce({ data: [], error: null });
    await fetchFriendFlights(null);
    expect(rpc).toHaveBeenLastCalledWith("friend_flights", { p_friend: null });
  });

  it("turns a PostgREST failure into an ApiError", async () => {
    rpc.mockResolvedValueOnce({ data: null, error: { code: "PGRST301", message: "jwt" } });
    await expect(fetchFriends()).rejects.toMatchObject({ code: "unauthorized" });
  });

  it("makes an invitation link through the friends function", async () => {
    callFunction.mockResolvedValueOnce({ id: "i-1", url: "https://somalabs.me/i/abc", expires_at: "2026-11-18T00:00:00Z" });
    const inv = await createInvite();
    expect(callFunction).toHaveBeenCalledWith("friends", { method: "POST", body: { action: "invite" } });
    expect(inv.url).toBe("https://somalabs.me/i/abc");
  });
});
