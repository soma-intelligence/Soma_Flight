import { useQuery } from "@tanstack/react-query";
import { ChevronRight, Star, X } from "lucide-react";
import { useMemo } from "react";
import { useShellNav } from "@/app/nav";
import { airportList, airportWeatherKey, fetchAirportWeather, type AirportWeather } from "@/data/airports";
import { useFakes } from "@/data/flights";
import { airportsReady, useAirports, type AirportInfo } from "@/ui/airports";
import { CategoryChip } from "@/ui/CategoryChip";
import { RoundButton } from "@/ui/RoundButton";
import { categoryOf } from "./category";
import { useFavorites } from "./hooks";

/**
 * The Airports list over the globe, first cut of AirportsListView: the favourites, then the busiest hubs
 * of the world, each row with its code, name and city, and the flight category when the weather came.
 * A row opens the airport card. Weather is a nicety: when it fails the rows stay as they are.
 */
export function AirportsList() {
  const nav = useShellNav();
  const dir = useAirports();
  const fakes = useFakes();
  const favs = useFavorites();
  const ready = airportsReady(dir);

  const favorites = useMemo(() => favs.data ?? [], [favs.data]);
  const { yours, hubs } = useMemo(() => {
    const known = (c: string) => dir(c) !== null;
    const yours = airportList(favorites, known, []);
    const mine = new Set(yours);
    return { yours, hubs: airportList([], known).filter((c) => !mine.has(c)) };
  }, [dir, favorites]);

  const codes = [...yours, ...hubs];
  const weather = useQuery({
    queryKey: airportWeatherKey(codes),
    queryFn: () => fetchAirportWeather(codes),
    enabled: ready && !favs.isPending && codes.length > 0,
    staleTime: fakes ? Number.POSITIVE_INFINITY : 5 * 60_000,
  });
  const rows = weather.data;
  // The same source as the card: the core's category from ceiling and visibility.
  const categories = useQuery({
    queryKey: ["airportCategories", weather.dataUpdatedAt],
    queryFn: async () => new Map(await Promise.all((rows ?? []).map(async (r) => [r.icao, r.weather ? await categoryOf(r.weather) : null] as const))),
    enabled: !!rows,
    staleTime: Number.POSITIVE_INFINITY,
  });
  const byIcao = useMemo(
    () => (categories.data ? new Map((rows ?? []).map((w) => [w.icao, w])) : new Map<string, AirportWeather>()),
    [rows, categories.data],
  );
  const cats = categories.data;

  const loading = !ready || favs.isPending;

  return (
    <div data-testid="airports-card" className="relative h-full overflow-y-auto">
      <h1 className="px-5 pt-[22px] pr-[76px] pb-3 text-[32px] leading-[38px] font-bold text-[var(--sf-primary)]">Airports</h1>
      <RoundButton icon={X} label="Close" onClick={nav.close} className="absolute top-4 right-4" />
      {loading ? (
        <div role="status" aria-label="Loading airports" className="flex min-h-[200px] items-center justify-center">
          <span className="size-6 animate-spin rounded-full border-2 border-[var(--sf-separator)] border-t-[var(--sf-secondary)]" />
        </div>
      ) : (
        <div className="pb-24">
          <Group title="Favorites" subtitle="Airports you starred" codes={yours} dir={dir} weather={byIcao} cats={cats} onOpen={(c) => nav.open(`/airport/${c}`)} />
          <Group title="Busiest hubs" subtitle="Large airports around the world" codes={hubs} dir={dir} weather={byIcao} cats={cats} onOpen={(c) => nav.open(`/airport/${c}`)} />
          <p className="px-5 pt-6 text-[12px] text-[var(--sf-secondary)]">Weather from NOAA METARs, public data.</p>
        </div>
      )}
    </div>
  );
}

function Group({
  title,
  subtitle,
  codes,
  dir,
  weather,
  cats,
  onOpen,
}: {
  title: string;
  subtitle: string;
  codes: string[];
  dir: (c: string) => AirportInfo | null;
  weather: Map<string, AirportWeather>;
  cats: Map<string, string | null> | undefined;
  onOpen: (icao: string) => void;
}) {
  if (codes.length === 0) return null;
  return (
    <section aria-label={title}>
      <div className="px-5 pt-5 pb-1.5">
        <h2 className="text-[17px] font-semibold text-[var(--sf-primary)]">{title}</h2>
        <p className="text-[13px] text-[var(--sf-secondary)]">{subtitle}</p>
      </div>
      {codes.map((c, i) => {
        const a = dir(c);
        if (!a) return null;
        return (
          <Row key={c} airport={a} weather={weather.get(c)} category={cats?.get(c) ?? null} last={i === codes.length - 1} favorite={title === "Favorites"} onOpen={() => onOpen(a.icao)} />
        );
      })}
    </section>
  );
}

function Row({
  airport,
  weather,
  category,
  favorite,
  last,
  onOpen,
}: {
  airport: AirportInfo;
  weather: AirportWeather | undefined;
  category: string | null;
  favorite: boolean;
  last: boolean;
  onOpen: () => void;
}) {
  const w = weather?.weather;
  return (
    <button
      type="button"
      onClick={onOpen}
      className={`flex w-full items-center gap-3.5 px-5 py-3 text-left ${last ? "" : "border-b border-[var(--sf-separator)]"}`}
    >
      <span className="flex w-11 flex-col items-center gap-1">
        {favorite ? (
          <Star size={14} fill="currentColor" aria-hidden className="text-[var(--sf-accent)]" />
        ) : (
          <span className="size-3.5" aria-hidden />
        )}
        <span className="font-mono text-[12px] font-semibold text-[var(--sf-secondary)]">{airport.iata ?? airport.icao}</span>
      </span>
      <span className="min-w-0 flex-1">
        <span className="block truncate text-[16.5px] font-semibold text-[var(--sf-primary)]">{airport.name}</span>
        <span className="mt-0.5 flex items-center gap-2 text-[13.5px] text-[var(--sf-secondary)]">
          <span className="truncate">{airport.city}</span>
          {category && <CategoryChip category={category} />}
          {w?.tempC != null && <span className="tabular-nums">{`${Math.round(w.tempC)}°`}</span>}
        </span>
      </span>
      <ChevronRight size={14} strokeWidth={2.4} aria-hidden className="text-[var(--sf-secondary)] opacity-60" />
    </button>
  );
}
