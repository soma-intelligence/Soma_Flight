# Soma Flight Web, Plan 1 plus: Foundation and first cut of every tab

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Plan 1 ([2026-11-08-web-foundation.md](2026-11-08-web-foundation.md)) as written, plus a simple first version of Airports, Friends, Passport and Settings, running in the browser against the cloud Supabase project `Flight`.

**Spec:** [docs/superpowers/specs/2026-11-08-web-version-design.md](../specs/2026-11-08-web-version-design.md)

## Owner decisions (2026-11-11)

1. Scope: Plan 1 plus a simple version of every tab in this run. Plans 2 to 5 still bring full parity later.
2. Globe: MapKit JS as in the spec. Until the owner creates a MapKit JS key, the globe shows its fallback (dark fill and Retry). That fallback is the expected state in this run.
3. Data: the remote Supabase project `Flight` (`qhzglupzzrnixfvkepze`), publishable key only.
4. Git: commit on `main`, stage explicit paths, no push.

## Amendments to Plan 1

All Global Constraints of Plan 1 still hold. These rules change or add to it.

- **A1. Development proxy instead of a CORS deploy.** The edge functions send no CORS headers and nothing is deployed in this run. `vite.config.ts` proxies `/sb` (HTTP and WebSocket, for Realtime) to `https://qhzglupzzrnixfvkepze.supabase.co`, with `changeOrigin: true`. In development `client.ts` builds the client on `window.location.origin + "/sb"` when `VITE_SUPABASE_PROXY=1`. Task 1 (the `withCors` wrapper) is still written and tested with `deno test`, but not deployed.
- **A2. Env.** `Apps/Web/.env.local` (gitignored) holds `VITE_SUPABASE_URL`, `VITE_SUPABASE_PUBLISHABLE_KEY` (copied from `Apps/iOS/Config.local.xcconfig`, `SUPABASE_ANON_KEY`) and `VITE_SUPABASE_PROXY=1`. Never committed, never printed in a commit, a doc or a reply.
- **A3. No cloud change.** No migration, secret, function deploy or Auth setting change. The email link only returns to `http://localhost:5173/auth/callback` if that URL is already in the project's allowed redirects; if it is not, the run says so to the owner and verifies signed-in screens on `?fakes=1` instead.
- **A4. No paid calls in testing.** The cloud has no `AEROAPI_KEY`, so `flight-lookup` and `flight-schedules` answer 503 there. Search is verified on fakes plus one real call that shows the app's error copy. `airport-board` is not called (`BOARD_PROVIDER=none`).
- **A5. Fakes cover every tab** (`?fakes=1`, development only), so every screen can be screenshotted without an account.
- **A6. Task 12** runs against the cloud through the proxy (no `supabase start`). Screenshots at 1366 x 1024 and 390 x 844, light and dark, saved to the scratchpad.

## Tasks 1 to 12

As in Plan 1, with the amendments above.

## Task 13: Airports, first cut

**Files:** `src/screens/airports/Airports.tsx`, `Airports.test.tsx`, `src/screens/airport/AirportCard.tsx`, `AirportCard.test.tsx`, `src/data/airports.ts`, `airports.test.ts`, `src/fakes/airports.ts`

- Route `/airports` reached from the tab pill's search button area as in the app's Airports entry, and `/airport/:code` as a card over the list.
- List: favourite airports first (the favourites table in the contract), then the busiest hubs from the `airports` table, each row with code, name and city.
- Card: header (code, name, city, local time), weather from `airport-weather` with the flight category from `flight_category_js`, FAA status from `faa-status` for US airports, favourite toggle. A failed nicety shows nothing.
- Tests: list order (favourites first), card shows weather and category, FAA block hidden for a non-US airport, favourite toggle calls the right write.

## Task 14: Friends, first cut

**Files:** `src/screens/friends/Friends.tsx`, `Friends.test.tsx`, `src/screens/friend/FriendCard.tsx`, `src/data/friends.ts`, `friends.test.ts`, `src/fakes/friends.ts`

- `/friends`: the friends list from the Friends RPCs in the contract, the invitation link (create and copy), an empty state.
- `/friend/:id`: name, photo and the friend's flights that the RPC returns, rows as `FlightRow`.
- Tests: list renders, copy link calls the clipboard with the somalabs.me link, empty state.

## Task 15: Passport, first cut

**Files:** `src/screens/passport/Passport.tsx`, `Passport.test.tsx`, `src/screens/passport/AddPastFlight.tsx`, `src/data/passport.ts`, `passport.test.ts`, `src/core/flightcore.ts` (add `computePassport`), `src/fakes/passport.ts`

- `/passport`: stats from `compute_passport_js` (flights, distance, hours, airports, countries), a year switch, the list of past flights newest first.
- Add a past flight (number, date, from, to) and delete one, writing `past_flights` as the contract says. Export JSON and CSV in the browser.
- No import, no year in review, no map page in this cut (Plan 4).
- Tests: stats match a Rust fixture, delete removes the row, export CSV header matches `PastFlightExport.swift`.

## Task 16: Settings, first cut

**Files:** `src/screens/settings/Settings.tsx`, `Settings.test.tsx`, `src/data/settings.ts`, `settings.test.ts`

- `/settings`: profile name and email, units (stored with the profile as the app does, or local only if the app keeps it on the device), notification preferences read and written in `notification_preferences` with the note that alerts reach the phone, appearance (system, light, dark), sign out, delete account (confirm dialog, then `delete-account`, then sign out).
- Tests: toggling a preference writes the column, delete asks for confirmation before calling the function.

## Done

- `npx vitest run` green, `deno test` green for touched functions, `npm run build` with no env shows only "No server configured", no fake marker in `dist`.
- Every tab and card opened in the browser pane, wide and narrow, light and dark, screenshots in the scratchpad.
- Commits on `main`, not pushed.
