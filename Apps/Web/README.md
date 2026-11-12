# Soma Flight web

Vite, React 19, TypeScript, Tailwind 4, shadcn/ui. Colours come from FlightKit's `Theme.swift` through `src/ui/theme.css`; `npm test` fails if the two drift.

## Run

    cp .env.example .env.local   # fill in the Supabase URL and publishable key
    npm install
    npm run dev                  # http://localhost:5173
    npm test
    npm run build

Only the publishable key belongs here. Never the service role key.

A production build without `VITE_SUPABASE_URL` and `VITE_SUPABASE_PUBLISHABLE_KEY` (https only) shows "No server configured".

`VITE_SUPABASE_PROXY=1` (development only) sends Supabase traffic through the dev server's `/sb` proxy, because the edge functions that send CORS headers (`withCors`, see `docs/api-contract.md`) are not deployed yet.

## What the browser keeps

The spec keeps nothing in the browser except the Supabase session. A few user conveniences are the exception, as the iOS app keeps them on the device too (owner's ruling, 2026-11-11). They are per browser, never synced to the account:

| Key | Storage | What |
| --- | --- | --- |
| `sf.appearance` | localStorage | System, light or dark, set in Settings. Sets `data-theme` on `<html>`; system leaves it off. |
| `sf.units` | localStorage | Distance (km or mi) and the 12 or 24 hour clock, set in Settings. Every distance and time follows it live (`useUnits`). |
| `sf.favoriteAirports` | localStorage | The favourite airports (ICAO codes), set with the star on an airport card. |
| `sf.return` | sessionStorage | The path to return to after the sign-in link, taken once. |
| `sf.fakes` | sessionStorage | Development only (`?fakes=1`), compiled out of production. |

TanStack Query's cache stays in memory and is cleared on sign out.
