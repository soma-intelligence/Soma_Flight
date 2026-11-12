import { useMemo } from "react";
import { Search as SearchIcon } from "lucide-react";
import { useShellNav } from "@/app/nav";
import { useAirports } from "@/ui/airports";
import { ErrorBanner } from "@/ui/ErrorBanner";
import { errorCode, errorCopy } from "@/ui/errorCopy";
import { FlightRow } from "@/ui/FlightRow";
import { JetIllustration } from "@/ui/JetIllustration";
import { useNow } from "@/ui/useNow";
import { TabTitle } from "../placeholder";
import { groupMyFlights } from "./groups";
import { useLiveMyFlights, useMyFlights } from "./useMyFlights";

/**
 * The home list, after MyFlightsView: followed flights in the air first, then the ones still to come,
 * then the finished, canceled and diverted ones until they are over. With nothing followed it invites a
 * search; before the first load it shows a spinner; a failed load with nothing to show keeps only the
 * error banner and its retry. Realtime keeps the rows current. The profile button sits over it (TabRoot).
 */
export function MyFlights() {
  const nav = useShellNav();
  const q = useMyFlights();
  useLiveMyFlights(q.data);
  const now = useNow();
  const airport = useAirports();
  const groups = useMemo(() => groupMyFlights((q.data ?? []).map((x) => x.flight), now), [q.data, now]);

  return (
    <div>
      <TabTitle>My Flights</TabTitle>
      <div className="px-4 pb-6">
        {q.error && (
          <div className="pb-[14px]">
            <ErrorBanner message={errorCopy(errorCode(q.error))} onRetry={() => void q.refetch()} />
          </div>
        )}
        {groups.length === 0 ? (
          q.isPending || (q.error && q.isFetching) ? (
            <div role="status" aria-label="Loading your flights" className="flex min-h-[200px] items-center justify-center">
              <span className="size-6 animate-spin rounded-full border-2 border-[var(--sf-separator)] border-t-[var(--sf-secondary)]" />
            </div>
          ) : q.error ? null : (
            <EmptyFlights onSearch={() => nav.open("/search")} />
          )
        ) : (
          groups.map((g) => (
            <section key={g.title} aria-label={g.title} className="pb-[14px]">
              <h2 className="flex justify-between pt-1.5 pb-2.5 text-[13px] text-[var(--sf-secondary)] uppercase">
                <span>{g.title}</span>
                <span>{g.rows.length === 1 ? "1 flight" : `${g.rows.length} flights`}</span>
              </h2>
              {g.rows.map((f) => (
                <FlightRow
                  key={f.id}
                  flight={f}
                  origin={airport(f.originIcao)}
                  destination={airport(f.destinationIcao)}
                  now={now}
                  onSelect={() => nav.open(`/flight/${f.id}`)}
                />
              ))}
            </section>
          ))
        )}
      </div>
    </div>
  );
}

/** The centred invitation when nothing is followed: the climbing jet, a short title and Search. */
function EmptyFlights({ onSearch }: { onSearch: () => void }) {
  return (
    <div className="flex min-h-[200px] flex-col items-center gap-1.5 py-6 text-center">
      <div className="w-full py-3 pb-[22px]">
        <JetIllustration width={240} />
      </div>
      <h2 className="text-[20px] font-semibold text-[var(--sf-primary)]">Where to next?</h2>
      <p className="text-[15px] text-[var(--sf-secondary)]">Add a flight you're taking by number, route or airport.</p>
      <button
        type="button"
        onClick={onSearch}
        className="mt-2.5 flex items-center gap-1.5 rounded-full bg-[var(--sf-pill)] px-4 py-[9px] text-[15px] font-semibold text-[var(--sf-primary)]"
      >
        <SearchIcon size={15} strokeWidth={2.4} aria-hidden />
        Search
      </button>
    </div>
  );
}
