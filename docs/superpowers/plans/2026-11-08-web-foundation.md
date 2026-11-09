# Soma Flight Web, Plan 1: Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A signed-in web app at `Apps/Web` that shows the globe, the panel (wide) or bottom sheet (narrow), My Flights, a first cut of the flight card with Follow and Stop following, and Search by flight number, against the same Supabase backend as the apps.

**Architecture:** Vite + React 19 + TypeScript in `Apps/Web`, shadcn/ui on Tailwind 4 with FlightKit `Theme` colours as CSS variables. Data through `@supabase/supabase-js` (publishable key only) and TanStack Query, live rows through Supabase Realtime. Shared maths from `flightcore-wasm` built with `--target web`. Globe on MapKit JS with a token from a new `mapkit-token` edge function. Edge functions the browser calls gain CORS.

**Tech Stack:** Node 22, Vite, React 19, TypeScript, Tailwind CSS 4, shadcn/ui, React Router, TanStack Query, supabase-js 2, MapKit JS, Vitest, Testing Library, wasm-pack, Deno (edge functions).

**Spec:** [docs/superpowers/specs/2026-11-08-web-version-design.md](../specs/2026-11-08-web-version-design.md)

## The web plans

The spec covers several subsystems, so it ships in five plans. Each one leaves a working app.

1. **Foundation (this plan):** scaffold, theme, CORS, `mapkit-token`, wasm for the web, data layer, sign in by email link, shell (panel, sheet, tab pill, cards over the list), globe, My Flights, flight card first cut, Search by flight number.
2. **Flight card parity:** every `FlightDetailView` card in moment order, the Swift-only rules (tile order by moment, gate announcement, CO2, sun side, leave-by) moved into `flightcore` with their Swift callers switched, sharing, Apple and Google sign in.
3. **Airports:** list, airport card loading every part at once, favourites, aircraft stats, Search by route and airport.
4. **Friends, Passport, Settings:** invites, friend cards, Passport stats, map, pages, year in review, add, edit, delete, CSV, Flighty CSV and `.eml` import, JSON and CSV export, Settings, delete account, planned flights.
5. **Finish:** pull to refresh drawings on touch screens, keyboard navigation, Playwright end to end, visual check against the iPad simulator, the public flight page for signed-out `/flight/:id`, launch checklist.

## Global Constraints

- Publishable key only in the browser. Never put the service role key in `Apps/Web` or its env files.
- Fail closed: a production build without `VITE_SUPABASE_URL` and `VITE_SUPABASE_PUBLISHABLE_KEY` shows "No server configured" and nothing else.
- Fakes only in development (`?fakes=1`), compiled out of the production bundle.
- No analytics, no tracking, no third-party script beyond MapKit JS (`https://cdn.apple-mapkit.com/mk/5.x.x/mapkit.js`).
- Nothing stored beyond the Supabase session. TanStack Query cache in memory only.
- No deploy, no Vercel project, no DNS record, no Supabase secret or config change, and no edge function deploy without the owner's yes. All backend work in this plan is tested locally (`supabase start`, `deno test`).
- No em dash anywhere (code, copy, docs, commits). No Claude attribution.
- Our own copy and visuals, never another app's. English strings come from `Packages/FlightKit/Sources/FlightKit/Resources/Localizable.xcstrings`.
- Exact dependency versions in `package.json` (no `^` or `~`), versions at least two weeks old at install time.
- Stage paths explicitly, never `git add -A`. One shared checkout on `main`, no worktrees, no branches. Commit only after the owner's yes for the run.
- Apps API contract: [docs/api-contract.md](../../api-contract.md). The web app reads it; it does not change endpoints or tables.

## Rulings on gaps in the spec

