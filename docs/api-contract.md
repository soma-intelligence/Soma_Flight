# Backend API contract

Base URL: `<project>/functions/v1/<name>`. Every endpoint except `aeroapi-webhook`, `push-sender`, `maintenance` and `usage-alert` needs
`Authorization: Bearer <user JWT>`. Errors are `{ "error": { "code", "message" } }` with codes
`unauthorized` (401), `invalid_request` (400/405), `not_found` (404), `rate_limited` (429),
`plan_limit` (403), `out_of_window` (400, a `flight-lookup` date outside 10 days back and 2 ahead),
`provider_unavailable` (503 or 500 for internal errors, also when the daily AeroAPI budget is spent).
The app maps each code to an `APIError` case (`APIError(code:)`); an unknown code becomes
`providerUnavailable`.

Decoding: `FlightJSON.decoder` (snake_case keys converted, ISO 8601 dates with or without milliseconds).
Keys that are already camelCase (stats, weather) pass through unchanged. The backend always writes
dates as `YYYY-MM-DDTHH:mm:ss.sssZ`. Exceptions are the `hour` of an `HourBucket`, which is integer epoch
seconds (the Rust core emits it that way and `HourBucket` decodes `Int64`).

## Tables the app reads and writes

Clients reach these through PostgREST with the user JWT. Row level security scopes every table to its
owner (`auth.uid() = user_id`); `flights`, `flight_events`, `airports` and `aircraft` are read-only
shared data.

### user_flights (follows)

Written by `follow-flight` and `delete-account` (service role). Clients get `select` on their own rows
and exactly one write: a PostgREST `update` of the five user fields, through a column-level grant
`update (seat_class, seat, reason, booking_code, notes, seat_position)` and the owner policy `user_flights_owner`.
Updating any other column (`user_id`, `flight_id`, `notify`, `created_at`), inserting a row or deleting
one is refused with 42501; updating a row of another user touches 0 rows.

| Column | Type | Rule |
| --- | --- | --- |
| `seat_class` | enum | `economy`, `premium_economy`, `business`, `first`, `private`, or null |
| `seat` | text | `^[0-9]{1,3}[A-K]$` (for example `12A`), or null |
| `reason` | enum | `personal`, `business`, `crew`, or null |
| `seat_position` | enum | `aisle`, `middle`, `window`, `pilot`, `captain`, `jumpseat`, or null; wins over the position read from `seat` |
| `booking_code` | text | `^[A-Z0-9]{5,8}$`, or null |
| `notes` | text | at most 2000 characters, or null |

A violated rule is a 23514 (check violation). Send `null` to clear a field.

### past_flights (history)

Written by the nightly archive job and by the app (manual entries). Clients have full DML
(`select`, `insert`, `update`, `delete`) on their own rows through the owner policy, so every column
below is client-writable, `origin_country`, `destination_country` and `air_minutes` included. The same
rules as `user_flights` apply to `seat`, `booking_code` and `notes` (23514 when violated; the constraint
on `seat` is not validated against rows stored before v1.1). The database does not normalize: the app
trims and upper-cases `seat` and `booking_code` before sending.

When a followed flight is archived, the row copies the follower's five user fields (null when never
set) and adds:

| Column | Type | Meaning |
| --- | --- | --- |
| `seat_class`, `reason`, `seat_position`, `booking_code`, `notes` | as in `user_flights` | copied from the follow |
| `origin_country`, `destination_country` | text | ISO 3166-1 alpha-2 from `airports.country`; null when the airport is unknown |
| `air_minutes` | int | `actual_on - actual_off` in minutes when both exist and on is after off, else null |

### aircraft

Reference data, `select` for signed-in users, written by the service role only; empty until filled.
Columns: `registration` (primary key), `aircraft_type`, `airline_icao`, `delivered_on` (date), `name`.

### flights

Four new nullable times, same format as the others (`YYYY-MM-DDTHH:mm:ss.sssZ`): `scheduled_off`,
`scheduled_on`, `estimated_off`, `estimated_on` (runway departure and arrival). `flight-lookup` and
`airport-board` return them; the webhook does not update them yet, so after a webhook the stored values
can lag until the next lookup. Merge rules: `scheduled_off` and `scheduled_on` take the new value when
given; `estimated_off` and `estimated_on` are frozen once the matching `actual_off` or `actual_on` exists
(a later estimate is ignored).

