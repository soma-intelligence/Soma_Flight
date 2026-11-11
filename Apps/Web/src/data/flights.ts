import { ApiError, callFunction } from "./api";
import { getSupabase } from "./client";
import { decodeFlight } from "./decode";
import type { Flight, FollowedFlight } from "./types";

export const myFlightsKey = ["myFlights"] as const;
export const flightKey = (id: string) => ["flight", id] as const;

/** True only in development with `?fakes=1`. */
export function fakesEnabled(dev: boolean, search: string): boolean {
  return dev && new URLSearchParams(search).get("fakes") === "1";
}
export function useFakes(): boolean {
  return fakesEnabled(import.meta.env.DEV, typeof window === "undefined" ? "" : window.location.search);
}

type PgError = { code?: string; message?: string };
function pgError(e: PgError): ApiError {
  if (e.code === "PGRST301" || e.code === "PGRST302") return new ApiError("unauthorized", 401, e.message);
  if (e.code === "PGRST116") return new ApiError("not_found", 404, e.message);
  return new ApiError("provider_unavailable", 500, e.message);
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
  if (error) throw pgError(error);
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
    return fakeFlights().find((f) => f.id === id) ?? null;
  }
  const { data, error } = await getSupabase().from("flights").select("*").eq("id", id).limit(1);
  if (error) throw pgError(error);
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
