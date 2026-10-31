// The share page's HTML: one self-contained document (inline CSS and SVG, no script, no web font, no
// framework), in the app's dark design. It reloads itself every minute with a meta refresh, so it stays
// live with nothing to run. Every text that comes from data goes through `esc`.
import { routeMapSvg } from "./map.ts";
import {
  type AirportRow,
  duration,
  type FlightView,
  type Side,
  TONE_COLOR,
} from "./view.ts";

export const REFRESH_SECONDS = 60;
/** Where "Get Soma Flight" goes when GET_APP_URL is not set. */
export const DEFAULT_APP_URL = "https://somalabs.me/flight";

export function esc(s: string): string {
  return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;").replace(/'/g, "&#39;");
}

/** A locale the runtime knows, from the viewer's Accept-Language; en-US otherwise. */
export function pickLocale(acceptLanguage: string | null): string {
  for (const part of (acceptLanguage ?? "").split(",")) {
    const tag = part.split(";")[0].trim();
    if (!tag || tag === "*") continue;
    try {
      const [ok] = Intl.DateTimeFormat.supportedLocalesOf([tag]);
      if (ok) return ok;
    } catch {
      // A malformed tag is skipped.
    }
  }
  return "en-US";
}

function fmt(
  locale: string,
  tz: string,
  opts: Intl.DateTimeFormatOptions,
): Intl.DateTimeFormat {
  try {
    return new Intl.DateTimeFormat(locale, { ...opts, timeZone: tz });
  } catch {
    return new Intl.DateTimeFormat(locale, { ...opts, timeZone: "UTC" });
  }
}

const clock = (t: number, tz: string, locale: string) =>
  fmt(locale, tz, { hour: "numeric", minute: "2-digit" }).format(t);
const day = (t: number, tz: string, locale: string) =>
  fmt(locale, tz, { weekday: "short", day: "numeric", month: "short" })
    .format(t);

/** What the page needs besides the view. */
export interface PageInput {
  view: FlightView;
  origin: AirportRow | null;
  destination: AirportRow | null;
  /** A signed URL of the airline's logo, or null for the monogram. */
  logoUrl: string | null;
  /** This page's public URL (og:url). */
  pageUrl: string;
  /** The preview image's public URL (og:image). */
  imageUrl: string;
  appUrl: string;
  locale: string;
  now: Date;
}

/** "Paris to San Francisco": the cities, else the codes. */
export function routeTitle(v: FlightView): string {
  return `${v.origin.city ?? v.origin.code} to ${
    v.destination.city ?? v.destination.code
  }`;
}

/** The preview text: "AF 84 · Paris to San Francisco" and "On time · Departs Sat 31 Oct 10:35 CDG". */
export function ogText(
  v: FlightView,
  locale: string,
): { title: string; description: string } {
  const title = `${v.ident} · ${routeTitle(v)}`;
  const parts = [v.status.text];
  const dep = v.origin.time;
  if (dep !== null) {
    parts.push(
      `Departs ${day(dep, v.origin.tz, locale)} ${
        clock(dep, v.origin.tz, locale)
      } ${v.origin.code}`,
    );
  }
  const arr = v.destination.time;
  if (arr !== null) {
    parts.push(
      `Arrives ${clock(arr, v.destination.tz, locale)} ${v.destination.code}`,
    );
  }
  return { title, description: parts.join(" · ") };
}

function mark(v: FlightView, logoUrl: string | null): string {
  if (logoUrl) {
    return `<img class="mark" src="${
      esc(logoUrl)
    }" alt="" width="40" height="40">`;
  }
  const code = v.airline?.iata ?? v.ident.split(" ")[0];
  const color = /^#[0-9A-Fa-f]{6}$/.test(v.airline?.color_primary ?? "")
    ? v.airline!.color_primary
    : "#2C2C2F";
  return `<div class="mark mono" style="background:${color}" aria-hidden="true">${
    esc(code)
  }</div>`;
}

function timeBlock(s: Side, locale: string): string {
  if (s.time === null) return `<div class="time">--:--</div>`;
  const best = clock(s.time, s.tz, locale);
  const moved = s.scheduled !== null &&
    Math.abs(s.time - s.scheduled) >= 60_000;
  const was = moved
    ? `<s class="was">${esc(clock(s.scheduled!, s.tz, locale))}</s>`
    : "";
  return `<div class="time" style="color:${TONE_COLOR[s.tone]}">${
    esc(best)
  }</div>${was}`;
}

