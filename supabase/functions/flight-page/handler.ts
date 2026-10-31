// GET /flight-page/<token>         -> the live page of a shared flight (text/html)
// GET /flight-page/<token>/og.png  -> its link preview image (image/png)
//
// Public: no account, no JWT (config.toml, verify_jwt = false). somalabs.me rewrites /f/<token> here, so
// a shared link reads https://somalabs.me/f/<token>. A token opens the page while its share is not revoked
// and its flight has not been down for 24 hours (_shared/share.ts); an unknown, revoked or expired token
// answers the same "no longer shared" page with 404, so a probe learns nothing.
//
// The page shows flight data only: the flights row, its two airports, its airline and the airline's logo.
// It never reads user_flights or past_flights, where the sharer's seat, booking code and notes live, and it
// never names the sharer. It calls no provider (free): the row is kept fresh by the sharer's follow.
//
// Answers may be cached for 30 seconds by the CDN in front (the page refreshes itself every 60), so a
// revoked link stops within half a minute.
import type { SupabaseClient } from "npm:@supabase/supabase-js@2";
import {
  hashToken,
  shareIsOpen,
  shareUrl,
  TOKEN_RE,
} from "../_shared/share.ts";
import {
  DEFAULT_APP_URL,
  pickLocale,
  renderGone,
  renderPage,
  renderUnavailable,
} from "./render.ts";
import {
  type AirlineRow,
  type AirportRow,
  buildView,
  FLIGHT_COLUMNS,
  type FlightRow,
} from "./view.ts";
import { ogImage } from "./og.ts";

export const PAGE_MAX_AGE = 30;
export const IMAGE_MAX_AGE = 300;
export const LOGO_URL_SECONDS = 3600;

export interface Deps {
  db: SupabaseClient;
  now?: () => Date;
  /** The public share base (SHARE_BASE_URL); somalabs.me/f/ otherwise. */
  base?: string | null;
  /** "Get Soma Flight" (GET_APP_URL); somalabs.me/flight otherwise. */
  appUrl?: string | null;
  /**
   * The project's public URL (PUBLIC_SUPABASE_URL), joined to signed logo paths. Inside the platform
   * SUPABASE_URL can be an internal host (kong:8000 on the local stack), useless to a browser.
   */
  publicUrl?: string | null;
  /** Test hook: the preview renderer (ogImage otherwise). */
  image?: typeof ogImage;
}

/** The token and whether the preview image is asked for, from /flight-page/<token>[/og.png]. */
export function parsePath(
  pathname: string,
): { token: string; image: boolean } | null {
  const parts = pathname.split("/").filter(Boolean);
  const i = parts.lastIndexOf("flight-page");
  const rest = i >= 0 ? parts.slice(i + 1) : parts;
  if (rest.length === 1 && TOKEN_RE.test(rest[0])) {
    return { token: rest[0], image: false };
  }
  if (rest.length === 2 && TOKEN_RE.test(rest[0]) && rest[1] === "og.png") {
    return { token: rest[0], image: true };
  }
  return null;
}

/** The page's security headers: nothing runs, nothing loads but our styles and the logo. */
export function pageHeaders(imgOrigin: string | null): Headers {
  const img = imgOrigin ? `${imgOrigin} data:` : "data:";
  return new Headers({
    "content-type": "text/html; charset=utf-8",
    "content-security-policy":
      `default-src 'none'; style-src 'unsafe-inline'; img-src ${img}; base-uri 'none'; form-action 'none'; frame-ancestors 'none'`,
    "referrer-policy": "no-referrer",
    "x-content-type-options": "nosniff",
    "x-robots-tag": "noindex, nofollow",
  });
}

function html(
  body: string,
  status: number,
  maxAge: number,
  imgOrigin: string | null = null,
): Response {
  const headers = pageHeaders(imgOrigin);
  headers.set(
    "cache-control",
    maxAge > 0 ? `public, max-age=${maxAge}, s-maxage=${maxAge}` : "no-store",
  );
  return new Response(body, { status, headers });
}

interface Shared {
  flight: FlightRow;
  origin: AirportRow | null;
  destination: AirportRow | null;
  airline: AirlineRow | null;
}

/** The open share's flight and what goes with it; null when the token opens nothing. */
async function load(
  db: SupabaseClient,
  token: string,
  now: Date,
): Promise<Shared | null> {
  const share = await db.from("flight_shares")
    .select("created_at, revoked_at, flight_id")
    .eq("token_hash", await hashToken(token)).maybeSingle();
  if (share.error) throw new Error(`share read failed: ${share.error.message}`);
  if (!share.data || share.data.revoked_at) return null;
  const f = await db.from("flights").select(FLIGHT_COLUMNS)
    .eq("id", share.data.flight_id).maybeSingle();
  if (f.error) throw new Error(`flight read failed: ${f.error.message}`);
  if (!f.data) return null;
  const flight = f.data as unknown as FlightRow;
  if (!shareIsOpen(share.data, flight, now)) return null;

  const codes = [flight.origin_icao, flight.destination_icao].filter(
    (c): c is string => !!c,
  );
  let airports: AirportRow[] = [];
  if (codes.length) {
    const a = await db.from("airports")
      .select("icao, iata, name, city, lat, lon, tz").in("icao", codes);
    if (a.error) throw new Error(`airport read failed: ${a.error.message}`);
    airports = (a.data ?? []) as AirportRow[];
  }
  const byIcao = (c: string | null) =>
    airports.find((a) => a.icao === c) ?? null;
  return {
    flight,
    origin: byIcao(flight.origin_icao),
    destination: byIcao(flight.destination_icao),
    airline: await airlineOf(db, flight),
  };
}

