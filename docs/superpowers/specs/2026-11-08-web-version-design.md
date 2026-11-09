# Soma Flight on the web: design

Date: 2026-11-08. Owner decisions in this session: public, full parity with the iPad and Mac apps, Vite + React + shadcn/ui, MapKit JS for the globe, same Supabase backend and accounts. Listed in [GOAL.md](../../../GOAL.md) as priority 7.

## Goal

A public web app at `flight.somalabs.me` that a Soma Flight account holder signs into and finds the same flights, friends and Passport as on their iPhone, laid out like the iPad and Mac apps: the satellite globe across the window, the tab's screen in a panel on the left, and a flight, airport or friend opening in that panel.

Done means: every screen listed under Screens works against the production backend with a real account, in current Safari, Chrome and Firefox on desktop and on a phone, in light and dark, with no fakes in the production build.

## Principles (from GOAL.md, held here)

- No analytics, no tracking, no third-party scripts beyond MapKit JS. No cookie banner is needed because nothing but the Supabase session is stored.
- Publishable key only in the browser. The service role key never leaves Supabase.
- Fail closed: a production build without `VITE_SUPABASE_URL` and `VITE_SUPABASE_PUBLISHABLE_KEY` shows "No server configured" and nothing else.
- Fakes only in development (`?fakes=1`, compiled out of the production bundle).
- No deploy, no Vercel project, no DNS record and no Supabase change without the owner's yes.
- No em dash in code, copy or docs. Our own copy and visuals, never another app's.

## Architecture

```
Apps/Web/                Vite + React 19 + TypeScript, shadcn/ui on Tailwind 4
  src/app/               shell: panel, globe, routing, auth gate
  src/screens/           one folder per screen (my-flights, flight, search, airport, airports,
                         friends, passport, settings, sign-in)
  src/data/              Supabase client, typed queries, edge function calls, realtime
  src/core/              thin wrapper over flightcore-wasm
  src/fakes/             development fixtures (excluded from production builds)
  src/ui/                shadcn components plus the app's own pieces (rows, tiles, pills)
supabase/functions/mapkit-token/   new: signs a short-lived MapKit JS token
core/flightcore-wasm/              built with --target web for the browser as well as deno
```

- **Routing**: React Router with real URLs so a flight can be shared and reloaded: `/` (My Flights), `/friends`, `/passport`, `/flight/:id`, `/airport/:code`, `/friend/:id`, `/search`, `/settings/*`. A card route keeps the tab underneath (the panel shows the card over the tab's list, back returns to it).
- **Data**: `@supabase/supabase-js` with the publishable key. Same tables and RPCs as the apps (`user_flights`, `past_flights`, `flights`, the friends RPCs, `notification_preferences`, favourite airports) and the same edge functions (`flight-lookup`, `follow-flight`, `flight-position`, `flight-insights`, `flight-brief`, `alternate-flights`, `flight-schedules`, `airport-board`, `airport-stats`, `airport-weather`, `faa-status`, `faa-notams`, `security-wait`, `share-flight`, `friends`, `brand-asset`, `delete-account`). The contract is [docs/api-contract.md](../../api-contract.md); the web app reads it, it does not change it.
- **Server state**: TanStack Query for loading, caching and the same freshness rules as the apps (each part has its TTL and reloads on its own when stale, with no "Updated N min ago" line). Live updates through Supabase Realtime on `flights`, as `SupabaseFlightService` does, with no per-user polling.
- **Shared logic**: `flightcore-wasm` gives the browser the same Rust as the apps (distances, great circles, Passport stats and detail, aircraft stats, weather category and impact, delay and gate predictions). `core/scripts/build-wasm.sh` gains a `--target web` output for `Apps/Web`. Logic that lives only in Swift today and that a web screen needs (for example tile order by moment, the gate announcement rule, CO2, sun side, leave-by) moves into `flightcore` first, with its Swift caller switched to it, so both clients share one implementation. Plain formatting (dates, units) stays in TypeScript, mirroring `Format`.
- **Globe**: MapKit JS, satellite with the globe projection, 3D and labels switches. Routes as great-circle overlays from `flightcore`, planes as annotations with heading, airports with status dots, the camera framing the visible area beside the panel (padding equal to the panel's width). Token from `mapkit-token`, refreshed before expiry.
- **`mapkit-token`**: a Deno edge function that signs an ES256 JWT (MapKit JS key id, team id, origin `https://flight.somalabs.me` plus localhost in development, 30 minute lifetime) from secrets `MAPKIT_KEY_ID`, `MAPKIT_TEAM_ID`, `MAPKIT_PRIVATE_KEY`. No database access. Rate limited per IP like the other public functions.

## Sign in

- Email link (PKCE), as the apps. The redirect URL `https://flight.somalabs.me/auth/callback` joins Supabase's allowed redirects (owner's yes needed for that config change).
- Apple and Google through Supabase OAuth. Owner steps: an Apple Services ID with the web return URL, and a Google web client ID, both entered in Supabase Auth.
- Same accounts: one sign-in shows the same followed flights, Passport and friends as the phone.
- Sign out clears the session. Account deletion calls `delete-account`, the same as the apps, and accounts are only marked deleted on the server, as everywhere.

## Layout

- **Wide (768 px and up)**: the globe fills the window. The panel is 402 px wide, 16 px from the left edge and 8 px below the top, running down to the bottom edge, rounded at the top only, in the sheet colour. The tab pill and the search button sit at its foot, the list fading out above them as in the app. A card opens over the list in the same panel with the app's motion; Escape or the back button closes it. The 3D and labels switches float at the top right of the globe.
- **Narrow (under 768 px)**: the panel becomes the iPhone's bottom sheet with its three heights (collapsed, medium, expanded), dragged by its grabber, the tab pill at the foot.
- **Theme**: light and dark from the system (a Settings override as in the app). FlightKit's `Theme` colours, radii and type scale become CSS variables that shadcn's tokens point at, so shadcn components look like the app's.
- **Keyboard**: Command K or Control K opens Search; arrows and Enter move through results; Escape closes a card or Search.
- **Pull to refresh**: on touch screens the list's pull runs the same two drawings as iOS (the icon jet or the departure board, at random), drawn on a canvas from the same numbers. On desktop the lists reload on their own and on focus.

## Screens (full parity)

Each screen copies its SwiftUI counterpart's content, order and wording (`Localizable.xcstrings` gives the English strings; French follows the app's).