`inbound_provider_id` (text, nullable): the provider id of the leg that brings this flight's aircraft,
kept from the webhook deliveries (`inbound_fa_flight_id`). The app does not read it; push-sender uses it
for the inbound late alert, and only when that leg is in `flights` too.

### notification_preferences

One row per user, the alert categories they want. Clients have `select`, `insert` and `delete` on
their own row and `update` of the category columns and `updated_at` (owner policy
`notification_preferences_owner`, 42501 for another user's row on insert, 0 rows touched on update).
No row means every category is on, so the app writes the row the first time something changes
(an upsert on `user_id`).

| Column | Type | Covers |
| --- | --- | --- |
| `delays` | bool, default true | `departure_delay`, `arrival_delay`, `schedule_change`, `inbound_late` |
| `gates` | bool, default true | `gate_assigned`, `gate_change`, `terminal_change` |
| `takeoff_landing` | bool, default true | `departed`, `takeoff`, `landing`, `arrived` |
| `baggage` | bool, default true | `baggage_belt` |
| `cancellations` | bool, default true | `cancel`, `reinstated`, `diversion` |
| `reminders` | bool, default true | the app's local reminders (check-in, morning of the flight, leave for the airport); the server never reads it |
| `updated_at` | timestamptz | set by the app on each save |

`user_flights.notify = false` still silences every alert of that flight.

## Endpoints

| Endpoint | Method | Body or query | Answer |
| --- | --- | --- | --- |
| `flight-lookup` | POST | `{ ident }` or `{ origin, destination }`, plus `date` | `{ flights: [Flight] }` (below) |
| `flight-position` | POST | `{ flightId }` | `{ flight: Flight }` (below) |
| `follow-flight` | POST, DELETE | `{ flightId, notify? }` (DELETE: `{ flightId }`) | `{ ok: true }` |
| `register-push-token` | POST | `{ token, kind, flightId?, platform }` | `{ ok: true }` |
| `airport-board` | GET | `airport`, `kind` (below) | see below |
| `brand-asset` | GET | `airline`, `kind`, `type?` (below) | `{ version, format, width, url, smallUrl, expiresAt }` |
| `aeroapi-webhook` | POST | FlightAware delivery, `?secret=` | server to server |
| `push-sender` | POST | `{ flightId, eventId }` | service role only |
| `maintenance` | POST | `?mode=alerts` or `?mode=prune` | service role only (pg_cron) |
| `brand-assets-sync` | POST | `?mode=logos&limit=50 or ?mode=side_views&limit=100[&icao=UAL,AFR]` (side views: default limit 100; also answers `unknownAirlines`, `mirrored`) | service role only (pg_cron); `{ ok, mode, checked, changed, added, failed, unchanged, missed, skipped, rejected, dropped, deferred, requests, ms, stoppedBy }`, 502 with `ok: false` when the provider is down, or `{ ok, mode, skipped }` with no provider |
| `usage-alert` | POST | none, or `?mode=cap` | service role only (pg_cron) |

The rows above the line are summaries; the sources are the header comments in each `handler.ts`.

## flight-lookup dates

`date` is `YYYY-MM-DD`, a local date at the origin airport, within 10 days back and 2 days ahead of
today (else `out_of_window`). The app sends the day the user picked on its own calendar.

- Ident search: every flight with that ident whose origin-local departure date is `date - 1`, `date`
  or `date + 1`, sorted by `scheduled_out`. A user in Paris on 30 Oct who looks up a flight that left
  New York on its 29 Oct and is still in the air finds it. The app shows all of them and picks none.
- Route search: the flights whose origin-local departure date is `date` only.

Flights whose origin or destination has no ICAO code are left out. A flight already stored is merged
with the rules of the webhook (`merge_flight`): actual times are set once, estimates are ignored once
the actual exists, and the status only rises (canceled, diverted and arrived never change), so a
lookup never moves a followed flight backwards.

## flight-position

`POST { flightId }` answers `{ flight }`, the `flights` row. When the caller follows the flight and it
is departed or en route, the first call in each 2 minute window per flight (shared by every follower)
fetches the live position from the provider and stores it in `position_*` (the answer and Realtime
carry it). Other calls answer the stored row. Provider trouble answers the stored row too. The app
calls it while a flight's detail is open and draws the plane when `position_lat`, `position_lon` and
`position_at` are present.

## Flight event payload

`flight_events.payload` (read by the app as `FlightEvent.payload`, flattened to strings). The source of
truth is `process_alert` (`supabase/migrations/20261030000012_alerts.sql`); an example of each kind
lives in `supabase/functions/aeroapi-webhook/contract/events.json`, written by the webhook tests and
decoded by the Swift tests.

| Key | On | Value |
| --- | --- | --- |
| `gate` | any event of a delivery that changed it | new departure gate |
| `minutes` | `delay` | delay in minutes against schedule (worst of departure and arrival) |
| `destination` | `diversion`, or a delivery that changed it | destination ICAO after the delivery |
| `event_code`, `alert_id`, `short_description`, `summary` | all | the provider's alert fields |
| `changes` | all | `{ field: { from, to } }` of every changed column (nested, the app does not read it) |
| `delay_minutes`, `previous_delay_minutes` | `delay` | as `minutes`, and the last delay notified |

The keys the app reads are single words: `FlightJSON.decoder` converts snake_case dictionary keys
too (`delay_minutes` arrives as `delayMinutes`), so a single word is the only spelling both sides
agree on without a conversion rule.

Event kinds: `gate_change`, `delay`, `departure`, `arrival`, `cancel`, `diversion`, `position`, and
`update` (since 20261030000012). An `update` is a delivery that is none of the others but changed what
an alert is made from: the status, an actual or scheduled time, an estimate by 5 minutes or more, or a
diverted flight's destination (diversion and change bodies only). Canceled and diverted flights get one
only when the status or that destination changes. The app shows no timeline row for it
(`FlightEventKind.update`); an unknown kind decodes as `update` too, so a newer backend never breaks
the list. A `filed` delivery with `cancelled: false` lifts a cancel (status rebuilt from the actual
times, `scheduled` when there are none) and makes an `update` whose `changes.status` goes from
`canceled`.

## Push alerts

push-sender turns each event into alerts (`supabase/functions/_shared/alerts.ts`), claims each one in
`alert_log` (unique per flight and key, service role only) and sends it to the followers with
`notify` on and the alert's category on. All the words live in `_shared/alert_copy.ts`. Values come
from the event's `changes`, so nothing calls the provider. An alert push carries `flightId`, `eventId`
and `kind` beside `aps`, `thread-id` is the flight id and `apns-collapse-id` is
`<eventId>:<kind>[:d|:a]`.

| Kind | Category | When | Example |
| --- | --- | --- | --- |
| `departure_delay` | delays | before the gate out, the departure estimate is 15 min late with none sent, or 15 min off the last one sent, or back within 5 min after a late one | "AF 84 is now 25m late", "AF 84 is back on time" |
| `arrival_delay` | delays | after the gate out, the same rule on the arrival estimate, measured from the last delay sent on either side | "AF 84 now arrives 1h 20m late" |
| `schedule_change` | delays | `scheduled_out` or `scheduled_in` moved (not a first value) | "AF 84 schedule changed" |
| `inbound_late` | delays | the inbound leg (`inbound_provider_id`, when its row is in `flights`) arrives less than 30 min before this flight's scheduled departure, and the departure estimate does not already cover it; once per flight; checked on this flight's events and on the inbound leg's | "AF 84 inbound plane is late" |
| `gate_assigned` | gates | first departure or arrival gate; once per side | "Gate K36 assigned" |
| `gate_change` | gates | a gate moved (departure side only until the gate out) | "Gate changed to G91" |
| `terminal_change` | gates | a terminal moved (not a first value) | "Terminal changed to 2F" |
| `baggage_belt` | baggage | first belt, or a move | "Bags on belt 4" |
| `departed` | takeoff_landing | `actual_out` set; once | "AF 84 left the gate" |
| `takeoff` | takeoff_landing | `actual_off` set, or a `departure` event without changes; once | "AF 84 took off" |
| `landing` | takeoff_landing | `actual_on` set, or an `arrival` event without changes; once | "AF 84 landed" |
| `arrived` | takeoff_landing | `actual_in` set; once | "AF 84 arrived at the gate" |
| `cancel` | cancellations | status became `canceled` (nothing else is sent for that event) | "AF 84 canceled" |
| `reinstated` | cancellations | status left `canceled` | "AF 84 is back on the schedule" |
| `diversion` | cancellations | status became `diverted`, or a diverted flight's destination moved | "AF 84 diverted to KOAK" |

Dedupe: once-only alerts use a fixed key (`takeoff`, `gate_assigned:departure`, `inbound_late`...),
the others `<kind>[:<side>]:<delivery>` where the delivery is the event's `provider_event_id` without
`:delay`, so a retried call or the two events of one delivery send nothing twice. The claim comes before
the send: a crash in between loses that alert rather than doubling it. Two deliveries processed at the
same moment can each see the same last delay and both send one (the webhook calls push-sender one event
after another, so this needs two deliveries for one flight in the same second).

Live Activity priority: 10 for `gate_change`, `departure`, `arrival`, `cancel` and `diversion` events
(unchanged), and for an `update` event that carries a gate, terminal, gate out, take-off, landing, gate
in, cancel, reinstated or diversion alert; 5 otherwise.

## brand-asset

`GET /brand-asset?airline=<ICAO>&kind=logo|logo_dark|wordmark|tail|side_view[&type=<ICAO type>]`

- Answer: `{ version, format, width, url, smallUrl, expiresAt }`. `format` is `png` or `webp`: SVG is never stored or served, vectors are rasterised at sync (stored image 384 px on the long side, `smallUrl` the 192 px one, null for provider rasters). `width` is the pixel width of `url`. `url` (and `smallUrl`) is a signed path into our private `brand-assets` bucket, relative to the project (`/storage/v1/object/sign/brand-assets/...?token=...`), valid 3600 s (`expiresAt`). The app joins it to the project URL it was configured with and downloads from that host only: the function's own `SUPABASE_URL` is an internal host on the local stack (`kong:8000`) and may differ from a custom API domain. The provider licence key never reaches the app.
- Kinds: `logo` (the airline's symbol when it has one, else its wordmark file, with the wordmark's version), `logo_dark`, `wordmark` (the full name mark, never a symbol), `tail`, `side_view`.
- `version`: the row's version for logos (the source file's content version, so `logo` and `wordmark` share it exactly when they are the same file); for `side_view`, the content version in the object name (with `m` when the sync mirrored it), so a re-upload for a nose change is a new version.
- `type` is required for `side_view` (the aircraft ICAO type, e.g. `B38M`) and refused for every other kind (400 `invalid_request`).
- Unknown airline, no stored asset, or an object gone from the bucket: 404 `not_found`. The app falls back to its own mark.
- Object paths carry the version (`logos/<ICAO>/<kind>-<version>.<ext>`, `side-views/<ICAO>/<TYPE>-<version>.<ext>`), so a change is a new URL and a cache never mixes versions.
- Limit: 600 calls per user per hour (429 `rate_limited`).

