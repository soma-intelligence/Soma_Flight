import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { X } from "lucide-react";
import { useEffect, useState } from "react";
import { useParams } from "react-router";
import { useShellNav } from "@/app/nav";
import { fetchFriendFlights, friendFlightsKey } from "@/data/friends";
import { fetchFlight, flightKey, followFlight, myFlightsKey, unfollowFlight, useFakes } from "@/data/flights";
import { subscribeFlights } from "@/data/realtime";
import type { Flight, FollowedFlight } from "@/data/types";
import { useMyFlights } from "@/screens/my-flights/useMyFlights";
import { initCore, distanceKm } from "@/core/flightcore";
import { airlineOf, useAirlines } from "@/ui/airlines";
import { airportsReady, useAirports, type AirportInfo } from "@/ui/airports";
import { ErrorBanner } from "@/ui/ErrorBanner";
import { errorCode, errorCopy } from "@/ui/errorCopy";
import { RoundButton } from "@/ui/RoundButton";
import { useNow } from "@/ui/useNow";
import { countdown, countdownCaption, landedCaption, landedTitle, statusTone, timetableRows } from "./facts";
import { CountdownCard, Header } from "./Header";
import { Progress } from "./Progress";
import { GatesCard, TimetableCard } from "./Timetable";

const sameId = (a: string, b: string) => a.toLowerCase() === b.toLowerCase();

/** True once the flightcore wasm is in (for the distance); false for good when it cannot load. */
function useCoreReady(): boolean {
  const [ready, setReady] = useState(false);
  useEffect(() => {
    let live = true;
    initCore().then(
      () => live && setReady(true),
      () => {},
    );
    return () => {
      live = false;
    };
  }, []);
  return ready;
}

/** Whole km between two airports (DetailFacts.distanceKm); null when either is unknown or the core is not in. */
function airportKm(core: boolean, a: AirportInfo | null, b: AirportInfo | null): number | null {
  if (!core || a?.lat == null || a.lon == null || b?.lat == null || b.lon == null) return null;
  try {
    return Math.round(distanceKm({ lat: a.lat, lon: a.lon }, { lat: b.lat, lon: b.lon }));
  } catch {
    return null;
  }
}

/**
 * One flight, first cut of FlightDetailView: the header pinned at the top, then the estimate while the
 * flight cannot be heard, the countdown card, gates and terminals and the detailed timetable, with Follow
 * or Stop Following at the foot. The other cards come with Plan 2; nothing here is a dead control.
 * Realtime keeps the row current. In development fakes, following changes local state only.
 * Opened from a friend's page (`/friend/:fid/flight/:id`) it is read only, as iOS's friend flight screen:
 * the flight comes from that friend's shared flights, with no Follow and no Realtime subscription.
 */