/** The operating airline: by the operator code (IATA or ICAO), else the ident's prefix. */
async function airlineOf(
  db: SupabaseClient,
  f: FlightRow,
): Promise<AirlineRow | null> {
  const code = (f.operator ?? /^([A-Z0-9]{2}[A-Z]?)\d/.exec(f.ident)?.[1] ?? "")
    .toUpperCase();
  if (!/^[A-Z0-9]{2,3}$/.test(code)) return null;
  const r = await db.from("airlines").select("icao, iata, name, color_primary")
    .eq(code.length === 3 ? "icao" : "iata", code).limit(1);
  if (r.error) throw new Error(`airline read failed: ${r.error.message}`);
  return (r.data?.[0] as AirlineRow | undefined) ?? null;
}

/**
 * A signed URL of the airline's logo for the dark page (the dark variant first), a PNG or SVG the browser
 * shows in an <img>; null when there is none, and on any failure (the page falls back to a monogram).
 */
async function logoUrl(
  db: SupabaseClient,
  airline: AirlineRow | null,
  publicUrl: string | null,
): Promise<string | null> {
  if (!airline || !publicUrl) return null;
  try {
    const r = await db.from("airline_assets")
      .select("kind, path, path_small, format")
      .eq("icao", airline.icao).in("kind", ["logo_dark", "logo"])
      .eq("aircraft_type", "");
    if (r.error || !r.data?.length) return null;
    const row = r.data.find((x) => x.kind === "logo_dark") ?? r.data[0];
    const path = row.path_small ??
      (row.format === "png" || row.format === "svg" ? row.path : null);
    if (!path) return null;
    const s = await db.storage.from("brand-assets").createSignedUrl(
      path,
      LOGO_URL_SECONDS,
    );
    if (s.error || !s.data) return null;
    const u = new URL(s.data.signedUrl);
    return new URL(u.pathname + u.search, publicUrl).toString();
  } catch (e) {
    console.error("share logo failed", e instanceof Error ? e.message : e);
    return null;
  }
}

export async function handler(req: Request, deps: Deps): Promise<Response> {
  const appUrl = deps.appUrl && /^https:\/\//.test(deps.appUrl)
    ? deps.appUrl
    : DEFAULT_APP_URL;
  if (req.method !== "GET" && req.method !== "HEAD") {
    return new Response(null, { status: 405, headers: { allow: "GET, HEAD" } });
  }
  const path = parsePath(new URL(req.url).pathname);
  if (!path) return html(renderGone(appUrl), 404, PAGE_MAX_AGE);
  const now = (deps.now ?? (() => new Date()))();
  let shared: Shared | null;
  try {
    shared = await load(deps.db, path.token, now);
  } catch (e) {
    console.error("flight-page failed", e instanceof Error ? e.message : e);
    return html(renderUnavailable(appUrl), 503, 0);
  }
  if (!shared) return html(renderGone(appUrl), 404, PAGE_MAX_AGE);
  const view = buildView(
    shared.flight,
    shared.origin,
    shared.destination,
    shared.airline,
    now,
  );

  if (path.image) {
    if (!shared.origin || !shared.destination) {
      return new Response(null, { status: 404 });
    }
    try {
      const png = await (deps.image ?? ogImage)({
        origin: shared.origin,
        destination: shared.destination,
        progress: view.flown,
        plane: view.position,
      });
      return new Response(png as BodyInit, {
        headers: {
          "content-type": "image/png",
          "cache-control":
            `public, max-age=${IMAGE_MAX_AGE}, s-maxage=${IMAGE_MAX_AGE}`,
          "x-content-type-options": "nosniff",
        },
      });
    } catch (e) {
      console.error(
        "flight-page image failed",
        e instanceof Error ? e.message : e,
      );
      return new Response(null, { status: 503 });
    }
  }

  const publicUrl = deps.publicUrl && /^https?:\/\//.test(deps.publicUrl)
    ? deps.publicUrl
    : null;
  const logo = await logoUrl(deps.db, shared.airline, publicUrl);
  const pageUrl = shareUrl(path.token, deps.base);
  const body = renderPage({
    view,
    origin: shared.origin,
    destination: shared.destination,
    logoUrl: logo,
    pageUrl,
    imageUrl: `${pageUrl}/og.png`,
    appUrl,
    locale: pickLocale(req.headers.get("accept-language")),
    now,
  });
  return html(
    req.method === "HEAD" ? "" : body,
    200,
    PAGE_MAX_AGE,
    logo ? new URL(logo).origin : null,
  );
}
