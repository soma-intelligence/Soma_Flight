# Soma Flight Backend Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the Supabase backend that finds, follows, and pushes live updates for flights, serves cached airport boards with delay stats and weather, and keeps each user's flight history.

**Architecture:** One Supabase project. Postgres holds shared flight rows and per-user rows behind RLS. Deno edge functions are the only callers of AeroAPI and aviationweather.gov; AeroAPI alerts arrive by webhook and fan out through Realtime and APNs. pg_cron runs board refresh, archiving, and the spend alert.

**Tech Stack:** Supabase CLI, Postgres 17, pgTAP (`supabase test db`), pg_cron, pg_net, Deno 2 edge functions, `jsr:@supabase/supabase-js@2`, `npm:jose@5` (APNs JWT), AeroAPI v4, aviationweather.gov data API, Resend (owner email).

**Spec:** `docs/superpowers/specs/2026-10-28-soma-flight-v1-design.md`

## Global Constraints

- The app never calls AeroAPI. Only edge functions hold `AEROAPI_KEY`.
- One `flights` row per real flight, unique on `provider_id` (AeroAPI `fa_flight_id`). One alert subscription per flight row.
- `flight-lookup` limit: 30 searches per user per hour.
- Free plan: 3 active followed flights. Pro: unlimited. `profiles.plan` is set by hand until the paywall ships.
- Board TTL 5 minutes; weather TTL 15 minutes.
- Alert subscriptions are deleted 24 hours after a flight lands.
- Typed error codes, exactly: `provider_unavailable`, `not_found`, `rate_limited`, `plan_limit`, `unauthorized`.
- RLS on every user table; users never read another user's followed or past flights.
- Account deletion sets `profiles.status = 'deleted'`, deletes the user's `user_flights`, `past_flights`, `push_tokens`, then the auth user. Never hard-delete `profiles`.
- No em dashes in code, comments, or copy.

## Review Focus

1. **The same AeroAPI alert delivered twice** (provider retries): one `flight_events` row and one push, not two. Test in Task 5.
2. **A flight followed by a user who then deletes their account**: no push token remains and the alert is dropped when no followers are left. Test in Task 8.
3. **Airport code typed as IATA (`AUS`) instead of ICAO (`KAUS`)**: board and weather still resolve. Test in Task 7.
4. **AeroAPI returns 429 or 5xx during a board refresh**: the stale snapshot is served with its real `fetched_at` and `stale: true`, never an empty board. Test in Task 7.
5. **Flight crossing midnight or diverted**: archiving uses the actual arrival airport and actual block time, and a diverted or canceled flight is archived with its status, not as a normal landing. Test in Task 9.

---

## File Structure

```
supabase/
  config.toml
  migrations/
    20261028000001_core_schema.sql        tables, indexes, RLS
    20261028000002_airports_seed.sql      airports reference data (generated)
    20261028000003_jobs.sql               archive + cleanup SQL functions, pg_cron schedules
  seed/airports.csv                       OurAirports subset (public domain)
  scripts/build_airports_seed.ts          CSV to SQL migration
  tests/
    rls_test.sql                          pgTAP: isolation between two users
    archive_test.sql                      pgTAP: archive_landed_flights()
  functions/
    _shared/errors.ts                     ApiError + JSON responses
    _shared/auth.ts                       user from JWT, service client
    _shared/aeroapi.ts                    AeroAPI client + usage counting
    _shared/aeroapi_types.ts              provider types + mapping to flights rows
    _shared/delay_stats.ts                pure stats over board rows
    _shared/weather.ts                    METAR/TAF fetch + flight category
    _shared/apns.ts                       APNs JWT + send
    _shared/fixtures/*.json               recorded provider payloads
    flight-lookup/index.ts
    follow-flight/index.ts
    aeroapi-webhook/index.ts
    push-sender/index.ts
    airport-board/index.ts
    delete-account/index.ts
    usage-alert/index.ts
    refresh-boards/index.ts
```

Spec addition found during planning: map pins, distance, and IATA/ICAO resolution need an `airports` reference table (ICAO, IATA, name, city, country code, lat, lon, tz). It is seeded from OurAirports (public domain) for airports with scheduled service.

---

### Task 1: Pricing and terms gate

**Files:**
- Create: `docs/provider-check.md`

