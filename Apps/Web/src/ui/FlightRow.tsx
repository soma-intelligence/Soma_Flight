import { ArrowDownRight, ArrowUpRight, type LucideIcon } from "lucide-react";
import type { Flight } from "@/data/types";
import { airlineOf, useAirlines } from "./airlines";
import { readUnits } from "@/data/settings";
import { airportsReady, useAirports, type AirportInfo } from "./airports";
import { AirlineMark } from "./AirlineMark";
import {
  airlineCode,
  bestIn,
  bestOut,
  clock,
  countdownColumn,
  destinationCode,
  ident,
  originCode,
  rowDay,
  rowMarker,
} from "./format";

/**
 * A followed flight in My Flights, after MyFlightRow: the countdown column, then the airline mark (its IATA
 * code from airlines.json), flight
 * number and date, the route by city, and the two codes with their local times (the arrival's "+1" when
 * it lands on a later local date). A hairline closes it under the text.
 */
export function FlightRow({
  flight,
  origin,
  destination,
  now,
  onSelect,
}: {
  flight: Flight;
  origin: AirportInfo | null;
  destination: AirportInfo | null;
  now: Date;
  onSelect: () => void;
}) {
  const count = countdownColumn(flight, now);
  const twelveHour = readUnits().clock === "h12";
  // Times read in the airports' zones: "--:--" until the airport table is in, never a jump from the browser's zone.
  const ready = airportsReady(useAirports());
  const airline = airlineOf(flight, useAirlines());
  const unitColor =
    flight.status === "canceled"
      ? "var(--sf-very-late)"
      : flight.status === "diverted"
        ? "var(--sf-diverted)"
        : "var(--sf-secondary)";
  const from = origin?.city ?? originCode(flight);
  const to = destination?.city ?? destinationCode(flight);
  const day = ready ? rowDay(flight, origin?.tz) : null;
  const said = [
    ident(flight.ident),
    `${from} to ${to}`,
    ...(day ? [day] : []),
    count.value ? `${count.value} ${count.unit.toLowerCase()}` : capitalized(count.unit),
  ].join(", ");

  return (
    <button
      type="button"
      onClick={onSelect}
      aria-label={said}
      data-testid="flight-row"
      className="flex w-full items-center gap-[13px] text-left"
    >
      <div className="flex w-[66px] shrink-0 flex-col items-center gap-0.5" aria-hidden>
        {count.value && (
          <span className="text-[34px] leading-[40px] font-semibold text-[var(--sf-primary)] tabular-nums">
            {count.value}
          </span>
        )}
        <span className="text-[13px] font-medium whitespace-nowrap" style={{ color: unitColor }}>
          {count.unit}
        </span>
      </div>
      <div className="min-w-0 flex-1 border-b border-[var(--sf-separator)]" aria-hidden>
        <div className="flex flex-col gap-[5px] py-[14px]">
          <div className="flex flex-wrap items-center justify-between gap-x-2 gap-y-0.5">
            <span className="flex items-center gap-2">
              <AirlineMark code={airlineCode(flight, airline)} size={24} />
              <span className="text-[15px] whitespace-nowrap text-[var(--sf-secondary)]">{ident(flight.ident)}</span>
            </span>
            {day && <span className="text-[15px] whitespace-nowrap text-[var(--sf-secondary)]">{day}</span>}
          </div>
          <p className="text-[17px] text-[var(--sf-primary)]">
            <span className="font-semibold">{from}</span> to <span className="font-semibold">{to}</span>
          </p>
          <div className="flex flex-wrap gap-x-[14px] gap-y-1 pt-0.5">
            <End icon={ArrowUpRight} code={originCode(flight)} time={ready ? clock(bestOut(flight), origin?.tz, twelveHour) : "--:--"} />
            <End
              icon={ArrowDownRight}
              code={destinationCode(flight)}
              time={ready ? clock(bestIn(flight), destination?.tz, twelveHour) : "--:--"}
              marker={ready ? rowMarker(flight, origin?.tz, destination?.tz) : null}
            />
          </div>
        </div>
      </div>
    </button>
  );
}

function capitalized(s: string): string {
  return s
    .toLowerCase()
    .split(" ")
    .map((w) => w.charAt(0).toUpperCase() + w.slice(1))
    .join(" ");
}

/** One end of the route: the arrow disc, the code and its local time, the arrival's day marker when given. */
function End({ icon: Icon, code, time, marker }: { icon: LucideIcon; code: string; time: string; marker?: string | null }) {
  return (
    <span className="flex items-center gap-1.5 text-[17px] whitespace-nowrap tabular-nums">
      <span className="flex size-[18px] items-center justify-center rounded-full bg-[color-mix(in_srgb,var(--sf-secondary)_75%,transparent)] text-[var(--sf-background)]">
        <Icon size={11} strokeWidth={3} />
      </span>
      <span className="text-[var(--sf-secondary)]">{code}</span>
      <span className="text-[var(--sf-primary)]">
        {time}
        {marker && <sup className="ml-px text-[11px] font-medium">{marker}</sup>}
      </span>
    </span>
  );
}
