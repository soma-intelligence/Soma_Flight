import { useEffect, useMemo, useRef, useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { Search as SearchIcon } from "lucide-react";
import { useShellNav } from "@/app/nav";
import { loadAirlines } from "@/ui/airlines";
import { useAirports } from "@/ui/airports";
import { ErrorBanner } from "@/ui/ErrorBanner";
import { errorCode, errorCopy } from "@/ui/errorCopy";
import { FlightRow } from "@/ui/FlightRow";
import { useNow } from "@/ui/useNow";
import { CardFrame } from "../placeholder";
import { dayString, lookupFlights } from "./lookup";
import { buildAirlineDirectory, parseFlightNumber, type AirlineDirectory, type AirlineRow } from "./parse";

const DAYS = [
  { label: "Today", offset: 0 },
  { label: "Tomorrow", offset: 1 },
  { label: "Yesterday", offset: -1 },
] as const;

const DEBOUNCE_MS = 250;

/** Names from the shared airline table, codes from the shared directory; null if it cannot load (the plain forms still read). */
function loadDirectory(): Promise<AirlineDirectory | null> {
  return Promise.all([loadAirlines(), import("@flightkit/Reference/airlines.json")]).then(
    ([dir, m]) => buildAirlineDirectory((m as unknown as { default: AirlineRow[] }).default, (c) => dir(c) !== null),
    () => null,
  );
}

/**
 * Search by flight number: a field that reads "af84", "AF 84", "84 af" or "air france 84", the day chips
 * (today, tomorrow, yesterday) and the flights found, each opening its card. Arrows move through the
 * results and Enter opens the one marked; Command or Control K opens this card and Escape closes it (the
 * shell holds both keys). A failed lookup shows the app's error copy and keeps the query and the day.
 */
export function Search() {
  const nav = useShellNav();
  const now = useNow();
  const airport = useAirports();
  const [text, setText] = useState("");
  const [offset, setOffset] = useState<number>(0);
  const [settled, setSettled] = useState("");
  const [active, setActive] = useState(0);
  const [dir, setDir] = useState<AirlineDirectory | null>(null);
  const input = useRef<HTMLInputElement>(null);

  useEffect(() => {
    let live = true;
    void loadDirectory().then((d) => live && setDir(d));
    return () => {
      live = false;
    };
  }, []);
  useEffect(() => {
    input.current?.focus();
  }, []);
  useEffect(() => {
    const t = setTimeout(() => setSettled(text), DEBOUNCE_MS);
    return () => clearTimeout(t);
  }, [text]);

  const number = useMemo(() => parseFlightNumber(settled, dir ?? undefined), [settled, dir]);
  const date = dayString(now, offset);
  const q = useQuery({
    queryKey: ["search", number?.airline, number?.number, date],
    queryFn: () => lookupFlights(number!, date),
    enabled: number !== null,
    retry: false,
  });
  const results = number ? (q.data ?? []) : [];
  const picked = Math.min(active, Math.max(results.length - 1, 0));

  function onKeyDown(e: React.KeyboardEvent) {
    if (e.key === "ArrowDown" || e.key === "ArrowUp") {
      if (results.length === 0) return;
      e.preventDefault();
      setActive(Math.max(0, Math.min(results.length - 1, picked + (e.key === "ArrowDown" ? 1 : -1))));
    } else if (e.key === "Enter") {
      e.preventDefault();
      if (results[picked]) nav.open(`/flight/${results[picked].id}`);
      else setSettled(text);
    }
  }

  const empty = number !== null && q.isSuccess && results.length === 0;
  return (
    <CardFrame title="Search" testId="search-card">
      <div className="px-4 pb-6" onKeyDown={onKeyDown}>
        <label className="flex items-center gap-2.5 rounded-full bg-[var(--sf-pill)] px-4 py-2.5">
          <SearchIcon size={16} strokeWidth={2.4} aria-hidden className="shrink-0 text-[var(--sf-secondary)]" />
          <input
            ref={input}
            aria-label="Flight number"
            value={text}
            onChange={(e) => {
              setText(e.target.value);
              setActive(0);
            }}
            placeholder="Flight number, like AF 84"
            autoCapitalize="characters"
            autoComplete="off"
            autoCorrect="off"
            spellCheck={false}
            enterKeyHint="search"
            className="min-w-0 flex-1 bg-transparent text-[17px] text-[var(--sf-primary)] outline-none placeholder:text-[var(--sf-secondary)]"
          />
        </label>
        <div role="radiogroup" aria-label="Day" className="flex gap-2 py-3.5">
          {DAYS.map((d) => (
            <button
              key={d.label}
              type="button"
              role="radio"
              aria-checked={offset === d.offset}
              onClick={() => {
                setOffset(d.offset);
                setActive(0);
              }}
              className={`rounded-full px-3.5 py-[7px] text-[15px] font-semibold ${
                offset === d.offset
                  ? "bg-[var(--sf-primary)] text-[var(--sf-background)]"
                  : "bg-[var(--sf-pill)] text-[var(--sf-primary)]"
              }`}
            >
              {d.label}
            </button>
          ))}
        </div>
        {q.isError && <ErrorBanner message={errorCopy(errorCode(q.error))} onRetry={() => void q.refetch()} />}
        {q.isFetching && !q.isError && results.length === 0 && (
          <div role="status" aria-label="Searching" className="flex min-h-[120px] items-center justify-center">
            <span className="size-6 animate-spin rounded-full border-2 border-[var(--sf-separator)] border-t-[var(--sf-secondary)]" />
          </div>
        )}
        {empty && !q.isFetching && (
          <p role="status" className="py-6 text-center text-[15px] text-[var(--sf-secondary)]">
            {errorCopy("not_found")}
          </p>
        )}
        {results.length > 0 && (
          <div role="list" aria-label="Flights found">
            {results.map((f, i) => (
              <div
                key={f.id}
                role="listitem"
                data-testid="search-result"
                aria-current={i === picked}
                className={i === picked ? "rounded-[14px] bg-[var(--sf-pill)]" : undefined}
                onMouseMove={() => i !== picked && setActive(i)}
              >
                <FlightRow
                  flight={f}
                  origin={airport(f.originIcao)}
                  destination={airport(f.destinationIcao)}
                  now={now}
                  onSelect={() => nav.open(`/flight/${f.id}`)}
                />
              </div>
            ))}
          </div>
        )}
      </div>
    </CardFrame>
  );
}
