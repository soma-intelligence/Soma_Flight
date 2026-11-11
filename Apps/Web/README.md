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