- [ ] **Step 1:** Open FlightAware's AeroAPI pricing and terms pages. Record in `docs/provider-check.md`: tier names, monthly minimums, per-result-set price for `/flights/{ident}`, `/flights/search`, `/airports/{id}/flights/*`, alerts, and whether the terms allow showing data to consumers in a paid app.
- [ ] **Step 2:** Write a monthly estimate for 1,000 and 10,000 active users using the spec's cost rules (shared rows, 5 min board TTL, alerts not polling).
- [ ] **Step 3:** Stop and ask the owner to confirm AeroAPI or switch to Cirium. Do not start Task 3 until confirmed. Tasks 2 and onward that do not hit the provider may continue.
- [ ] **Step 4:** Commit `docs: AeroAPI pricing and terms check`.

### Task 2: Project, schema, airports, RLS

**Files:**
- Create: `supabase/config.toml` (via `supabase init`), `supabase/migrations/20261028000001_core_schema.sql`, `supabase/migrations/20261028000002_airports_seed.sql`, `supabase/scripts/build_airports_seed.ts`, `supabase/seed/airports.csv`, `supabase/tests/rls_test.sql`

**Interfaces:**
- Produces tables exactly as in spec section 4, plus:
  - `airports(icao text pk, iata text unique null, name text, city text, country text, lat float8, lon float8, tz text)`
  - `rate_events(id bigserial, user_id uuid, endpoint text, at timestamptz default now())`, index `(user_id, endpoint, at)`
  - `flights.status` enum `flight_status`: `scheduled, departed, en_route, landed, arrived, canceled, diverted, unknown`
  - `flight_events.kind` enum `flight_event_kind`: `gate_change, delay, departure, arrival, cancel, diversion, position`
  - `airport_snapshots` primary key `(icao, kind)`, kind enum `snapshot_kind`: `departures, arrivals, stats, weather`
  - `profiles.plan` enum `plan`: `free, pro`; `profiles.status` enum `account_status`: `active, deleted`
  - Trigger `on_auth_user_created` inserts a `profiles` row.
  - Realtime publication `supabase_realtime` includes `flights`.

- [ ] **Step 1: Write the failing pgTAP test** `supabase/tests/rls_test.sql`: create users A and B; as service role insert one flight, `user_flights` and `past_flights` for A; then as B (`set local role authenticated; set local request.jwt.claims = '{"sub":"<B>"}'`):
  - `is((select count(*) from user_flights), 0::bigint)`
  - `is((select count(*) from past_flights), 0::bigint)`
  - `is((select count(*) from push_tokens), 0::bigint)`
  - `is((select count(*) from flights), 1::bigint)` (shared rows readable)
  - `throws_ok($$insert into flights(provider_id, ident) values ('x','X1')$$)` (clients cannot write flights)
  - `throws_ok($$select * from webhook_inbox$$)` or zero rows with no grant
  - as A: `is((select count(*) from user_flights), 1::bigint)`
- [ ] **Step 2:** `supabase start && supabase test db`. Expected: FAIL, relations missing.
- [ ] **Step 3:** Write `20261028000001_core_schema.sql`: tables, enums, indexes (`flights(ident, scheduled_out)`, `user_flights(flight_id)`, `flight_events(flight_id, received_at)`), RLS policies (owner-only via `auth.uid() = user_id` on user tables; `select` to `authenticated` on `flights`, `flight_events`, `airport_snapshots`, `airports`; no client grants on `webhook_inbox`, `usage_counters`, `rate_events`), profile trigger, realtime publication.
- [ ] **Step 4:** Write `build_airports_seed.ts` (`deno run -A supabase/scripts/build_airports_seed.ts supabase/seed/airports.csv > supabase/migrations/20261028000002_airports_seed.sql`). Keep rows where `scheduled_service = 'yes'` and `ident` is 4 letters. Download `airports.csv` from ourairports.com into `supabase/seed/` and commit it.
- [ ] **Step 5:** `supabase db reset && supabase test db`. Expected: PASS. Also `select count(*) from airports` returns more than 3000 and `select icao from airports where iata = 'AUS'` returns `KAUS`.
- [ ] **Step 6:** Commit `feat(db): core schema, airports, RLS`.

### Task 3: Shared function modules (errors, auth, AeroAPI client)

