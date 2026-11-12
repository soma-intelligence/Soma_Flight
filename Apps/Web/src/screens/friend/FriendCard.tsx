import { useQuery } from "@tanstack/react-query";
import { X } from "lucide-react";
import { useParams } from "react-router";
import { useShellNav } from "@/app/nav";
import { fetchFriendFlights, fetchFriends, friendFlightsKey, friendName, friendsKey } from "@/data/friends";
import { FriendAvatar } from "@/screens/friends/FriendAvatar";
import { since } from "@/screens/friends/facts";
import { useAirports } from "@/ui/airports";
import { ErrorBanner } from "@/ui/ErrorBanner";
import { errorCode, errorCopy } from "@/ui/errorCopy";
import { FlightRow } from "@/ui/FlightRow";
import { RoundButton } from "@/ui/RoundButton";
import { useNow } from "@/ui/useNow";

/** One friend, after FriendPageView: their name and mark, then the flights the server shares with the user. */
export function FriendCard() {
  const { id = "" } = useParams();
  const nav = useShellNav();
  const now = useNow();
  const airport = useAirports();
  const friends = useQuery({ queryKey: friendsKey, queryFn: fetchFriends });
  const flights = useQuery({ queryKey: friendFlightsKey(id), queryFn: () => fetchFriendFlights(id) });
  const friend = friends.data?.find((f) => f.id === id);
  const list = flights.data ?? [];
  const error = friends.error ?? flights.error;

  return (
    <div data-testid="friend-card" className="relative h-full overflow-y-auto">
      <RoundButton icon={X} label="Close" onClick={nav.close} className="absolute top-4 right-4" />
      {friend ? (
        <div className="flex items-center gap-[14px] px-5 pt-[22px] pr-[76px] pb-3">
          <FriendAvatar id={friend.id} name={friend.displayName} emoji={friend.emoji} size={60} />
          <div className="min-w-0">
            <h1 className="text-[28px] leading-[34px] font-bold text-[var(--sf-primary)]">{friendName(friend)}</h1>
            <p className="text-[15px] text-[var(--sf-secondary)]">{since(friend.since)}</p>
          </div>
        </div>
      ) : (
        <h1 className="px-5 pt-[22px] pr-[76px] pb-3 text-[28px] leading-[34px] font-bold text-[var(--sf-primary)]">
          {friends.isPending ? "Friend" : "No longer friends"}
        </h1>
      )}
      <div className="px-4 pb-8">
        {error != null && (
          <div className="pb-[14px]">
            <ErrorBanner message={errorCopy(errorCode(error))} />
          </div>
        )}
        {friend && (
          <section aria-label="Their Flights">
            <h2 className="flex justify-between pb-2 text-[13px] text-[var(--sf-secondary)] uppercase">
              <span>Their Flights</span>
              {list.length > 0 && <span>{list.length === 1 ? "1 flight" : `${list.length} flights`}</span>}
            </h2>
            {list.length === 0 ? (
              !flights.isPending && (
                <p className="py-2 text-[15px] text-[var(--sf-secondary)]">
                  {friend.sharesFlights
                    ? "Nothing coming up."
                    : `${friendName(friend)} is not sharing flights with you right now.`}
                </p>
              )
            ) : (
              list.map((x) => (
                <FlightRow
                  key={x.flight.id}
                  flight={x.flight}
                  origin={airport(x.flight.originIcao)}
                  destination={airport(x.flight.destinationIcao)}
                  now={now}
                  onSelect={() => nav.open(`/friend/${id}/flight/${x.flight.id}`)}
                />
              ))
            )}
          </section>
        )}
      </div>
    </div>
  );
}