- **My Flights**: In the Air, Upcoming (with planned flights), Recent; rows as `MyFlightRow`; offline banner; empty state with the jet illustration.
- **Flight detail**: the cards of `FlightDetailView` in the order the moment calls for (a week before, day of travel, in flight, landed), including the gate rule ("Not announced yet, around HH:MM" about 45 min before boarding, the number once known, hidden once archived), timetable, estimated progress, plane and route history, brief, predictions, forecast, FAA advisories, security wait and leave-by, connection, emissions, sun and window seat, landmarks, cancellation kit, travel documents, sharing (link and image), Follow and Stop following.
- **Search**: flight number, route or airport with the app's suggestions, chips and date picker; a result opens the flight card.
- **Airports**: the list (favourites, then hubs by status, region filter) and the airport card loading every part at once (boards, daily performance, stats, weather, operations report, FAA, security, Runway Regulars); favourite toggle; aircraft stats.
- **Friends**: invitation links (somalabs.me link and `somaflight://i/` token), the list, a friend's card and their flights, as the Friends tab.
- **Passport**: stats, map, full pages, year in review cards, add and edit a past flight, delete; import from CSV, Flighty CSV and a dropped email file (`.eml`), read in the browser and never uploaded raw; export JSON and CSV.
- **Settings**: profile, units, travel tools, travel documents, notification preferences (saved on the server, delivered to the phone), acknowledgements, sign out, delete account.

## Not on the web

Live Activities, widgets, Watch, CarPlay, Apple Health features (jet lag plan, recovery: health data stays on the phone), Wallet passes, calendar sync, app icon choice, Siri. Alerts stay on the phone: no web push in this release. Each screen that would mention one of these says nothing about it rather than showing a dead control.

## Errors and edge cases

- Offline: a calm banner, the last data kept on screen (TanStack Query cache persisted in memory only, nothing written to disk beyond the Supabase session).
- A failed part shows the app's error banner with retry and keeps what it had; a failed nicety (security, FAA) shows nothing.
- Expired session: back to sign-in, then back to the same URL.
- A shared `/flight/:id` opened signed out: the public flight page (`flight-page`) content, with a sign-in button to follow it.
- MapKit token failure: the panel keeps working over a plain dark background with a quiet retry.
- No board provider: no "data plan" note, only the parts that have data, as in the app since 2026-11-08.

## Testing

- Unit tests (Vitest) for the data layer, formatting, the wasm wrapper and the moment-based card order, with fixtures from `core/fixtures` shared with the Rust and Swift tests.
- Component tests (Testing Library) for each screen against the development fakes.
- End to end (Playwright, local Supabase from `supabase start`) for sign in by email, follow and unfollow a flight, open an airport, add and export a past flight, accept a friend invite.
- Visual check of each screen against the iPad simulator at the same width, light and dark.
- `supabase/functions/mapkit-token` gets a Deno test like the other functions.

## Owner steps before launch

1. A MapKit JS key in the Apple Developer account (Certificates, IDs and Profiles, Keys, MapKit JS), its id, team id and private key stored as Supabase secrets.
2. Apple Services ID and Google web client for OAuth, entered in Supabase Auth; the web callback URL added to the allowed redirects.
3. A Vercel project for `Apps/Web` and the `flight.somalabs.me` DNS record.
4. A yes to deploy `mapkit-token` and the web app.

## Out of scope

New backend features, web push, a public marketing site (the landing stays at somalabs.me), offline install (PWA) beyond what the browser does by default.
