import { useQuery } from "@tanstack/react-query";
import { clock } from "@/ui/format";
import { useUnits, visibilityText } from "@/ui/units";
import { Star, X } from "lucide-react";
import { useParams } from "react-router";
import { useShellNav } from "@/app/nav";
import {
  airportWeatherKey,
  faaStatusKey,
  fetchAirportWeather,
  fetchFaaStatus,
  isFaaCovered,
  type AirportConditions,
  type FaaProgram,
} from "@/data/airports";
import { useFakes } from "@/data/flights";
import { categoryOf } from "@/screens/airports/category";
import { useFavorites, useToggleFavorite } from "@/screens/airports/hooks";
import { airportsReady, useAirports } from "@/ui/airports";
import { CategoryChip } from "@/ui/CategoryChip";
import { RoundButton } from "@/ui/RoundButton";
import { useNow } from "@/ui/useNow";

const CATEGORY_NAME: Record<string, [string, string]> = {
  VFR: ["Visual Flight Rules", "Good ceiling and visibility. Normal flows."],
  MVFR: ["Marginal VFR", "Lower clouds or haze. Short delays are possible."],
  IFR: ["Instrument Flight Rules", "Low clouds or poor visibility. Expect slower flows."],
  LIFR: ["Low IFR", "Very low clouds or visibility. Delays are likely."],
};

const PROGRAM_TITLE: Record<FaaProgram["kind"], string> = {
  closure: "Airport closed",
  ground_stop: "Ground stop",
  ground_delay: "Ground delay program",
  departure_delay: "Departure delays",
  arrival_delay: "Arrival delays",
  deicing: "De-icing",
};

function countryName(code: string): string {
  try {
    return new Intl.DisplayNames(["en"], { type: "region" }).of(code) ?? code;
  } catch {
    return code;
  }
}

/** "14:05 PDT" (or "2:05 PM PDT"): the clock in the airport's zone with the zone's short name. */
function localTime(now: Date, tz: string | null, twelveHour = false): string {
  try {
    const f = (o: Intl.DateTimeFormatOptions) => new Intl.DateTimeFormat("en-US", { timeZone: tz ?? undefined, ...o });
    const time = clock(now, tz, twelveHour);
    const zone = f({ timeZoneName: "short" }).formatToParts(now).find((p) => p.type === "timeZoneName")?.value ?? "";
    return `${time} ${zone}`.trim();
  } catch {
    return "";
  }
}

function ago(from: Date, now: Date): string {
  const m = Math.max(0, Math.round((now.getTime() - from.getTime()) / 60_000));
  if (m < 1) return "just now";
  if (m < 60) return `${m} min ago`;
  const h = Math.floor(m / 60);
  return h < 24 ? `${h} h ago` : `${Math.floor(h / 24)} d ago`;
}

/**
 * One airport, first cut of AirportView: the header (codes, local time, name, city), the current weather
 * with the flight category the core computes, the FAA's programs at a US airport and the favourite star.
 * Weather and FAA are niceties: a failed read shows nothing, never an error.
 */
export function AirportCard() {
  const { code = "" } = useParams();
  const nav = useShellNav();
  const dir = useAirports();
  const fakes = useFakes();
  const now = useNow();
  const twelveHour = useUnits().clock === "h12";
  const favs = useFavorites();
  const toggle = useToggleFavorite();

  const valid = /^[A-Za-z]{3,4}$/.test(code);
  const ready = airportsReady(dir) && valid;
  const info = dir(code);
  const icao = info?.icao ?? code.toUpperCase();
  const covered = info ? isFaaCovered(info.country ?? "") : false;
  const stale = fakes ? Number.POSITIVE_INFINITY : 5 * 60_000;

  const weather = useQuery({
    queryKey: airportWeatherKey([icao]),
    queryFn: async () => (await fetchAirportWeather([icao])).find((w) => w.icao === icao)?.weather ?? null,
    enabled: ready,
    staleTime: stale,
  });
  const faa = useQuery({
    queryKey: faaStatusKey(icao),
    queryFn: () => fetchFaaStatus(icao),
    enabled: ready && covered,
    staleTime: stale,
  });

  if (!valid) {
    return (
      <div data-testid="airport-card" className="relative h-full overflow-y-auto">
        <h1 className="px-5 pt-[22px] pr-[76px] text-[26px] leading-[31px] font-bold text-[var(--sf-primary)]">Airport not found</h1>
        <p className="px-5 pt-1 text-[15px] text-[var(--sf-secondary)]">Check the code and try again.</p>
        <RoundButton icon={X} label="Close" onClick={nav.close} className="absolute top-4 right-4" />
      </div>
    );
  }

  const isFav = (favs.data ?? []).includes(icao);

  return (
    <div data-testid="airport-card" className="relative h-full overflow-y-auto">
      <header className="flex items-start gap-3 pt-4 pr-4 pb-3 pl-5">
        <div className="min-w-0 flex-1 pt-1">
          <div className="flex flex-wrap items-center gap-1">
            {info?.iata && <Chip>{info.iata}</Chip>}
            <Chip>{icao}</Chip>
            {info && (
              <span data-testid="airport-local-time">
                <Chip>{localTime(now, info.tz, twelveHour)}</Chip>
              </span>
            )}
          </div>
          <h1 className="mt-1.5 line-clamp-2 text-[26px] leading-[31px] font-bold text-[var(--sf-primary)]">{info?.name || icao}</h1>
          {info && (
            <p className="mt-0.5 text-[13px] font-medium tracking-wide text-[var(--sf-secondary)] uppercase">
              {info.country ? `${info.city}, ${countryName(info.country)}` : info.city}
            </p>
          )}
        </div>
        <div className="flex items-center gap-2">
          {!favs.isPending && !favs.isError && (
            <RoundButton
              icon={(p) => <Star {...p} fill={isFav ? "currentColor" : "none"} />}
              label={isFav ? "Remove from favorites" : "Add to favorites"}
              onClick={() => toggle.mutate({ icao, on: !isFav })}
            />
          )}
          <RoundButton icon={X} label="Close" onClick={nav.close} />
        </div>
      </header>
      <div className="flex flex-col gap-4 px-4 pt-2 pb-24">
        {weather.data && <WeatherBlock w={weather.data} now={now} />}
        {covered && faa.data?.available && <FaaBlock programs={faa.data.programs} />}
      </div>
    </div>
  );
}