## airport-board

`GET /airport-board?airport=<IATA or ICAO>&kind=departures|arrivals|stats|weather`

- `airport`: 3 characters are an IATA code, 4 an ICAO code (FAA local ids of 3 characters are not accepted). Unknown code: 400.
- `kind`: `departures`, `arrivals`, `stats` or `weather`.
- Limit: 120 calls per user per hour (429 `rate_limited`).
- Every answer: `icao`, `kind`, `fetched_at`, `stale`, plus a body that depends on the kind.
- Freshness: boards and stats 5 minutes, weather 15 minutes. An older snapshot is refreshed on read (no cron).
  One request per airport and kind refreshes; concurrent ones get the old snapshot with `stale: true`.
  When the provider fails, the old snapshot is returned with `stale: true` and its original `fetched_at`.
  With no snapshot at all the answer is 503 `provider_unavailable`.
- `stats` serves both directions in one call, matching `AirportService.stats(_:)`; there is no direction
  parameter and no top-level severity (each `DelayStats` has its own).

| kind | body | Swift |
| --- | --- | --- |
| `departures`, `arrivals` | `flights: [Flight]` | `AirportBoard` |
| `stats` | `departures: DelayStats`, `arrivals: DelayStats` | `AirportService.stats` tuple |
| `weather` | `weather: Weather` | `AirportService.weather` tuple |