**Files:**
- Create: `supabase/functions/_shared/errors.ts`, `auth.ts`, `aeroapi.ts`, `aeroapi_types.ts`, `fixtures/flight_af84.json`, `fixtures/departures_kaus.json`
- Test: `supabase/functions/_shared/aeroapi_test.ts`

**Interfaces:**
- Produces:
  - `type ErrorCode = "provider_unavailable" | "not_found" | "rate_limited" | "plan_limit" | "unauthorized"`
  - `class ApiError extends Error { constructor(code: ErrorCode, status: number, message?: string) }`
  - `json(body: unknown, status?: number): Response`, `errorResponse(e: unknown): Response` with body `{ "error": { "code": ErrorCode, "message": string } }` (unknown errors become 500 `provider_unavailable`)
  - `requireUser(req: Request): Promise<{ userId: string }>` throws `unauthorized`
  - `serviceClient(): SupabaseClient`
  - `class AeroApi { constructor(key: string, fetchFn?: typeof fetch, onCall?: (endpoint: string) => Promise<void>) ; flightsByIdent(ident: string, start?: string, end?: string): Promise<AeroFlight[]>; flightById(faFlightId: string): Promise<AeroFlight | null>; searchRoute(origin: string, destination: string, date: string): Promise<AeroFlight[]>; airportFlights(icao: string, kind: "departures" | "arrivals"): Promise<AeroFlight[]>; createAlert(ident: string, start: string, end: string): Promise<number>; deleteAlert(alertId: number): Promise<void> }`
  - `toFlightRow(f: AeroFlight): FlightRow` (snake_case row for `flights` upsert)
- AeroAPI base `https://aeroapi.flightaware.com/aeroapi`, header `x-apikey`. 404 maps to `not_found`; 429 to `rate_limited`; 5xx and network errors to `provider_unavailable`. Every call invokes `onCall(endpoint)`, which increments `usage_counters(day, endpoint)`.

- [ ] **Step 1: Write failing tests** in `aeroapi_test.ts` using a fake `fetchFn`:
  - `flightsByIdent parses fixture`: returns one flight with `ident_iata === "AF84"`; `toFlightRow` gives `origin_icao === "LFPG"` and a non-null `scheduled_out`.
  - `404 becomes not_found`, `429 becomes rate_limited`, `503 becomes provider_unavailable`, `fetch throws becomes provider_unavailable` (assert `e.code`).
  - `onCall is invoked once per request with the endpoint path`.
  - `sends x-apikey header`.
- [ ] **Step 2:** `deno test -A supabase/functions/_shared/`. Expected: FAIL.
- [ ] **Step 3:** Record the two fixtures from the AeroAPI personal tier (or the AeroAPI docs examples if Task 1 is not cleared), then implement the modules.
- [ ] **Step 4:** Run tests. Expected: PASS.
- [ ] **Step 5:** Commit `feat(functions): shared errors, auth, AeroAPI client`.

### Task 4: flight-lookup and follow-flight

**Files:**
- Create: `supabase/functions/flight-lookup/index.ts`, `supabase/functions/follow-flight/index.ts`, `supabase/functions/_shared/limits.ts`
- Test: `supabase/functions/flight-lookup/index_test.ts`, `supabase/functions/follow-flight/index_test.ts`

**Interfaces:**
- Consumes: Task 3 modules.
- Produces:
  - `POST /flight-lookup` body `{ ident?: string, origin?: string, destination?: string, date: "YYYY-MM-DD" }` (either `ident` or both airports; airports accept IATA or ICAO, resolved through `airports`). Returns `{ flights: FlightRow[] }` after upserting by `provider_id`.
  - `POST /follow-flight` body `{ flightId: string, notify?: boolean }` returns `{ ok: true }`; `DELETE /follow-flight` body `{ flightId }` unfollows and deletes the alert when no followers remain.
  - `checkRate(userId, endpoint, max, windowMinutes): Promise<void>` throws `rate_limited`; `checkPlanFollowLimit(userId): Promise<void>` throws `plan_limit` when plan is `free` and active follows (flights not `arrived`, `canceled`) are 3 or more.
- Handlers export `handler(req: Request, deps: Deps): Promise<Response>` so tests inject a fake `AeroApi` and a test DB client; `Deno.serve` wraps it.