- **CORS.** No edge function sends CORS headers today, so a browser cannot call them. Task 1 adds a shared CORS wrapper, allowing `WEB_ORIGINS` (comma list, default `https://flight.somalabs.me,http://localhost:5173`). This is transport only: bodies, codes and auth stay as in the contract. Plan 1 wraps the functions it calls; later plans wrap theirs.
- **`mapkit-token` rate limit.** Public functions here have no per-IP limiter. The function requires the user JWT instead and uses `checkRate(user, "mapkit-token", 30, 60)`. The globe is for signed-in users; the signed-out flight page (Plan 5) needs no map.
- **Planned flights** (import queue) are not in My Flights until Plan 4, which brings the import to the web.

## Review Focus

1. A flight row whose `scheduled_out` is null: My Flights must sort it last in Upcoming, as Swift's `.distantFuture`, not crash or sort first. Test in Task 9.
2. The email link opened in another browser or after the PKCE verifier is gone: the callback must show "This link has expired. Send a new one." and the sign-in form, not a blank page. Test in Task 6.
3. A `rate_limited` or `provider_unavailable` answer from `flight-lookup`: Search shows the app's error copy and keeps the typed query. Test in Task 11.
4. MapKit token fetch fails or MapKit JS fails to load: the panel keeps working over a plain dark background with a quiet Retry. Test in Task 8.
5. The window crossing 768 px while a card is open: the open card stays open (same route) when the panel turns into the sheet and back. Test in Task 7.

---

### Task 1: CORS for the edge functions the web calls

**Files:**
- Create: `supabase/functions/_shared/cors.ts`
- Create: `supabase/functions/_shared/cors_test.ts`
- Modify: `supabase/functions/flight-lookup/index.ts`, `supabase/functions/follow-flight/index.ts`, `supabase/functions/flight-position/index.ts`

**Interfaces:**
- Produces: `withCors(handler: (req: Request) => Response | Promise<Response>, origins?: string[]): (req: Request) => Promise<Response>` and `webOrigins(): string[]` (reads `WEB_ORIGINS`).

- [ ] **Step 1: Write the failing tests** in `cors_test.ts`:
  - `OPTIONS from an allowed origin answers 204` with `Access-Control-Allow-Origin` equal to that origin, `Access-Control-Allow-Headers` containing `authorization, x-client-info, apikey, content-type`, `Access-Control-Allow-Methods` `GET, POST, DELETE, OPTIONS`, `Access-Control-Max-Age` `600`, `Vary: Origin`, and the wrapped handler not called.
  - `a POST from an allowed origin keeps the handler's status and body and adds Allow-Origin`.
  - `an origin not in the list gets no Allow-Origin header` (status and body unchanged).
  - `a request with no Origin (the apps) is passed through untouched`.
  - `webOrigins() defaults to https://flight.somalabs.me and http://localhost:5173` and splits a set `WEB_ORIGINS` on commas, trimming spaces.
- [ ] **Step 2:** Run `cd supabase/functions && deno test _shared/cors_test.ts`. Expected: FAIL, module not found.
- [ ] **Step 3: Implement `withCors` and `webOrigins`.** Headers are added on a copy of the response (`new Response(res.body, res)`), never by mutating a shared object.
- [ ] **Step 4:** Wrap each listed `index.ts`: `Deno.serve(withCors((req) => handler(req, deps)))`.
- [ ] **Step 5:** Run `deno test _shared/cors_test.ts flight-lookup follow-flight flight-position`. Expected: PASS, and the functions' existing tests still pass.
- [ ] **Step 6: Commit** `feat: CORS for the functions the web app calls`.

### Task 2: `mapkit-token` edge function

**Files:**
- Create: `supabase/functions/mapkit-token/index.ts`, `handler.ts`, `handler_test.ts`
- Modify: `supabase/config.toml` (function entry, `verify_jwt = true`), `supabase/functions/.env.example` if present (names only: `MAPKIT_KEY_ID`, `MAPKIT_TEAM_ID`, `MAPKIT_PRIVATE_KEY`), `docs/api-contract.md` (new `## mapkit-token` section)

