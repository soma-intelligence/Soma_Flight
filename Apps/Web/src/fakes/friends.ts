import type { Friend, FriendFlight, FriendInvite, FriendsMe } from "@/data/friends";
import type { Flight } from "@/data/types";
import { fakeFlights } from "./flights";

// Development only: import this module behind `if (import.meta.env.DEV)`.

export const MAYA = "f7e4d000-0000-4000-8000-00000000a0a1";
export const THEO = "f7e4d000-0000-4000-8000-00000000a0a2";
export const NOA = "f7e4d000-0000-4000-8000-00000000a0a3";

const DAY = 86_400_000;

export function fakeFriends(now: Date = new Date()): Friend[] {
  const base = { shareFlights: true, sharePassport: false, alerts: false, sharesPassport: false };
  return [
    { ...base, id: MAYA, displayName: "Maya", emoji: "🌿", since: new Date(now.getTime() - 90 * DAY), sharesFlights: true },
    { ...base, id: THEO, displayName: "Theo Martin", emoji: null, since: new Date(now.getTime() - 12 * DAY), sharesFlights: true },
    { ...base, id: NOA, displayName: "Noa", emoji: null, since: new Date(now.getTime() - 3 * DAY), sharesFlights: false },
  ];
}

export function fakeFriendsMe(): FriendsMe {
  return { friendCode: "K7M2X9QP", sharingPaused: false, displayName: "Quentin", emoji: null };
}

/** Maya in the air, Theo with one still to leave, under ids of their own so they differ from the user's. */
export function fakeFriendFlights(now: Date = new Date()): FriendFlight[] {
  const all = fakeFlights(now);
  const inAir = all.find((f) => f.status === "en_route") ?? all[0]!;
  const later = all.find((f) => f.status === "scheduled" && f.id !== inAir.id) ?? all[1]!;
  const copy = (f: Flight, id: string, ident: string): Flight => ({ ...f, id, ident, providerId: `${f.providerId}-friend` });
  return [
    { friendId: MAYA, flight: copy(inAir, "f7e4d000-0000-4000-8000-00000000f001", "DL262") },
    { friendId: THEO, flight: copy(later, "f7e4d000-0000-4000-8000-00000000f002", "BA287") },
  ];
}

let made = 0;
export function fakeInvite(now: Date = new Date()): FriendInvite {
  made += 1;
  return {
    id: `inv-${made}`,
    url: `https://somalabs.me/i/FakeInvite${String(made).padStart(33, "0")}`,
    expiresAt: new Date(now.getTime() + 7 * DAY),
  };
}

/** What a fresh account has before it changes anything: every category on (no row means all on). */
const prefs: Record<string, boolean> = {};
export function fakeNotificationPrefs(): Record<string, boolean> {
  return { ...prefs };
}
export function setFakeNotificationPref(column: string, on: boolean): void {
  prefs[column] = on;
}