- [ ] **Step 1: Write failing tests** (against local Supabase, fake AeroApi):
  - `lookup by ident upserts once`: calling twice for `AF84` leaves one `flights` row.
  - `lookup accepts IATA airports`: `{origin:"CDG", destination:"SFO"}` calls `searchRoute("LFPG","KSFO", ...)`.
  - `31st lookup in an hour returns 429 rate_limited`.
  - `no JWT returns 401 unauthorized`.
  - `follow creates alert once`: two users follow the same flight, `createAlert` called once, `flights.alert_id` set.
  - `4th follow on free plan returns 403 plan_limit`; same on `pro` returns 200.
  - `unfollow by last follower deletes alert` (`deleteAlert` called, `alert_id` null).
- [ ] **Step 2:** `deno test -A supabase/functions/flight-lookup supabase/functions/follow-flight`. Expected: FAIL.
- [ ] **Step 3:** Implement. Alert window: scheduled departure minus 1 day to scheduled arrival plus 1 day.
- [ ] **Step 4:** Run tests. Expected: PASS.
- [ ] **Step 5:** Commit `feat(functions): flight lookup and follow`.

### Task 5: aeroapi-webhook

**Files:**
- Create: `supabase/functions/aeroapi-webhook/index.ts`, `supabase/functions/_shared/fixtures/alert_gate_change.json`, `alert_departure.json`
- Test: `supabase/functions/aeroapi-webhook/index_test.ts`

**Interfaces:**
- Consumes: `toFlightRow`, `serviceClient`.
- Produces: `POST /aeroapi-webhook?secret=<WEBHOOK_SECRET>`. Stores raw body in `webhook_inbox`, then `provider_event_id = hex(sha256(raw body))`; maps `event_code` (`change`, `departure`, `arrival`, `cancelled`, `diverted`, `minutes_out`, `filed`) to `flight_event_kind`; updates the `flights` row; inserts `flight_events` with `on conflict (provider_event_id) do nothing`; when a row was inserted, calls `push-sender` with `{ flightId, eventId }`. Sets `webhook_inbox.processed_at` or `error`.

- [ ] **Step 1: Write failing tests:**
  - `wrong secret returns 401` and writes nothing.
  - `gate change updates flights.gate_origin and inserts one event`.
  - `same body twice yields one event and one push call` (Review Focus 1).
  - `malformed body keeps inbox row with error and returns 200` (so the provider does not retry forever).
- [ ] **Step 2:** Run. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run. Expected: PASS.
- [ ] **Step 5:** Commit `feat(functions): AeroAPI webhook with idempotent events`.

### Task 6: push-sender

**Files:**
- Create: `supabase/functions/_shared/apns.ts`, `supabase/functions/push-sender/index.ts`
- Test: `supabase/functions/_shared/apns_test.ts`, `supabase/functions/push-sender/index_test.ts`

**Interfaces:**
- Produces:
  - `apnsJwt(teamId: string, keyId: string, p8: string, now: number): Promise<string>` (ES256, cached 50 minutes)
  - `sendApns(token: string, payload: object, opts: { pushType: "alert" | "liveactivity", topic: string, sandbox: boolean }, fetchFn?): Promise<{ ok: boolean, status: number, reason?: string }>`
  - `alertCopy(kind: FlightEventKind, flight: FlightRow): { title: string, body: string } | null` (null for `position`; `delay` only when the new delay is 15 minutes or more)
  - `POST /push-sender` (service role only) `{ flightId, eventId }`: alert push to `push_tokens` of kind `alert` whose user follows with `notify = true`; Live Activity push (`event: "update"`, `content-state` = `{ status, gateOrigin, gateDestination, estimatedOut, estimatedIn, progress }`; `event: "end"` on `arrived` or `canceled`) to `live_activity` tokens for that flight. Topic for Live Activity: `<bundle id>.push-type.liveactivity`. Tokens answered with 410 or `BadDeviceToken` are deleted.
- Secrets: `APNS_TEAM_ID`, `APNS_KEY_ID`, `APNS_P8`, `APNS_BUNDLE_ID`, `APNS_SANDBOX`.