function facts(s: Side, arrival: boolean): string {
  const rows: [string, string | null][] = [
    ["Terminal", s.terminal],
    ["Gate", s.gate],
  ];
  if (arrival) rows.push(["Belt", s.belt]);
  return `<dl class="facts">${
    rows.map(([k, v]) =>
      `<div><dt>${k}</dt><dd>${v ? esc(v) : "&ndash;"}</dd></div>`
    ).join("")
  }</dl>`;
}

function sideCard(
  s: Side,
  title: string,
  arrival: boolean,
  locale: string,
): string {
  const when = s.time !== null ? `${day(s.time, s.tz, locale)} · ` : "";
  return `<section class="card side">
<div class="kicker">${title}</div>
<div class="code">${esc(s.code)}</div>
<div class="place">${esc(s.name ?? s.city ?? "")}</div>
<div class="when"><span>${esc(when)}${esc(s.label)}</span></div>
<div class="times">${timeBlock(s, locale)}</div>
${facts(s, arrival)}
</section>`;
}

function progressBar(v: FlightView, now: Date): string {
  if (v.progress === null) return "";
  const pct = Math.round(v.progress * 1000) / 10;
  const left = v.destination.time !== null && v.destination.time > now.getTime()
    ? `${duration(v.destination.time - now.getTime())} left`
    : "";
  return `<div class="progress" role="progressbar" aria-valuemin="0" aria-valuemax="100" aria-valuenow="${
    Math.round(pct)
  }" aria-label="Trip progress">
<div class="ends"><span>${esc(v.origin.code)}</span><span>${
    esc(left)
  }</span><span>${esc(v.destination.code)}</span></div>
<div class="track"><div class="fill" style="width:${pct}%"></div><div class="plane" style="left:${pct}%"></div></div>
</div>`;
}

function ago(then: number, now: Date): string {
  const m = Math.max(0, Math.floor((now.getTime() - then) / 60_000));
  if (m < 1) return "just now";
  if (m < 60) return `${m} min ago`;
  const h = Math.floor(m / 60);
  return h < 24 ? `${h} hr ago` : `${Math.floor(h / 24)} d ago`;
}

const CSS = `
:root{color-scheme:dark;--bg:#18181A;--card:#202023;--pill:#2C2C2F;--sep:#2E2E31;--fg:#FFFFFF;--fg2:#96969D;--accent:#0A84FF}
*{box-sizing:border-box}
html,body{margin:0;background:var(--bg);color:var(--fg)}
body{font:16px/1.35 -apple-system,BlinkMacSystemFont,"SF Pro Text","Helvetica Neue",Helvetica,Arial,sans-serif;-webkit-font-smoothing:antialiased}
main{max-width:560px;margin:0 auto;padding:20px 16px 40px}
header{display:flex;align-items:center;gap:12px}
.mark{width:40px;height:40px;border-radius:10px;flex:none;object-fit:contain;background:var(--pill)}
.mono{display:flex;align-items:center;justify-content:center;font-weight:700;font-size:14px;color:#fff;letter-spacing:.02em}
.id{font-size:14px;color:var(--fg2);font-weight:500}
h1{font-size:26px;line-height:1.15;margin:14px 0 8px;font-weight:700;letter-spacing:-.01em}
.status{display:flex;align-items:center;gap:10px;flex-wrap:wrap;font-size:15px}
.pill{display:inline-flex;align-items:center;gap:6px;padding:4px 10px;border-radius:999px;background:var(--pill);font-weight:600}
.pill i{width:8px;height:8px;border-radius:50%;display:inline-block}
.count{color:var(--fg2)}
.map{margin:18px 0 0;border-radius:14px;overflow:hidden;background:var(--card);line-height:0}
.map svg{width:100%;height:auto;display:block}
.progress{margin:14px 0 0}
.ends{display:flex;justify-content:space-between;font-size:13px;color:var(--fg2);margin-bottom:6px;font-weight:600}
.track{position:relative;height:6px;border-radius:3px;background:var(--pill)}
.fill{position:absolute;left:0;top:0;bottom:0;border-radius:3px;background:var(--accent)}
.plane{position:absolute;top:50%;width:14px;height:14px;margin:-7px 0 0 -7px;border-radius:50%;background:var(--accent);border:2px solid var(--fg)}
.sides{display:grid;grid-template-columns:1fr 1fr;gap:12px;margin-top:16px}
.card{background:var(--card);border-radius:14px;padding:14px}
.kicker{font-size:13px;color:var(--fg2);font-weight:600;text-transform:uppercase;letter-spacing:.04em}
.code{font-size:30px;font-weight:700;margin-top:4px;letter-spacing:.01em}
.place{font-size:13px;color:var(--fg2);min-height:1.35em;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.when{font-size:13px;color:var(--fg2);margin-top:10px}
.times{display:flex;align-items:baseline;gap:8px;flex-wrap:wrap}
.time{font-size:24px;font-weight:700;font-variant-numeric:tabular-nums}
.was{color:var(--fg2);font-size:15px}
.facts{display:grid;grid-template-columns:repeat(3,auto);justify-content:start;gap:4px 18px;margin:12px 0 0;padding-top:12px;border-top:1px solid var(--sep)}
.facts div{min-width:0}
.facts dt{font-size:12px;color:var(--fg2)}
.facts dd{margin:0;font-size:17px;font-weight:600}
.updated{margin-top:14px;font-size:13px;color:var(--fg2);text-align:center}
.get{display:block;margin:24px auto 0;width:fit-content;padding:12px 22px;border-radius:999px;background:var(--accent);color:#fff;font-weight:600;text-decoration:none}
.note{margin-top:12px;font-size:12px;color:var(--fg2);text-align:center}
@media (max-width:380px){.sides{grid-template-columns:1fr}}
`.trim();

