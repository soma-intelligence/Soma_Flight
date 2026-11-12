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

`VITE_SUPABASE_PROXY=1` (development only) sends Supabase traffic through the dev server's `/sb` proxy, because the edge functions send no CORS headers yet.

## What the browser keeps

The spec keeps nothing in the browser except the Supabase session. Two user conveniences are the exception, as the iOS app keeps them on the device too (owner's ruling, 2026-11-11): `sf.appearance` (system, light or dark; sets `data-theme` on `<html>`, system leaves it off) and `sf.units` (distance and 12 or 24 hour clock), both set in Settings. The Supabase session aside, `sf.fakes` and `sf.return` live in sessionStorage only. TanStack Query's cache stays in memory.