- [ ] **Step 1: Write failing tests:**
  - `apnsJwt has ES256 header with kid and iss` (decode with jose).
  - `alertCopy gate_change` gives title `AF84 gate change` and body containing the new gate; `delay 10 min` returns null; `position` returns null.
  - `push-sender skips users with notify false`.
  - `410 response deletes the token`.
  - `arrival sends liveactivity end`.
- [ ] **Step 2:** Run. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run. Expected: PASS.
- [ ] **Step 5:** Commit `feat(functions): APNs alerts and Live Activity updates`.

### Task 7: airport-board, delay stats, weather

**Files:**
- Create: `supabase/functions/_shared/delay_stats.ts`, `supabase/functions/_shared/weather.ts`, `supabase/functions/airport-board/index.ts`, `supabase/functions/_shared/fixtures/metar_kaus.json`, `taf_kaus.json`
- Test: `supabase/functions/_shared/delay_stats_test.ts`, `weather_test.ts`, `supabase/functions/airport-board/index_test.ts`

**Interfaces:**
- Produces:
  - `computeStats(rows: FlightRow[], kind: "departures" | "arrivals", now: Date): DelayStats` where `DelayStats = { total: number, onTime: number, delayed15: number, canceled: number, avgDelayMinutes: number, perHour: { hour: string, onTime: number, late15: number, late45: number, canceled: number, diverted: number }[], worstRoutes: { icao: string, delayed: number, canceled: number }[], worstAirlines: { operator: string, delayed: number, canceled: number }[], severity: "normal" | "moderate" | "major" }`. Delay = actual (or estimated) out minus scheduled out for departures, in minus scheduled in for arrivals. `onTime` = delay under 15 minutes. `severity`: `major` when avg delay is 45 minutes or more or cancellations are 10% or more; `moderate` when avg delay is 15 minutes or more; else `normal`.
  - `flightCategory(ceilingFt: number | null, visibilitySm: number): "VFR" | "MVFR" | "IFR" | "LIFR"` (FAA thresholds: LIFR ceiling under 500 or vis under 1; IFR under 1000 or under 3; MVFR 1000 to 3000 or 3 to 5; else VFR).
  - `fetchWeather(icao: string, fetchFn?): Promise<Weather>` from `https://aviationweather.gov/api/data/metar?ids=<icao>&format=json` and `/taf?ids=<icao>&format=json`.
  - `GET /airport-board?airport=<IATA or ICAO>&kind=departures|arrivals|stats|weather` returns `{ icao, kind, fetchedAt, stale: boolean, payload }`. Serves `airport_snapshots` when younger than TTL (5 min boards and stats, 15 min weather); otherwise refreshes, stores, and returns. `stats` is computed from the departures and arrivals snapshots. Updates `last_viewed_at`.

- [ ] **Step 1: Write failing tests:**
  - `computeStats` on a hand-built list of 10 departures (5 on time, 3 late 20 min, 1 late 50 min, 1 canceled): `onTime 5`, `delayed15 4`, `canceled 1`, `severity "moderate"`, `perHour` buckets sum to 10.
  - `computeStats` handles an empty list: totals 0, `severity "normal"`, no NaN.
  - `flightCategory(null, 10) === "VFR"`, `(800, 10) === "IFR"`, `(2500, 10) === "MVFR"`, `(300, 0.5) === "LIFR"`.
  - `fetchWeather parses fixture` (wind, gusts, ceiling, visibility, raw METAR text, TAF periods).
  - `board accepts IATA` (`AUS` resolves to `KAUS`, Review Focus 3).
  - `fresh snapshot served without provider call`; `old snapshot triggers refresh`.
  - `provider 503 with old snapshot returns it with stale true and original fetchedAt` (Review Focus 4); `provider 503 with no snapshot returns 503 provider_unavailable`.
- [ ] **Step 2:** Run. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run. Expected: PASS.
- [ ] **Step 5:** Commit `feat(functions): airport boards, delay stats, weather`.

### Task 8: delete-account

**Files:**
- Create: `supabase/functions/delete-account/index.ts`
- Test: `supabase/functions/delete-account/index_test.ts`

**Interfaces:**
- Produces: `POST /delete-account` (user JWT) returns `{ ok: true }`. Order: for each followed flight, unfollow through the same code path as `DELETE /follow-flight`; delete `past_flights` and `push_tokens`; set `profiles.status = 'deleted'`; `auth.admin.deleteUser(userId)`.