Rules the app can rely on:

- **Board `Flight.id`** is a UUID v5 of `provider_id` (the AeroAPI `fa_flight_id`) under the namespace
  `7b3e1c4a-5d2f-4e8b-9a61-0c3f5d7e9b21`. It is stable across refreshes. It is not `flights.id`: boards are
  not stored in `flights`. Use `provider_id` to link to a followed flight. The app does this in
  `SupabaseFlightService.resolve(_:)`: the `flights` table by `provider_id` first, else one `flight-lookup`
  of the row's ident (counts against the lookup limit; the mapping is kept in memory only).
- Board rows have no position. `origin_icao` and `destination_icao` are never null: the viewed airport fills
  its own side when the provider omits it, and a row with an unknown other side is dropped.
- **Stats** count only flights scheduled at or before the moment the stats were computed. Flights that have not left
  are left out of every figure, including `total`, `onTime` and the cancellation ratio, and out of `perHour`
  (`HourBucket` has no field for them). Rows with no scheduled time or no other airport are left out too.
  `severity` is `major` at 45 minutes average delay or 10% canceled, `moderate` at 15 minutes.
  `stats.fetched_at` is the older board's time.
- **Weather** is the newest METAR (or SPECI) and TAF. `windDirDeg` is null for variable (`VRB`) or calm wind
  (calm also has `windKt: 0`). `ceilingFt` is the lowest broken, overcast or vertical visibility layer, null
  when there is none. `visibilitySm` reads `10+` as 10. `category` comes from the Rust core (FAA thresholds),
  or from the feed when visibility is missing. Forecast periods without a time range or a category are left
  out. An airport with no usable METAR is 404 `not_found`; a failed METAR request is never cached (the old
  snapshot is served stale, or 503).