function head(
  title: string,
  description: string,
  extra: string,
): string {
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<meta name="robots" content="noindex,nofollow">
<meta name="referrer" content="no-referrer">
<meta name="theme-color" content="#18181A">
<title>${esc(title)}</title>
<meta name="description" content="${esc(description)}">
${extra}<style>${CSS}</style>
</head>`;
}

/** The live page for one shared flight. */
export function renderPage(p: PageInput): string {
  const { view: v, locale, now } = p;
  const { title, description } = ogText(v, locale);
  const og = [
    `<meta http-equiv="refresh" content="${REFRESH_SECONDS}">`,
    `<meta property="og:type" content="website">`,
    `<meta property="og:site_name" content="Soma Flight">`,
    `<meta property="og:title" content="${esc(title)}">`,
    `<meta property="og:description" content="${esc(description)}">`,
    `<meta property="og:url" content="${esc(p.pageUrl)}">`,
    `<meta property="og:image" content="${esc(p.imageUrl)}">`,
    `<meta property="og:image:width" content="1200">`,
    `<meta property="og:image:height" content="630">`,
    `<meta property="og:image:alt" content="${
      esc(`Route map from ${v.origin.code} to ${v.destination.code}`)
    }">`,
    `<meta name="twitter:card" content="summary_large_image">`,
  ].join("\n") + "\n";
  const map = p.origin && p.destination
    ? `<div class="map">${
      routeMapSvg(
        {
          origin: p.origin,
          destination: p.destination,
          progress: v.flown,
          plane: v.position ?? null,
        },
        560,
        280,
      )
    }</div>`
    : "";
  const airline = v.airline ? ` · ${esc(v.airline.name)}` : "";
  return `${head(title, description, og)}
<body>
<main>
<header>${mark(v, p.logoUrl)}<div class="id">${
    esc(v.ident)
  }${airline}</div></header>
<h1>${esc(routeTitle(v))}</h1>
<div class="status"><span class="pill"><i style="background:${
    TONE_COLOR[v.status.tone]
  }"></i>${esc(v.status.text)}</span>${
    v.countdown ? `<span class="count">${esc(v.countdown)}</span>` : ""
  }</div>
${map}
${progressBar(v, now)}
<div class="sides">
${sideCard(v.origin, "Departure", false, locale)}
${sideCard(v.destination, "Arrival", true, locale)}
</div>
<div class="updated">Updated ${
    ago(v.updatedAt, now)
  } · refreshes every minute</div>
<a class="get" href="${esc(p.appUrl)}">Get Soma Flight</a>
<div class="note">Shared from Soma Flight. Times are local to each airport.</div>
</main>
</body>
</html>
`;
}

/** A page with a title and one line: a closed link, or a failure on our side. */
function renderMessage(appUrl: string, title: string, line: string): string {
  return `${head(title, "Track your own flights with Soma Flight.", "")}
<body>
<main>
<h1>${esc(title)}</h1>
<p class="count">${esc(line)}</p>
<a class="get" href="${esc(appUrl)}">Get Soma Flight</a>
</main>
</body>
</html>
`;
}

/** The page for a link that is unknown, revoked or past its flight: the same for all three. */
export function renderGone(appUrl: string): string {
  return renderMessage(
    appUrl,
    "This flight is no longer shared",
    "The link has expired or the person who shared it stopped sharing.",
  );
}

/** The page when we could not read the flight: try again in a minute. */
export function renderUnavailable(appUrl: string): string {
  return renderMessage(
    appUrl,
    "Flight data is unavailable",
    "We could not load this flight just now. Try again in a minute.",
  );
}
