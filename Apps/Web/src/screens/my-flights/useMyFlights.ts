import { useQuery, useQueryClient } from "@tanstack/react-query";
import { useEffect } from "react";
import { fetchMyFlights, flightKey, myFlightsKey, useFakes } from "@/data/flights";
import { subscribeFlights } from "@/data/realtime";
import type { Flight, FollowedFlight } from "@/data/types";

/** The signed-in user's followed flights, `["myFlights"]` in the memory cache. Fakes never go stale. */
export function useMyFlights() {
  const fakes = useFakes();
  return useQuery({
    queryKey: myFlightsKey,
    queryFn: fetchMyFlights,
    staleTime: fakes ? Number.POSITIVE_INFINITY : 60_000,
  });
}

/** Puts a changed row in place in My Flights and in its own card's cache. */
export function applyRow(qc: ReturnType<typeof useQueryClient>, row: Flight) {
  const same = (f: Flight) => f.id.toLowerCase() === row.id.toLowerCase();
  qc.setQueryData<FollowedFlight[]>(myFlightsKey, (old) =>
    old?.map((x) => (same(x.flight) ? { ...x, flight: row } : x)),
  );
  qc.setQueryData(flightKey(row.id), row);
}

/**
 * Realtime UPDATEs on the followed flights, applied to the cache as they come (MyFlightsStore.subscribe),
 * so a flight moves between groups without a reload. One subscription per set of ids; none with fakes.
 */
export function useLiveMyFlights(follows: FollowedFlight[] | undefined) {
  const qc = useQueryClient();
  const fakes = useFakes();
  const ids = (follows ?? []).map((x) => x.flight.id).sort();
  const key = ids.join(",");
  useEffect(() => {
    if (fakes || key === "") return;
    return subscribeFlights(key.split(","), (row) => applyRow(qc, row));
  }, [fakes, key, qc]);
}