**Interfaces:**
- Consumes: `requireUser` (`_shared/auth.ts`), `checkRate` (`_shared/limits.ts`), `json`, `errorResponse`, `ApiError` (`_shared/errors.ts`), `withCors` (Task 1).
- Produces: `GET /mapkit-token` returns `{ "token": string, "expiresAt": string }` (ISO 8601). `handler(req, deps: { verify: TokenVerifier, rate: typeof checkRate, now: () => Date, secrets: { keyId, teamId, privateKey } | null })`.

- [ ] **Step 1: Write the failing tests** in `handler_test.ts` (generate a throwaway P-256 key in the test with `crypto.subtle`):
  - `no JWT answers 401 unauthorized`.
  - `missing secrets answer 503 provider_unavailable` with no token in the body.
  - `a signed-in GET returns an ES256 JWT` whose header has `alg: "ES256"`, `kid` = key id, `typ: "JWT"`, and whose payload has `iss` = team id, `iat` = now, `exp` = now + 1800, `origin` = the request's `Origin` when it is in `webOrigins()`; the signature verifies with the public key.
  - `an Origin outside webOrigins() answers 400 invalid_request`, so a token is never minted for another site.
  - `a rate_limited ApiError from rate answers 429`.
- [ ] **Step 2:** `deno test mapkit-token`. Expected: FAIL.
- [ ] **Step 3: Implement** with `npm:jose@5` (`SignJWT`, `importPKCS8`); `checkRate(user.id, "mapkit-token", 30, 60)`. Secrets read once from `Deno.env` in `index.ts`.
- [ ] **Step 4:** `deno test mapkit-token`. Expected: PASS. `deno lint mapkit-token`. Expected: clean.
- [ ] **Step 5: Commit** `feat: mapkit-token edge function (local only, not deployed)`.

### Task 3: flightcore for the browser

**Files:**
- Modify: `core/scripts/build-wasm.sh` (add a `--web` flag; without it, behaviour is unchanged)
- Create: `Apps/Web/src/core/pkg/` (wasm-pack output, committed like the Deno package), `Apps/Web/src/core/flightcore.ts`, `Apps/Web/src/core/flightcore.test.ts`

**Interfaces:**
- Produces in `flightcore.ts`: `initCore(): Promise<void>` (idempotent), `distanceKm(a: LatLon, b: LatLon): number`, `greatCircle(a: LatLon, b: LatLon, segments: number): LatLon[]`, `type LatLon = { lat: number; lon: number }`. Later plans add wrappers here, one per `*_js` export, never calling the pkg directly from screens.

- [ ] **Step 1:** `build-wasm.sh --web` runs `wasm-pack build flightcore-wasm --target web --release --out-dir ../../Apps/Web/src/core/pkg -- --locked` and removes the generated `.gitignore`. Read `core/flightcore-wasm/src/lib.rs` for the exact JSON shapes `distance_km_js` and `great_circle_js` take and return.
- [ ] **Step 2: Write the failing tests** (Vitest, Node loads the `.wasm` with `fs.readFile` passed to `init`): `distanceKm SFO to JFK matches core/fixtures` (take the expected value from the fixture the Rust and Swift tests use, tolerance 0.5 km), `greatCircle returns segments + 1 points starting at a and ending at b`, `initCore twice loads once`.
- [ ] **Step 3:** Run after Task 4's scaffold exists; if Task 4 is not done, do Task 4 first and come back. Expected: FAIL, then implement, then PASS with `npx vitest run src/core`.
- [ ] **Step 4: Commit** `feat: flightcore wasm built for the web`.

### Task 4: Scaffold `Apps/Web` with the app's theme