- [ ] **Step 1: Write failing tests:**
  - `deletes user rows and keeps profile marked deleted`.
  - `sole follower deletion drops the alert; shared flight keeps alert` (Review Focus 2).
  - `no JWT returns 401`.
- [ ] **Step 2:** Run. Expected: FAIL.
- [ ] **Step 3:** Implement. Extract the unfollow logic from Task 4 into `_shared/follow.ts` (`unfollow(userId, flightId, deps)`) and use it in both functions.
- [ ] **Step 4:** Run. Expected: PASS.
- [ ] **Step 5:** Commit `feat(functions): account deletion`.

### Task 9: Archiving, cleanup, board refresh, spend alert

**Files:**
- Create: `supabase/migrations/20261028000003_jobs.sql`, `supabase/tests/archive_test.sql`, `supabase/functions/refresh-boards/index.ts`, `supabase/functions/usage-alert/index.ts`

**Interfaces:**
- Produces:
  - SQL `archive_landed_flights() returns int`: for flights with status `arrived`, `landed`, `canceled`, or `diverted` and `actual_in` (or `estimated_in` for canceled) older than 24 hours, insert one `past_flights` row per follower (distance from `airports` coordinates by haversine in km, rounded; destination is the actual arrival airport; block minutes = actual_in minus actual_out; delay minutes = actual_in minus scheduled_in, floor 0), delete the `user_flights` rows, and return the count. Rows need a `status` column on `past_flights` (`completed`, `canceled`, `diverted`); add it in this migration.
  - pg_cron schedules: `refresh-boards` every 5 minutes (pg_net POST to the function, which refreshes departures and arrivals for snapshots with `last_viewed_at` in the last hour); `archive_landed_flights()` hourly, followed by a pg_net call to a cleanup step in `refresh-boards?mode=alerts` that deletes AeroAPI alerts for flights with no followers; `usage-alert` daily at 08:00 UTC.
  - `usage-alert` sums yesterday's `usage_counters.estimated_cost`; when above `USAGE_ALERT_USD`, emails `OWNER_EMAIL` through Resend.
  - Function URL and service key for pg_net read from Vault (`vault.decrypted_secrets`), never hard-coded.

- [ ] **Step 1: Write failing pgTAP test** `archive_test.sql`:
  - landed flight CDG to SFO arrived 25 hours ago with two followers: function returns 2, two `past_flights` rows, `distance_km` between 8900 and 9000, `user_flights` empty for that flight.
  - flight arrived 2 hours ago: not archived.
  - diverted flight (planned KSFO, actual KOAK): row destination `KOAK`, status `diverted` (Review Focus 5).
  - flight departing 23:30 and arriving 01:10 next day: `block_minutes = 100`.
  - canceled flight: archived with status `canceled`, `block_minutes` null.
- [ ] **Step 2:** `supabase test db`. Expected: FAIL.
- [ ] **Step 3:** Implement migration and the two functions.
- [ ] **Step 4:** `supabase db reset && supabase test db`. Expected: PASS. `select jobname from cron.job` lists the three jobs.
- [ ] **Step 5:** Commit `feat(db): archiving, cleanup, refresh and spend jobs`.

### Task 10: Deploy and live end to end

**Files:**
- Create: `docs/backend-runbook.md` (project ref, secrets list, webhook URL registration, how to replay `webhook_inbox`)

- [ ] **Step 1:** Ask the owner to create the Supabase project `soma-flight` (or approve creating it through the Supabase MCP) and to provide APNs key and AeroAPI key as secrets. Do not create paid resources without that yes.
- [ ] **Step 2:** `supabase link`, `supabase db push`, `supabase functions deploy`, `supabase secrets set ...`. Register the webhook endpoint with AeroAPI (`PUT /alerts/endpoint`).
- [ ] **Step 3:** With a test account: look up a flight departing within 3 hours, follow it, and confirm a `flight_events` row and an APNs response 200 (sandbox token from a dev build, or a logged dry run until the app exists).
- [ ] **Step 4:** Open `airport-board?airport=SFO&kind=stats` twice within 5 minutes; confirm one provider call in `usage_counters`.
- [ ] **Step 5:** Write the runbook and commit `docs: backend runbook`.