The example files below are generated from the handler by `airport-board/index_test.ts`
(`UPDATE_CONTRACT=1 deno test -A supabase/functions/airport-board` rewrites them) and live in
`supabase/functions/airport-board/contract/`. Swift decodes the same files.

### kind=departures

`contract/departures.json`

```json
{
  "icao": "KAUS",
  "kind": "departures",
  "fetched_at": "2026-11-03T16:00:00.000Z",
  "stale": false,
  "flights": [
    {
      "provider_id": "UAL1630-1793500000-schedule-0001p",
      "ident": "UA1630",
      "operator": "UA",
      "origin_icao": "KAUS",
      "origin_iata": "AUS",
      "destination_icao": "KLAX",
      "destination_iata": "LAX",
      "scheduled_out": "2026-11-03T14:40:00.000Z",
      "scheduled_in": "2026-11-03T17:45:00.000Z",
      "estimated_out": "2026-11-03T14:44:00.000Z",
      "estimated_in": "2026-11-03T17:50:00.000Z",
      "actual_out": "2026-11-03T14:44:00.000Z",
      "actual_off": "2026-11-03T14:58:00.000Z",
      "actual_on": null,
      "actual_in": null,
      "gate_origin": "7",
      "gate_destination": null,
      "terminal_origin": "Main",
      "terminal_destination": null,
      "baggage_belt": null,
      "aircraft_type": "B739",
      "registration": "N27263",
      "status": "en_route",
      "updated_at": "2026-11-03T16:00:00.000Z",
      "id": "9f849cb8-b065-5a02-9d37-3a28db71e0de"
    },
    {
      "provider_id": "DAL1744-1793500000-schedule-0005p",
      "ident": "DL1744",
      "operator": "DL",
      "origin_icao": "KAUS",
      "origin_iata": "AUS",
      "destination_icao": "KSEA",
      "destination_iata": "SEA",
      "scheduled_out": "2026-11-03T13:50:00.000Z",
      "scheduled_in": "2026-11-03T17:40:00.000Z",
      "estimated_out": null,
      "estimated_in": null,
      "actual_out": null,
      "actual_off": null,
      "actual_on": null,
      "actual_in": null,
      "gate_origin": "9",
      "gate_destination": null,
      "terminal_origin": "Main",
      "terminal_destination": null,
      "baggage_belt": null,
      "aircraft_type": "A321",
      "registration": "N817DN",
      "status": "canceled",
      "updated_at": "2026-11-03T16:00:00.000Z",
      "id": "dd9f2373-ba31-5de5-bf20-69a828460a3b"
    },
    {
      "provider_id": "AAL2417-1793500000-schedule-0004p",
      "ident": "AA2417",
      "operator": "AA",
      "origin_icao": "KAUS",
      "origin_iata": "AUS",
      "destination_icao": "KDFW",
      "destination_iata": "DFW",
      "scheduled_out": "2026-11-03T15:05:00.000Z",
      "scheduled_in": "2026-11-03T16:20:00.000Z",
      "estimated_out": "2026-11-03T15:05:00.000Z",
      "estimated_in": "2026-11-03T16:20:00.000Z",
      "actual_out": null,
      "actual_off": null,
      "actual_on": null,
      "actual_in": null,
      "gate_origin": "B6",
      "gate_destination": null,
      "terminal_origin": "Main",
      "terminal_destination": null,
      "baggage_belt": null,
      "aircraft_type": "A321",
      "registration": "N845NN",
      "status": "scheduled",
      "updated_at": "2026-11-03T16:00:00.000Z",
      "id": "04d75c9f-d994-5448-9fb1-d7ed579b59ce"
    },
    {
      "provider_id": "SWA1182-1793500000-schedule-0003p",
      "ident": "WN1182",
      "operator": "WN",
      "origin_icao": "KAUS",
      "origin_iata": "AUS",
      "destination_icao": "KDEN",
      "destination_iata": "DEN",
      "scheduled_out": "2026-11-03T15:20:00.000Z",
      "scheduled_in": "2026-11-03T17:15:00.000Z",
      "estimated_out": "2026-11-03T15:35:00.000Z",
      "estimated_in": "2026-11-03T17:30:00.000Z",
      "actual_out": null,
      "actual_off": null,
      "actual_on": null,
      "actual_in": null,
      "gate_origin": "12",
      "gate_destination": null,
      "terminal_origin": "Main",
      "terminal_destination": null,
      "baggage_belt": null,
      "aircraft_type": "B38M",
      "registration": "N8741Q",
      "status": "scheduled",
      "updated_at": "2026-11-03T16:00:00.000Z",
      "id": "b35862f4-5dbc-50c2-84ca-49e9575a61e8"
    }
  ]
}
```