**Files:**
- Create: `Apps/Web/` (Vite React TS template, then trimmed), `package.json`, `vite.config.ts`, `tsconfig*.json`, `index.html`, `components.json`, `src/main.tsx`, `src/ui/theme.css`, `src/ui/theme.test.ts`, `src/app/config.ts`, `src/app/config.test.ts`, `src/app/NoServer.tsx`, `.env.example`, `README.md`
- Modify: `.gitignore` (root: `Apps/Web/node_modules`, `Apps/Web/dist`, `Apps/Web/.env*.local`)

**Interfaces:**
- Produces: `readConfig(env: Record<string, string | undefined>, prod: boolean): { url: string; key: string } | null`. Null in production when either value is missing or the URL is not `https://` (except `http://127.0.0.1` and `http://localhost` in development). `theme.css` defines every `Theme` colour as `--sf-<name>` for light and dark, and maps shadcn's tokens (`--background`, `--foreground`, `--card`, `--primary`, `--muted-foreground`, `--border`, `--ring`) onto them.

- [ ] **Step 1:** Scaffold with `npm create vite` (react-ts), add Tailwind 4 (`@tailwindcss/vite`), `npx shadcn init`, Vitest, `@testing-library/react`, `jsdom`. Pin exact versions. `.env.example` lists only `VITE_SUPABASE_URL=` and `VITE_SUPABASE_PUBLISHABLE_KEY=`.
- [ ] **Step 2: Write the failing tests:**
  - `config.test.ts`: `production without URL returns null`, `production without key returns null`, `production with http URL returns null`, `development accepts http://127.0.0.1:58321`, `production with https URL and key returns both`.
  - `theme.test.ts`: reads `theme.css` and `Packages/FlightKit/Sources/FlightKit/UI/Theme.swift`; for every `Color(light: 0x..., dark: 0x...)` in Theme.swift there is a `--sf-<name>` with the same light hex under `:root` and the same dark hex under the dark selector. This keeps the two in step.
- [ ] **Step 3:** Run `npx vitest run`. Expected: FAIL.
- [ ] **Step 4: Implement** `readConfig`, `theme.css` (dark via `@media (prefers-color-scheme: dark)` and `[data-theme="dark"]`, light override `[data-theme="light"]`), `NoServer` ("No server configured", nothing else), and `main.tsx` rendering `NoServer` when `readConfig` is null.
- [ ] **Step 5:** `npx vitest run` PASS. `npm run build` with no env, then `grep -r "No server configured" dist` finds it.
- [ ] **Step 6: Commit** `feat: web app scaffold with FlightKit theme tokens`.

### Task 5: Data layer and development fakes

**Files:**
- Create: `src/data/client.ts`, `src/data/api.ts`, `src/data/api.test.ts`, `src/data/types.ts`, `src/data/decode.ts`, `src/data/decode.test.ts`, `src/data/flights.ts`, `src/data/flights.test.ts`, `src/data/realtime.ts`, `src/fakes/index.ts`, `src/fakes/flights.ts`

**Interfaces:**
- Consumes: `readConfig` (Task 4).
- Produces:
  - `type ApiErrorCode = "unauthorized" | "invalid_request" | "not_found" | "rate_limited" | "plan_limit" | "out_of_window" | "provider_unavailable"`; `class ApiError extends Error { code: ApiErrorCode; status: number }`; `apiErrorFrom(status: number, body: unknown): ApiError` (unknown code becomes `provider_unavailable`, as `APIError(code:)`).
  - `callFunction<T>(name: string, init: { method?: "GET" | "POST" | "DELETE"; query?: Record<string, string>; body?: unknown }): Promise<T>` through `supabase.functions.invoke`, throwing `ApiError`.
  - `type Flight` mirroring the `flights` table columns in the contract (dates as `Date`), `type FlightStatus`.
  - `decodeFlight(row: unknown): Flight` (snake_case to camelCase, ISO dates with or without milliseconds).
  - `fetchMyFlights(): Promise<{ createdAt: Date; flight: Flight }[]>` (`user_flights` select `created_at, flights(*)` order `created_at`), `fetchFlight(id: string): Promise<Flight | null>`, `followFlight(input)`, `unfollowFlight(id)` per the contract's `follow-flight` section.
  - `subscribeFlights(ids: string[], onRow: (f: Flight) => void): () => void` (one channel on `flights` filtered `id=in.(...)`, as `SupabaseFlightService`).
  - Query keys: `["myFlights"]`, `["flight", id]`.
  - `useFakes(): boolean`: true only when `import.meta.env.DEV` and `?fakes=1`. `src/fakes` is imported only behind `if (import.meta.env.DEV)` so the production bundle drops it.