function Chip({ children }: { children: string }) {
  return (
    <span className="rounded-[4px] border border-[var(--sf-grid)] bg-[var(--sf-card)] px-[5px] py-0.5 font-mono text-[11px] font-semibold text-[var(--sf-secondary)]">
      {children}
    </span>
  );
}

function useCategory(w: AirportConditions): string | null {
  const q = useQuery({
    queryKey: ["flightCategory", w.ceilingFt, w.visibilitySm, w.category],
    queryFn: () => categoryOf(w),
    staleTime: Number.POSITIVE_INFINITY,
  });
  return q.data ?? w.category;
}

function WeatherBlock({ w, now }: { w: AirportConditions; now: Date }) {
  const units = useUnits();
  const category = useCategory(w);
  const [name, line] = category ? (CATEGORY_NAME[category] ?? [category, ""]) : ["", ""];
  return (
    <section data-testid="weather-block" aria-label="Weather" className="rounded-[18px] bg-[var(--sf-card)] p-4">
      <div className="flex items-baseline justify-between gap-3">
        <p className="text-[34px] leading-[38px] font-bold tabular-nums text-[var(--sf-primary)]">{w.tempC !== null ? `${Math.round(w.tempC)}°C` : "--"}</p>
        <p className="text-[17px] font-semibold text-[var(--sf-primary)]">{w.condition}</p>
      </div>
      {w.summary && <p className="mt-1 text-[14.5px] text-[var(--sf-secondary)]">{w.summary}</p>}
      {category && (
        <div className="mt-3 rounded-[14px] bg-[var(--sf-row-alt)] p-3">
          <div className="flex items-center gap-2">
            <CategoryChip category={category} />
            <span className="text-[14px] font-semibold text-[var(--sf-primary)]">{name}</span>
          </div>
          {line && <p className="mt-1 text-[13.5px] text-[var(--sf-secondary)]">{line}</p>}
        </div>
      )}
      <dl className="mt-3 grid grid-cols-2 gap-x-4 gap-y-3 text-[14px]">
        <Fact label="Ceiling" value={w.ceilingFt === null ? "None" : `${w.ceilingFt.toLocaleString("en-US")} ft`} />
        <Fact label="Visibility" value={visibilityText(w.visibilitySm, units.distance)} />
        <Fact label="Wind" value={w.windKt === null ? "--" : `${w.windKt} kt`} sub={w.windDirDeg === null ? undefined : `from ${w.windDirDeg}°`} />
        <Fact label="Gusts" value={w.gustKt === null ? "None" : `${w.gustKt} kt`} />
      </dl>
      {w.observedAt && (
        <p className="mt-3 border-t border-[var(--sf-separator)] pt-3 font-mono text-[12px] text-[var(--sf-secondary)] uppercase">
          {`METAR observed ${ago(w.observedAt, now)}`}
        </p>
      )}
    </section>
  );
}

function Fact({ label, value, sub }: { label: string; value: string; sub?: string }) {
  return (
    <div>
      <dt className="text-[12px] font-medium text-[var(--sf-secondary)]">{label}</dt>
      <dd className="font-semibold tabular-nums text-[var(--sf-primary)]">
        {value}
        {sub && <span className="ml-1.5 font-normal text-[var(--sf-secondary)]">{sub}</span>}
      </dd>
    </div>
  );
}

function FaaBlock({ programs }: { programs: FaaProgram[] }) {
  return (
    <section data-testid="faa-block" aria-label="FAA status" className="rounded-[18px] bg-[var(--sf-card)] p-4">
      <h2 className="text-[17px] font-semibold text-[var(--sf-primary)]">FAA status</h2>
      {programs.length === 0 ? (
        <p className="mt-1 text-[14.5px] text-[var(--sf-secondary)]">No ground stops or delay programs right now.</p>
      ) : (
        programs.map((p, i) => (
          <div key={`${p.kind}-${i}`} className="mt-2.5">
            <p className="text-[15px] font-semibold text-[var(--sf-very-late)]">{PROGRAM_TITLE[p.kind]}</p>
            <p className="text-[13.5px] text-[var(--sf-secondary)]">
              {[p.reason, p.averageMinutes !== null ? `${p.averageMinutes} min average` : null].filter(Boolean).join(", ")}
            </p>
          </div>
        ))
      )}
    </section>
  );
}