### kind=arrivals

`contract/arrivals.json` has the same shape as departures, seen from the other end (`destination_icao` is the viewed airport).

```json
{
  "icao": "KAUS",
  "kind": "arrivals",
  "fetched_at": "2026-11-03T16:00:00.000Z",
  "stale": false,
  "flights": [
    {
      "provider_id": "UAL1630-1793500000-schedule-0001p",
      "ident": "UA1630",
      "operator": "UA",
      "origin_icao": "KLAX",
      "origin_iata": "LAX",
      "destination_icao": "KAUS",
      "destination_iata": "AUS",
      "scheduled_out": "2026-11-03T14:40:00.000Z",
      "scheduled_in": "2026-11-03T17:45:00.000Z",
      "estimated_out": "2026-11-03T14:44:00.000Z",
      "estimated_in": "2026-11-03T17:50:00.000Z",
      "actual_out": "2026-11-03T14:44:00.000Z",
      "actual_off": "2026-11-03T14:58:00.000Z",
      "actual_on": null,
      "actual_in": null,
      "gate_origin": "7",
      "gate_destination": null,
      "terminal_origin": "Main",
      "terminal_destination": null,
      "baggage_belt": null,
      "aircraft_type": "B739",
      "registration": "N27263",
      "status": "en_route",
      "updated_at": "2026-11-03T16:00:00.000Z",
      "id": "9f849cb8-b065-5a02-9d37-3a28db71e0de"
    },
    {
      "provider_id": "DAL1744-1793500000-schedule-0005p",
      "ident": "DL1744",
      "operator": "DL",
      "origin_icao": "KSEA",
      "origin_iata": "SEA",
      "destination_icao": "KAUS",
      "destination_iata": "AUS",
      "scheduled_out": "2026-11-03T13:50:00.000Z",
      "scheduled_in": "2026-11-03T17:40:00.000Z",
      "estimated_out": null,
      "estimated_in": null,
      "actual_out": null,
      "actual_off": null,
      "actual_on": null,
      "actual_in": null,
      "gate_origin": "9",
      "gate_destination": null,
      "terminal_origin": "Main",
      "terminal_destination": null,
      "baggage_belt": null,
      "aircraft_type": "A321",
      "registration": "N817DN",
      "status": "canceled",
      "updated_at": "2026-11-03T16:00:00.000Z",
      "id": "dd9f2373-ba31-5de5-bf20-69a828460a3b"
    },
    {
      "provider_id": "AAL2417-1793500000-schedule-0004p",
      "ident": "AA2417",
      "operator": "AA",
      "origin_icao": "KDFW",
      "origin_iata": "DFW",
      "destination_icao": "KAUS",
      "destination_iata": "AUS",
      "scheduled_out": "2026-11-03T15:05:00.000Z",
      "scheduled_in": "2026-11-03T16:20:00.000Z",
      "estimated_out": "2026-11-03T15:05:00.000Z",
      "estimated_in": "2026-11-03T16:20:00.000Z",
      "actual_out": null,
      "actual_off": null,
      "actual_on": null,
      "actual_in": null,
      "gate_origin": "B6",
      "gate_destination": null,
      "terminal_origin": "Main",
      "terminal_destination": null,
      "baggage_belt": null,
      "aircraft_type": "A321",
      "registration": "N845NN",
      "status": "scheduled",
      "updated_at": "2026-11-03T16:00:00.000Z",
      "id": "04d75c9f-d994-5448-9fb1-d7ed579b59ce"
    },
    {
      "provider_id": "SWA1182-1793500000-schedule-0003p",
      "ident": "WN1182",
      "operator": "WN",
      "origin_icao": "KDEN",
      "origin_iata": "DEN",
      "destination_icao": "KAUS",
      "destination_iata": "AUS",
      "scheduled_out": "2026-11-03T15:20:00.000Z",
      "scheduled_in": "2026-11-03T17:15:00.000Z",
      "estimated_out": "2026-11-03T15:35:00.000Z",
      "estimated_in": "2026-11-03T17:30:00.000Z",
      "actual_out": null,
      "actual_off": null,
      "actual_on": null,
      "actual_in": null,
      "gate_origin": "12",
      "gate_destination": null,
      "terminal_origin": "Main",
      "terminal_destination": null,
      "baggage_belt": null,
      "aircraft_type": "B38M",
      "registration": "N8741Q",
      "status": "scheduled",
      "updated_at": "2026-11-03T16:00:00.000Z",
      "id": "b35862f4-5dbc-50c2-84ca-49e9575a61e8"
    }
  ]
}
```