export function FlightCard() {
  const { id = "", fid } = useParams();
  const readOnly = fid !== undefined;
  const nav = useShellNav();
  const qc = useQueryClient();
  const fakes = useFakes();
  const now = useNow();
  const airport = useAirports();
  const zonesKnown = airportsReady(airport);
  const airlines = useAirlines();
  const core = useCoreReady();
  const mine = useMyFlights();
  const followedRow = mine.data?.find((x) => sameId(x.flight.id, id));

  const own = useQuery({
    queryKey: flightKey(id),
    queryFn: () => fetchFlight(id),
    staleTime: fakes ? Number.POSITIVE_INFINITY : 60_000,
    placeholderData: followedRow?.flight,
    enabled: !readOnly,
  });
  // A friend's flight is read from the friend's shared list (the page's cache, fetched when absent).
  const theirs = useQuery({
    queryKey: friendFlightsKey(fid ?? ""),
    queryFn: () => fetchFriendFlights(fid ?? ""),
    select: (list) => list.find((x) => sameId(x.flight.id, id))?.flight ?? null,
    staleTime: fakes ? Number.POSITIVE_INFINITY : 60_000,
    enabled: readOnly,
  });
  const q = readOnly ? theirs : own;
  const flight = q.data ?? null;

  useEffect(() => {
    if (fakes || readOnly || !flight) return;
    return subscribeFlights([flight.id], (row) => qc.setQueryData(flightKey(id), row));
  }, [fakes, readOnly, flight?.id, id, qc]); // eslint-disable-line react-hooks/exhaustive-deps

  const [followError, setFollowError] = useState<string | null>(null);
  const follow = useMutation({
    mutationFn: async (f: Flight) => {
      if (!fakes) await followFlight({ flightId: f.id });
    },
    onMutate: () => setFollowError(null),
    onSuccess: (_v, f) => {
      qc.setQueryData<FollowedFlight[]>(myFlightsKey, (old) =>
        old?.some((x) => sameId(x.flight.id, f.id)) ? old : [...(old ?? []), { createdAt: new Date(), flight: f }],
      );
      if (!fakes) void qc.invalidateQueries({ queryKey: myFlightsKey });
    },
    onError: (e) => setFollowError(errorCopy(errorCode(e))),
  });
  const unfollow = useMutation({
    mutationFn: async (f: Flight) => {
      if (!fakes) await unfollowFlight(f.id);
    },
    onMutate: () => setFollowError(null),
    onSuccess: (_v, f) => {
      qc.setQueryData<FollowedFlight[]>(myFlightsKey, (old) => old?.filter((x) => !sameId(x.flight.id, f.id)));
      if (!fakes) void qc.invalidateQueries({ queryKey: myFlightsKey });
    },
    onError: (e) => setFollowError(errorCopy(errorCode(e))),
  });

  if (!flight) {
    const missing = q.isSuccess && q.data === null;
    return (
      <div data-testid="flight-card" data-flight-id={id} className="relative flex h-full flex-col">
        <div className="flex justify-end pt-4 pr-4">
          <RoundButton icon={X} label="Close" onClick={nav.close} />
        </div>
        {missing || q.error ? (
          <div className="p-4">
            <ErrorBanner
              message={errorCopy(missing ? "not_found" : errorCode(q.error))}
              onRetry={missing ? undefined : () => void q.refetch()}
            />
          </div>
        ) : (
          <div role="status" aria-label="Loading" className="flex flex-1 items-center justify-center">
            <span className="size-6 animate-spin rounded-full border-2 border-[var(--sf-separator)] border-t-[var(--sf-secondary)]" />
          </div>
        )}
      </div>
    );
  }

  const origin = airport(flight.originIcao);
  const destination = airport(flight.destinationIcao);
  const landed = landedTitle(flight);
  const followed = !!followedRow;
  // Until the list of follows is in, the button cannot say which it is: it stays disabled.
  const busy = follow.isPending || unfollow.isPending || !mine.isSuccess;
  const airline = airlineOf(flight, airlines);

  return (
    <div data-testid="flight-card" data-flight-id={id} className="flex h-full flex-col">
      <Header
        flight={flight}
        origin={origin}
        destination={destination}
        airline={airline}
        zonesKnown={zonesKnown}
        onClose={nav.close}
      />
      <div className="relative min-h-0 flex-1">
        <div className="h-full overflow-y-auto overscroll-contain">
          <div className="flex flex-col gap-4 px-5 pt-4 pb-[96px]">
            {q.error && <ErrorBanner message={errorCopy(errorCode(q.error))} onRetry={() => void q.refetch()} />}
            <Progress flight={flight} now={now} />
            <CountdownCard
              title={landed ?? countdown(flight, now)}
              caption={
                (landed && landedCaption(flight, airportKm(core, origin, destination))) ||
                countdownCaption(flight, airline)
              }
              tone={statusTone(flight)}
            />
            <GatesCard flight={flight} />
            <TimetableCard rows={timetableRows(flight, origin?.tz, destination?.tz, false, zonesKnown)} />
          </div>
        </div>
        {!readOnly && (
          <div className="pointer-events-none absolute right-0 bottom-0 left-0 flex flex-col items-end gap-2 px-5 pb-4">
            {followError && (
              <div className="pointer-events-auto w-full">
                <ErrorBanner message={followError} />
              </div>
            )}
            {followed ? (
              <button
                type="button"
                disabled={busy}
                onClick={() => unfollow.mutate(flight)}
                className="sf-glass pointer-events-auto h-[52px] rounded-full px-[22px] text-[18px] font-semibold text-[var(--sf-primary)] disabled:opacity-60"
              >
                Stop Following
              </button>
            ) : (
              <button
                type="button"
                disabled={busy}
                onClick={() => follow.mutate(flight)}
                className="pointer-events-auto h-[52px] rounded-full bg-[var(--sf-accent)] px-[22px] text-[18px] font-semibold text-white shadow-[0_6px_18px_rgba(0,0,0,0.18)] disabled:opacity-60"
              >
                Follow
              </button>
            )}
          </div>
        )}
      </div>
    </div>
  );
}
