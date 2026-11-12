import { callFunction, pgError } from "./api";
import { getSupabase } from "./client";
import { decodeFlight } from "./decode";
import { useFakes } from "./flights";
import type { Flight } from "./types";

export const friendsKey = ["friends"] as const;
export const friendsMeKey = ["friendsMe"] as const;
/** `null` is every friend's flights (the list), an id is one friend's (the card). */
export const friendFlightsKey = (id: string | null) => ["friendFlights", id] as const;

/** A mutual friend, a `friends_list` row (docs/api-contract.md, "friends"). */
export type Friend = {
  id: string;
  displayName: string | null;
  emoji: string | null;
  since: Date;
  /** The caller's own switches about this friend. */
  shareFlights: boolean;
  sharePassport: boolean;
  alerts: boolean;
  /** What the friend shares with the caller now. */
  sharesFlights: boolean;
  sharesPassport: boolean;
};

export type FriendsMe = {
  friendCode: string;
  sharingPaused: boolean;
  displayName: string | null;
  emoji: string | null;
};

export type FriendFlight = { friendId: string; flight: Flight };

export type FriendInvite = { id: string; url: string; expiresAt: Date };

type Row = Record<string, unknown>;

const optStr = (v: unknown): string | null => (typeof v === "string" ? v : null);

/** The name shown everywhere: "Friend" until they pick one. */
export function friendName(f: { displayName: string | null }): string {
  const n = f.displayName?.trim() ?? "";
  return n === "" ? "Friend" : n;
}

/** Up to two initials of a name ("Maya Lin" gives "ML"), "?" without one. */
export function friendInitials(name: string | null): string {
  const s = (name ?? "")
    .split(/\s+/)
    .filter(Boolean)
    .slice(0, 2)
    .map((w) => Array.from(w)[0]!.toUpperCase())
    .join("");
  return s === "" ? "?" : s;
}

/** "K7M2 X9QP": the 8-character code in two groups. */
export function spacedCode(code: string): string {
  return code.length === 8 ? `${code.slice(0, 4)} ${code.slice(4)}` : code;
}

export function decodeFriend(row: unknown): Friend {
  if (typeof row !== "object" || row === null) throw new Error("friend row: not an object");
  const r = row as Row;
  const id = r.friend_id;
  const since = new Date(String(r.since));
  if (typeof id !== "string" || id === "" || Number.isNaN(since.getTime())) throw new Error("friend row: bad id or date");
  return {
    id,
    displayName: optStr(r.display_name),
    emoji: optStr(r.emoji),
    since,
    shareFlights: r.share_flights === true,
    sharePassport: r.share_passport === true,
    alerts: r.alerts === true,
    sharesFlights: r.shares_flights === true,
    sharesPassport: r.shares_passport === true,
  };
}

/** The caller's friends, by name. A row that cannot be read is left out. */
export async function fetchFriends(): Promise<Friend[]> {
  if (useFakes() && import.meta.env.DEV) {
    const { fakeFriends } = await import("@/fakes/friends");
    return fakeFriends();
  }
  const { data, error } = await getSupabase().rpc("friends_list");
  if (error) throw pgError(error, "other");
  const out: Friend[] = [];
  for (const row of (data ?? []) as unknown[]) {
    try {
      out.push(decodeFriend(row));
    } catch {
      // one bad row never fails the list
    }
  }
  return out;
}

/** The caller's friend code, pause, name and emoji. */
export async function fetchFriendsMe(): Promise<FriendsMe> {
  if (useFakes() && import.meta.env.DEV) {
    const { fakeFriendsMe } = await import("@/fakes/friends");
    return fakeFriendsMe();
  }
  const { data, error } = await getSupabase().rpc("friends_me");
  if (error) throw pgError(error, "other");
  const r = ((data ?? []) as Row[])[0];
  if (!r || typeof r.friend_code !== "string") throw pgError({ message: "friends_me: no row" }, "other");
  return {
    friendCode: r.friend_code,
    sharingPaused: r.sharing_paused === true,
    displayName: optStr(r.display_name),
    emoji: optStr(r.emoji),
  };
}

/** Upcoming and in-air flights of one friend, or of every friend when `friendId` is null. */
export async function fetchFriendFlights(friendId: string | null): Promise<FriendFlight[]> {
  if (useFakes() && import.meta.env.DEV) {
    const { fakeFriendFlights } = await import("@/fakes/friends");
    return fakeFriendFlights().filter((x) => friendId === null || x.friendId === friendId);
  }
  const { data, error } = await getSupabase().rpc("friend_flights", { p_friend: friendId });
  if (error) throw pgError(error, "other");
  const out: FriendFlight[] = [];
  for (const row of (data ?? []) as Row[]) {
    try {
      out.push({ friendId: String(row.friend_id), flight: decodeFlight(row) });
    } catch {
      // one bad row never fails the list
    }
  }
  return out;
}

/** A new single-use invitation link (open 7 days). */
export async function createInvite(): Promise<FriendInvite> {
  if (useFakes() && import.meta.env.DEV) {
    const { fakeInvite } = await import("@/fakes/friends");
    return fakeInvite();
  }
  const r = await callFunction<{ id: string; url: string; expires_at: string }>("friends", {
    method: "POST",
    body: { action: "invite" },
  });
  return { id: r.id, url: r.url, expiresAt: new Date(r.expires_at) };
}