- [ ] **Step 1: Write the failing tests:** `apiErrorFrom maps each contract code and status`, `unknown code becomes provider_unavailable`, `decodeFlight reads dates with and without milliseconds`, `decodeFlight keeps null scheduled_out as null`, `fetchMyFlights builds the user_flights query` (supabase client mocked), `subscribeFlights removes its channel on unsubscribe`.
- [ ] **Step 2:** `npx vitest run src/data`. Expected: FAIL. Implement. Expected: PASS.
- [ ] **Step 3:** `npm run build`, then `grep -rl "FAKE_FLIGHT_MARKER" dist` finds nothing (put that string in `src/fakes/flights.ts`).
- [ ] **Step 4: Commit** `feat: web data layer, error mapping, realtime and dev fakes`.

### Task 6: Sign in by email link

**Files:**
- Create: `src/screens/sign-in/SignIn.tsx`, `src/screens/sign-in/SignIn.test.tsx`, `src/app/AuthCallback.tsx`, `src/app/AuthCallback.test.tsx`, `src/app/AuthGate.tsx`, `src/app/AuthGate.test.tsx`, `src/app/session.ts`

**Interfaces:**
- Consumes: `client.ts` (Task 5), created with `auth: { flowType: "pkce", persistSession: true, storage: localStorage }` (the session is the only stored item).
- Produces: `useSession(): { session: Session | null; loading: boolean }`, `signOut(): Promise<void>`, routes `/sign-in` and `/auth/callback`. `AuthGate` saves the wanted path in `sessionStorage` key `sf.return` before sending to `/sign-in`, and the callback returns there.
- [ ] **Step 1: Write the failing tests:**
  - `SignIn sends signInWithOtp with emailRedirectTo origin + /auth/callback` and then shows the app's "Check your email" copy.
  - `AuthCallback exchanges the code and navigates to the saved path`.
  - `AuthCallback with a missing or expired code shows "This link has expired. Send a new one." and the form` (Review Focus 2).
  - `AuthCallback ignores a #access_token fragment` (as the apps).
  - `AuthGate sends a signed-out visit to /flight/abc to /sign-in and remembers /flight/abc`.
- [ ] **Step 2:** FAIL, implement (copy from `Localizable.xcstrings`; the expired-link line is new copy, add it to the xcstrings English and French too), PASS.
- [ ] **Step 3: Commit** `feat: web sign in by email link (PKCE)`.

### Task 7: Shell: panel, bottom sheet, tab pill, cards over the list

**Files:**
- Create: `src/app/routes.tsx`, `src/app/Shell.tsx`, `src/app/Shell.test.tsx`, `src/app/Panel.tsx`, `src/app/Sheet.tsx`, `src/app/sheetGeometry.ts`, `src/app/sheetGeometry.test.ts`, `src/app/CardStack.tsx`, `src/ui/TabPill.tsx`, `src/app/useWide.ts`

