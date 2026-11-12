import { callFunction, pgError } from "./api";
import { getSupabase } from "./client";
import { decodeFlight } from "./decode";
import type { Flight, FollowedFlight } from "./types";

export const myFlightsKey = ["myFlights"] as const;
export const flightKey = (id: string) => ["flight", id] as const;

/** True only in development with `?fakes=1`. */
export function fakesEnabled(dev: boolean, search: string): boolean {
  return dev && new URLSearchParams(search).get("fakes") === "1";
}
/** Where development remembers `?fakes=1` for the tab, so in-app links need not carry it. */
export const FAKES_KEY = "sf.fakes";

/**
 * True in development once `?fakes=1` has been seen in this tab (the flag sticks in sessionStorage, so
 * navigation and Sign Out keep fakes on). Always false in production, where the branch is compiled out.
 */
export function useFakes(): boolean {
  if (import.meta.env.DEV) {
    if (typeof window === "undefined") return false;
    if (fakesEnabled(true, window.location.search)) {
      try {
        sessionStorage.setItem(FAKES_KEY, "1");
      } catch {
        /* storage blocked: fakes stay on while the URL says so */
      }
      return true;
    }
    try {
      return sessionStorage.getItem(FAKES_KEY) === "1";
    } catch {
      return false;
    }
  }
  return false;
}

/** The signed-in user's follows with their flights. A row that cannot be read is left out. */
export async function fetchMyFlights(): Promise<FollowedFlight[]> {
  if (useFakes() && import.meta.env.DEV) {
    const { fakeFollowed } = await import("@/fakes");
    return fakeFollowed();
  }
  const { data, error } = await getSupabase()
    .from("user_flights")
    .select("created_at, flights(*)")
    .order("created_at");
  if (error) throw pgError(error, "flight");
  const out: FollowedFlight[] = [];
  for (const row of (data ?? []) as unknown as { created_at?: string; flights?: unknown }[]) {
    if (!row.flights) continue;
    try {
      out.push({ createdAt: new Date(String(row.created_at)), flight: decodeFlight(row.flights) });
    } catch {
      // one bad row never fails the list
    }
  }
  return out;
}

export async function fetchFlight(id: string): Promise<Flight | null> {
  if (useFakes() && import.meta.env.DEV) {
    const { fakeFlights } = await import("@/fakes");
    const { fakeFriendFlights } = await import("@/fakes/friends");
    const own = fakeFlights().find((f) => f.id === id);
    return own ?? fakeFriendFlights().find((x) => x.flight.id === id)?.flight ?? null;
  }
  const { data, error } = await getSupabase().from("flights").select("*").eq("id", id).limit(1);
  if (error) throw pgError(error, "flight");
  const row = (data ?? [])[0];
  return row ? decodeFlight(row) : null;
}

export async function followFlight(input: { flightId: string; notify?: boolean }): Promise<void> {
  await callFunction("follow-flight", {
    method: "POST",
    body: { flightId: input.flightId.toLowerCase(), notify: input.notify ?? true },
  });
}

export async function unfollowFlight(id: string): Promise<void> {
  await callFunction("follow-flight", { method: "DELETE", body: { flightId: id.toLowerCase() } });
}
