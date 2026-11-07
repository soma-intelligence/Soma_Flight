// Plain words for one decoded TAF period ("Light rain, wind 12 kt gusting 25 kt, visibility 3 mi,
// cloud base 800 ft"). The weather groups are read by the Rust core (describeWeather); this file only
// picks the words, in the same spirit as metar_words.ts.
import { describeWeather } from "./flightcore.ts";
import type { ForecastPeriod } from "./weather.ts";

const capitalized = (s: string) =>
  s.length ? s[0].toUpperCase() + s.slice(1) : s;

/** How a period relates to the forecast around it: "Gradually", "At times", "30% chance". */
export function changeWords(p: ForecastPeriod): string | null {
  switch (p.change) {
    case "BECMG":
      return "Gradually";
    case "TEMPO":
      return "At times";
    case "PROB":
      return p.probability !== null ? `${p.probability}% chance` : "Possible";
    case "FM":
      return "From then";
    default:
      return null;
  }
}

/** The wind of a period: "Calm", "Wind 12 kt", "Wind 12 kt gusting 25 kt"; null without a wind. */
export function windPhrase(p: ForecastPeriod): string | null {
  if (p.windKt === null) return null;
  if (p.windKt === 0 && p.gustKt === null) return "Calm";
  const gust = p.gustKt !== null ? ` gusting ${p.gustKt} kt` : "";
  return `Wind ${p.windKt} kt${gust}`;
}

/** Visibility in statute miles, "visibility 3 mi"; null when 6 miles or more (nothing to say). */
export function visibilityPhrase(p: ForecastPeriod): string | null {
  const v = p.visibilitySm;
  if (v === null || v >= 6) return null;
  const n = Number.isInteger(v) ? String(v) : String(Math.round(v * 10) / 10);
  return `visibility ${n} mi`;
}

/** "cloud base 800 ft" for a ceiling (broken or overcast layer); null without one. */
export function ceilingPhrase(p: ForecastPeriod): string | null {
  return p.ceilingFt === null ? null : `cloud base ${p.ceilingFt} ft`;
}

/**
 * One period in a sentence: the weather (or the sky), the wind, the visibility when it is poor, and the
 * cloud base when there is one. Our own words, nothing copied from the report.
 */
export function periodWords(p: ForecastPeriod): string {
  const said = p.wx ? describeWeather(p.wx).trim() : "";
  const first = said ? capitalized(said) : "No significant weather";
  const parts = [
    first,
    windPhrase(p)?.replace(/^./, (c) => c.toLowerCase()),
    visibilityPhrase(p),
    ceilingPhrase(p),
  ].filter((x): x is string => !!x);
  const lead = changeWords(p);
  const body = parts.join(", ");
  return lead ? `${lead}: ${body}` : body;
}