**Interfaces:**
- Produces:
  - Routes: `/` (My Flights), `/friends`, `/passport` (placeholders until Plan 4), `/flight/:id`, `/airport/:code` and `/friend/:id` (placeholders until Plans 3 and 4), `/search`, `/settings/*` (placeholder with Sign out). A card route renders over its tab's list: the tab is remembered in router state, back returns to it.
  - `type Detent = "collapsed" | "medium" | "expanded"`; `sheetTop(detent, g: SheetGeometry): number`; `snap(top: number, velocity: number, g): Detent`, ported one to one from `Packages/FlightKit/Sources/FlightKit/App/SheetDetents.swift` with its constants.
  - `useWide(): boolean` (`(min-width: 768px)`).
  - `Panel`: 402 px wide, 16 px from the left, 8 px below the top, to the bottom edge, top corners 30 px, `--sf-background`, pill and search button at its foot, list fading out above the pill.
  - `Sheet`: same content, three detents, grabber 36 x 5 in a 22 px strip, drag with pointer events, tap steps up (from expanded back to collapsed), arrow keys on the focused grabber step it.
  - `CardStack`: the open card rises from the bottom, `transform: translateY` only, 420 ms `cubic-bezier(0.2, 0.9, 0.1, 1)`, lower card dimmed by a black overlay at 0.3. No shadow or scale animation (smoothness rule, 2026-11-08).
  - `TabPill`: My Flights, Friends, Passport and the search button; labels from xcstrings.
- [ ] **Step 1: Write the failing tests:** `snap` cases copied from `SheetGeometrySnapshotTests.swift` and the Swift detent tests (same inputs, same detent), `sheetTop for each detent matches Swift`, `Shell shows Panel at 1024 px and Sheet at 500 px`, `an open /flight/x card stays open when the width crosses 768 px` (Review Focus 5), `back from /flight/x returns to the tab underneath`.
- [ ] **Step 2:** FAIL, implement, PASS.
- [ ] **Step 3: Commit** `feat: web shell with the panel, the sheet and cards over the list`.

### Task 8: Globe on MapKit JS

**Files:**
- Create: `src/app/globe/loadMapKit.ts`, `src/app/globe/Globe.tsx`, `src/app/globe/Globe.test.tsx`, `src/app/globe/content.ts`, `src/app/globe/content.test.ts`

**Interfaces:**
- Consumes: `callFunction` (Task 5), `greatCircle` (Task 3), `useWide` (Task 7).
- Produces:
  - `loadMapKit(fetchToken: () => Promise<string>): Promise<typeof mapkit>`: inserts the MapKit JS script once, `mapkit.init({ authorizationCallback })`, the callback calling `mapkit-token` again before `expiresAt`.
  - `globeContent(flights: Flight[], now: Date): { routes: LatLon[][]; planes: { id: string; at: LatLon; heading: number }[]; airports: { code: string; at: LatLon }[] }`.
  - `Globe`: satellite map type, globe projection where MapKit JS offers it, labels and 3D switches top right, padding left equal to 418 px when wide and 0 when narrow, routes as polylines, planes as annotations rotated by heading. On load failure: `--sf-background` dark fill and a small Retry button, the panel unaffected (Review Focus 4).
- [ ] **Step 1: Write the failing tests:** `globeContent draws one route per flight with both airports known`, `a flight with no position puts no plane`, `Globe shows Retry when loadMapKit rejects and calls it again on click` (MapKit mocked).
- [ ] **Step 2:** FAIL, implement, PASS.
- [ ] **Step 3: Commit** `feat: web globe on MapKit JS`.

### Task 9: My Flights

**Files:**
- Create: `src/screens/my-flights/MyFlights.tsx`, `MyFlights.test.tsx`, `groups.ts`, `groups.test.ts`, `src/ui/FlightRow.tsx`, `src/ui/format.ts`, `src/ui/format.test.ts`

