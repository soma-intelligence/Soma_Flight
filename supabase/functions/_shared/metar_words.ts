// Plain words for a decoded METAR: the sky or the present weather ("Light rain and mist",
// "Mostly cloudy") and the wind ("light winds"), for the airport list and the status card. The
// present weather groups are read by the Rust core (describeWeather); this file only picks words.
import type { CloudLayer } from "./weather.ts";
import { describeWeather } from "./flightcore.ts";

/** Sky cover order, thinnest first. VV (vertical visibility) is an obscured sky. */
const COVER_RANK: Record<string, number> = {
  FEW: 1,
  SCT: 2,
  BKN: 3,
  OVC: 4,
  OVX: 5,
  VV: 5,
};

/** The sky in words from the cloud layers: the thickest layer decides. */
export function skyWords(clouds: CloudLayer[]): string {
  let worst = 0;
  for (const c of clouds) worst = Math.max(worst, COVER_RANK[c.cover] ?? 0);
  switch (worst) {
    case 1:
      return "A few clouds";
    case 2:
      return "Partly cloudy";
    case 3:
      return "Mostly cloudy";
    case 4:
      return "Overcast";
    case 5:
      return "Sky obscured";
    default:
      return "Clear skies";
  }
}

const capitalized = (s: string) =>
  s.length ? s[0].toUpperCase() + s.slice(1) : s;

/**
 * What it looks like outside: the present weather when there is some ("Light rain and mist"),
 * else the sky.
 */
export function conditionWords(
  wx: string | null,
  clouds: CloudLayer[],
): string {
  const said = wx ? describeWeather(wx).trim() : "";
  return said ? capitalized(said) : skyWords(clouds);
}

/** The wind in a few words, lower case; null when the report has no wind. */
export function windWords(
  windKt: number | null,
  gustKt: number | null,
): string | null {
  if (windKt === null) return null;
  if (gustKt !== null && gustKt >= 25) return "gusty winds";
  if (windKt <= 3) return "calm winds";
  if (windKt <= 10) return "light winds";
  if (windKt <= 20) return "a steady breeze";
  return "strong winds";
}

/** One sentence for the status card: "Partly cloudy with light winds." */
export function weatherSentence(
  wx: string | null,
  clouds: CloudLayer[],
  windKt: number | null,
  gustKt: number | null,
): string {
  const condition = conditionWords(wx, clouds);
  const wind = windWords(windKt, gustKt);
  return wind ? `${condition} with ${wind}.` : `${condition}.`;
}