### kind=stats

`contract/stats.json`

```json
{
  "icao": "KAUS",
  "kind": "stats",
  "fetched_at": "2026-11-03T16:00:00.000Z",
  "stale": false,
  "departures": {
    "total": 4,
    "onTime": 2,
    "delayed15": 1,
    "canceled": 1,
    "avgDelayMinutes": 6.333333333333333,
    "perHour": [
      {
        "hour": 1793710800,
        "onTime": 0,
        "late15": 0,
        "late45": 0,
        "canceled": 1,
        "diverted": 0
      },
      {
        "hour": 1793714400,
        "onTime": 1,
        "late15": 0,
        "late45": 0,
        "canceled": 0,
        "diverted": 0
      },
      {
        "hour": 1793718000,
        "onTime": 1,
        "late15": 1,
        "late45": 0,
        "canceled": 0,
        "diverted": 0
      }
    ],
    "worstRoutes": [
      {
        "icao": "KDEN",
        "delayed": 1,
        "canceled": 0
      },
      {
        "icao": "KSEA",
        "delayed": 0,
        "canceled": 1
      }
    ],
    "worstAirlines": [
      {
        "operator": "DL",
        "delayed": 0,
        "canceled": 1
      },
      {
        "operator": "WN",
        "delayed": 1,
        "canceled": 0
      }
    ],
    "severity": "major"
  },
  "arrivals": {
    "total": 0,
    "onTime": 0,
    "delayed15": 0,
    "canceled": 0,
    "avgDelayMinutes": 0,
    "perHour": [],
    "worstRoutes": [],
    "worstAirlines": [],
    "severity": "normal"
  }
}
```