**Interfaces:**
- Consumes: `fetchMyFlights`, `subscribeFlights` (Task 5).
- Produces: `groupMyFlights(flights: Flight[], now: Date): { title: "In the Air" | "Upcoming" | "Recent"; rows: Flight[] }[]`, a port of `MyFlightsStore.isLive`, `byOut`, `LandedFlights.isOver` and `MyFlightsView.groups` without planned flights. `format.ts` mirrors the parts of `UI/Format.swift` the row uses (times in the airport's zone, duration).
- [ ] **Step 1: Write the failing tests:** each case of the Swift tests for `MyFlightsView.groups`, `isLive` and `isOver` (find them with `grep -rn "groups(live" Packages/FlightKit/Tests`), plus `a null scheduled_out sorts last in Upcoming` (Review Focus 1); `MyFlights shows the empty state with the jet illustration when there are no rows`; `a realtime row update moves a flight from Upcoming to In the Air without a reload`; `format` cases copied from the Swift `Format` tests the row uses.
- [ ] **Step 2:** FAIL, implement, PASS. The row's layout follows `MyFlightRow`; the jet illustration is redrawn as SVG from `EmptyStateIllustration.swift`.
- [ ] **Step 3: Commit** `feat: web My Flights`.

### Task 10: Flight card, first cut

**Files:**
- Create: `src/screens/flight/FlightCard.tsx`, `FlightCard.test.tsx`, `src/screens/flight/Header.tsx`, `Timetable.tsx`, `Progress.tsx`

**Interfaces:**
- Consumes: `fetchFlight`, `followFlight`, `unfollowFlight`, `subscribeFlights` (Task 5), `CardStack` (Task 7).
- Produces: route `/flight/:id` showing header (number, airline, route, status colour from `--sf-on-time` and friends), timetable (scheduled, estimated, actual, gate, terminal), estimated progress, Follow or Stop following. The other cards arrive in Plan 2; nothing shows a dead control meanwhile.
- [ ] **Step 1: Write the failing tests:** `shows the flight's number and route`, `Follow calls follow-flight and the button turns to Stop following`, `plan_limit shows the app's free plan copy`, `an unknown id shows not found copy`.
- [ ] **Step 2:** FAIL, implement, PASS.
- [ ] **Step 3: Commit** `feat: web flight card first cut with follow`.

### Task 11: Search by flight number

**Files:**
- Create: `src/screens/search/Search.tsx`, `Search.test.tsx`, `src/screens/search/parse.ts`, `parse.test.ts`

**Interfaces:**
- Consumes: `callFunction("flight-lookup", ...)` per the contract's `flight-lookup` and `flight-lookup dates` sections.
- Produces: `/search` with a field, the date chips the app shows (today, tomorrow, yesterday) and results; a result opens `/flight/:id`. Command K or Control K opens it; Escape closes it; arrows and Enter move through results. `parseFlightNumber(text: string): { airline: string; number: string } | null` ported from the Swift search parser (`grep -rn "func parse" Packages/FlightKit/Sources/FlightKit/Stores/SearchStore.swift`).
- [ ] **Step 1: Write the failing tests:** the Swift parser's test cases, `out_of_window shows the app's date copy`, `rate_limited and provider_unavailable show the app's error copy and keep the query` (Review Focus 3), `Command K opens Search from My Flights`.
- [ ] **Step 2:** FAIL, implement, PASS.
- [ ] **Step 3: Commit** `feat: web Search by flight number`.

### Task 12: Local end-to-end check and docs

**Files:**
- Modify: `Apps/Web/README.md`, `README.md` (one line pointing to the web app), `GOAL.md` only if a priority line needs a status note

- [ ] **Step 1:** `supabase start`, `supabase functions serve` with local `MAPKIT_*` values left empty, `npm run dev` with the local URL and its demo publishable key. Sign in with a local Inbucket email, follow a seeded flight, see it in My Flights, open its card, stop following. Globe shows Retry (no MapKit key locally), panel works.
- [ ] **Step 2:** `npx vitest run` all green; `deno test` for the touched functions green; `npm run build` with no env shows only "No server configured"; no fakes in `dist`.
- [ ] **Step 3:** Screenshots at 1366 x 1024 and 390 x 844, light and dark, next to the iPad and iPhone simulator at the same size, saved to the scratchpad, never to the repo.
- [ ] **Step 4: Commit** `docs: web app local setup`.