### kind=weather

`contract/weather.json`

```json
{
  "icao": "KAUS",
  "kind": "weather",
  "fetched_at": "2026-11-03T16:00:00.000Z",
  "stale": false,
  "weather": {
    "metarRaw": "SPECI KAUS 291744Z VRB03KT 10SM -RA BKN009 BKN026 BKN046 OVC130 22/20 A3015 RMK AO2 P0001 T02170200",
    "tafRaw": "TAF KAUS 291730Z 2918/3024 10003KT P6SM -RA SCT015 BKN025 OVC100 FM292100 08007KT P6SM VCSH SCT040 OVC100 FM300000 09003KT P6SM OVC040 FM301500 10006KT 6SM -RA BR OVC050 FM301900 10005KT 3SM -RA BR OVC009",
    "tempC": 21.7,
    "windDirDeg": null,
    "windKt": 3,
    "gustKt": null,
    "visibilitySm": 10,
    "ceilingFt": 900,
    "category": "IFR",
    "observedAt": "2026-10-29T17:44:00.000Z",
    "forecast": [
      {
        "from": "2026-10-29T18:00:00.000Z",
        "to": "2026-10-29T21:00:00.000Z",
        "category": "MVFR",
        "windDirDeg": 100,
        "windKt": 3,
        "gustKt": null,
        "visibilitySm": 6,
        "ceilingFt": 2500
      },
      {
        "from": "2026-10-29T21:00:00.000Z",
        "to": "2026-10-30T00:00:00.000Z",
        "category": "VFR",
        "windDirDeg": 80,
        "windKt": 7,
        "gustKt": null,
        "visibilitySm": 6,
        "ceilingFt": 10000
      },
      {
        "from": "2026-10-30T00:00:00.000Z",
        "to": "2026-10-30T15:00:00.000Z",
        "category": "VFR",
        "windDirDeg": 90,
        "windKt": 3,
        "gustKt": null,
        "visibilitySm": 6,
        "ceilingFt": 4000
      },
      {
        "from": "2026-10-30T15:00:00.000Z",
        "to": "2026-10-30T19:00:00.000Z",
        "category": "VFR",
        "windDirDeg": 100,
        "windKt": 6,
        "gustKt": null,
        "visibilitySm": 6,
        "ceilingFt": 5000
      },
      {
        "from": "2026-10-30T19:00:00.000Z",
        "to": "2026-10-31T00:00:00.000Z",
        "category": "IFR",
        "windDirDeg": 100,
        "windKt": 5,
        "gustKt": null,
        "visibilitySm": 3,
        "ceilingFt": 900
      }
    ]
  }
}
```

## App configuration and sign in

- Debug builds use `Apps/<platform>/Config.Debug.xcconfig`: the local stack (`http://127.0.0.1:58321`), its
  public demo anon key, and an Info.plist that allows local networking. Release builds use
  `Config.Release.xcconfig`, which is empty: the URL and anon key must come from a gitignored
  `Config.local.xcconfig` next to it, otherwise the app refuses to start ("no server configured"). A plain
  http URL is only accepted for this machine. Never put the service role key in any of these files.
- Sign in with Apple needs a provisioning profile. The Mac Debug build signs to run locally and leaves the
  capability out (`SomaFlight-Debug.entitlements`), so only email sign-in works there; a Mac Release or iOS
  device build needs the team and a profile with Sign in with Apple, and fails to sign without one.
- The email link returns as `somaflight://auth-callback?code=...` (PKCE). The app ignores any other form,
  including a fragment carrying tokens. The local stack lists the callback in `additional_redirect_urls`.
- Sign-out deletes this device's `push_tokens` rows (clients keep delete on their own rows) before the
  session ends.
