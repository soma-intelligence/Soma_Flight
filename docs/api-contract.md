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

### gate_history (function)

`rpc/gate_history` (POST, signed-in users only; anon gets 42501) with `p_ident` (the flight's `ident`,
"AF84"), `p_origin` (origin ICAO), `p_operator` (the flight's `operator`, "AF", or null), `p_day` (the
flight's local departure day at the origin, `YYYY-MM-DD`) and optional `p_days` (1 to 30, default 7).
Answer, one JSON object:

```json
{
  "days": [{ "day": "2026-10-29", "gate": "B22", "terminal": "2" }],
  "airline": [{ "gate": "B22", "terminal": "2", "flights": 9 }]
}
```

`days`: the departure gate the flight number used on each of the `p_days` days before `p_day`, newest
first (the last gate seen that day). `airline`: the operator's departures at the origin over the 14
days before `p_day`, by gate, busiest first, at most 100; empty without an operator. Both come from
`flight_gate_days` (service role only), which a trigger on `flights` fills whenever a departure gate is
stored (webhook merge or lookup; canceled flights skipped) and a daily job prunes after 30 days. The app
turns them into "Likely gate B22, used 6 of the last 7 days" with the core's `predict_gate`.

### notification_preferences

One row per user, the alert categories they want. Clients have `select`, `insert`, `update` and
`delete` on their own row (owner policy `notification_preferences_owner`: 42501 for inserting another
user's row or moving one's own to another user, 0 rows touched when updating someone else's).
No row means every category is on, so the app writes the row the first time something changes
(an upsert on `user_id`).

| Column | Type | Covers |
| --- | --- | --- |
| `delays` | bool, default true | `departure_delay`, `arrival_delay`, `schedule_change`, `inbound_late`, `predicted_delay`, `connection_at_risk`, `airport_program` |
| `gates` | bool, default true | `gate_assigned`, `gate_change`, `terminal_change` |
| `takeoff_landing` | bool, default true | `departed`, `takeoff`, `landing`, `arrived` |
| `baggage` | bool, default true | `baggage_belt` |
| `cancellations` | bool, default true | `cancel`, `reinstated`, `diversion` |
| `reminders` | bool, default true | the app's local reminders (check-in, morning of the flight, leave for the airport); the server never reads it |
| `boarding` | bool, default true | `boarding_started`, `boarding_change` (migration 20261107000030) |
| `aircraft` | bool, default true | `aircraft_change` (migration 20261107000030) |
| `favorite_airports` | bool, default true | the favorite airport pushes below (migration 20261107000030) |
| `updated_at` | timestamptz | set by the app on each save |

`user_flights.notify = false` still silences every alert of that flight.

## Endpoints

| Endpoint | Method | Body or query | Answer |
| --- | --- | --- | --- |
| `flight-lookup` | POST | `{ ident }` or `{ origin, destination }`, plus `date` | `{ flights: [Flight] }` (below) |
| `mapkit-token` | GET | none (user JWT) | `{ token, expiresAt }` (below) |
| `flight-position` | POST | `{ flightId }` | `{ flight: Flight }` (below) |
| `follow-flight` | POST, DELETE | `{ flightId, notify? }` (DELETE: `{ flightId }`) | `{ ok: true }` |
| `register-push-token` | POST | `{ token, kind, flightId?, platform }` | `{ ok: true }` |
| `airport-board` | GET | `airport`, `kind` (below) | see below |
| `brand-asset` | GET | `airline`, `kind`, `type?` (below) | `{ version, format, width, url, smallUrl, expiresAt }` |
| `flight-insights` | GET | `mode=arrival_forecast&ident=` or `mode=inbound&flight_id=` (below) | `{ ident, fetched_at, stale, forecast }` or `{ flight_id, fetched_at, stale, legs }` |
| `alternate-flights` | GET | `origin`, `destination` (ICAO), `after` (ISO time) (below) | `{ origin, destination, after, fetched_at, stale, flights }` |
| `flight-brief` | POST | `{ kind, subject, facts }` (below) | `{ kind, subject, text, facts_used, generated_at, cached }` |
| `nearby-flights` | GET | `lat`, `lon`, `radius_km?` (below) | `{ box, fetched_at, stale, truncated, flights }`; 503 `provider_unavailable` while off |
| `flight-schedules` | POST | `{ origin?, destination?, airline?, ident?, date, time? }` (below) | `{ date, fetched_at, stale, truncated, flights }` |
| `security-wait` | GET | `airport` (IATA or ICAO) | `{ airport, iata, available, reason, live, source, fetched_at, checkpoints }` (below) |
| `share-flight` | POST, GET, DELETE | POST `{ flight_id }`; GET and DELETE `?flight_id=` | `{ url, expires_at }`, `{ active, expires_at }`, `{ revoked }` (below) |
| `flight-page` | GET | `/flight-page/<token>[/og.png]`, public (no JWT) | the share page (HTML) or its preview image (PNG) |
| `friends` | POST | `{ action, token?, code?, invitation_id?, accept? }` | per action (below) |
| `faa-status` | GET | `airport` (IATA or ICAO) | `{ airport, iata, available, reason, stale, fetched_at, programs }` (below) |
| `faa-status` | POST | `?mode=sweep` | service role only (pg_cron); `{ ok, mode, stale, programs, flights, sent, failed }` |
| `faa-notams` | GET | `airport` (IATA or ICAO) | `{ airport, iata, configured, stale, fetched_at, notams }` (below) |
| `airport-weather` | GET | `airports` (comma list, up to 40, IATA or ICAO) or `airport` | `{ fetched_at, airports: [{ icao, iata, weather, faa }] }` (below) |
| `airport-stats` | GET | `airport` (detail) or `airports` (list, up to 20) | `{ available, reason, provider, ... }` (below) |
| `airport_regulars` | RPC | `{ p_icao }` | `[{ user_id, is_me, display_name, emoji, visits, last_visit }]` (below) |
| `aeroapi-webhook` | POST | FlightAware delivery, `?secret=` | server to server |
| `push-sender` | POST | `{ flightId, eventId }`, or `{ flightId, program }` (faa-status's sweep) | service role only |
| `maintenance` | POST | `?mode=alerts`, `?mode=prune` or `?mode=poll` | service role only (pg_cron) |
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

## mapkit-token

`GET /mapkit-token` with the user JWT answers `{ "token": string, "expiresAt": string }`: an ES256 JWT for
MapKit JS (header `kid` = the MapKit key id, claims `iss` = team id, `iat`, `exp` = `iat` + 1800 s, and
`origin` when the request has an `Origin`). Used by the web globe; the apps do not call it.

- `401 unauthorized` without a valid JWT; `429 rate_limited` after 30 calls per hour per user.
- `400 invalid_request` when the `Origin` is not in `WEB_ORIGINS`, so no token is minted for another site.
- `503 provider_unavailable` while `MAPKIT_KEY_ID`, `MAPKIT_TEAM_ID` or `MAPKIT_PRIVATE_KEY` is unset.

## CORS

`flight-lookup`, `follow-flight`, `flight-position` and `mapkit-token` answer browser preflights and add
`Access-Control-Allow-Origin` for the origins in `WEB_ORIGINS` (comma list, default
`https://flight.somalabs.me,http://localhost:5173`). Requests without an `Origin` (the apps) are untouched.

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
| `predicted_delay` | delays | before the gate out and before any departure delay alert, the core's `predict_delay` gives a medium or high confidence delay from what the backend already holds (the inbound leg's row or a cached inbound chain under 30 min old, the cached arrival forecast, the origin's stats snapshot under 30 min old, weather snapshots under 2 h old); a late inbound prediction is skipped when `inbound_late` goes or went; once per flight; checked on this flight's events and on the inbound leg's | "AF 84 likely 25 min late" |
| `connection_at_risk` | delays | a user follows this flight and the flight it connects into (below), and the layover from the first flight's best arrival to the second's best departure falls under the connection airport's usual minimum (At risk) or under 15 minutes (Missed); not for a canceled or diverted first flight, a canceled onward flight or one that already left (those have their own alerts); once per pair, claimed on the arriving flight (`connection_at_risk:<onward flights.id>`), sent only to the users who follow both; checked on the events of either flight | "AF 84 connection at risk" |
| `airport_program` | delays | faa-status's sweep found a ground stop, ground delay program or closure at either airport that holds the flight (see faa-status); once per flight, airport, kind and program start | "Ground delay program at SFO", "Ground stop at EWR", "SFO airport closed" |

| `early_departure` | delays | `actual_out` set 10 min or more before `scheduled_out`; once; sent beside `departed` | "AF 84 left 15m early" |
| `taxi_long` | delays | `actual_off` set 30 min or more after `actual_out`; once | "AF 84 taxied 34m before take-off" |
| `aircraft_change` | aircraft | `aircraft_type` or `registration` moved from one value to another before the gate out (not a first value) | "AF 84 has a different aircraft type" |
| `boarding_started` | boarding | `boarding_actual` set; once. Dormant: no provider gives a boarding time and `process_alert` does not track one, so this never fires until a source and a column exist | "AF 84 is boarding" |
| `boarding_change` | boarding | `boarding_estimated` moved 10 min or more. Dormant, same reason | "AF 84 boarding time changed" |

An `airport_program` push comes from `POST { flightId, program }`, not from a flight event: its `eventId` is
null, `apns-collapse-id` is `<flightId>:airport_program`, it updates no Live Activity, and its key in
`alert_log` is `airport_program:<icao>:<kind>:<program start, to the minute>`, so a program revised by the
FAA (a new average, a later end) is not announced again, and a new one later that day is.

### Favorite airports

`favorite_airports (user_id, airport_icao)`: owner only (RLS), at most 50 per user, `select`, `insert` and
`delete` for clients. `favorite-airports?mode=sweep` (service role, pg_cron `favorite-airports-sweep` every
5 minutes at minute 2, off unless the function secret `FAVORITE_AIRPORT_ALERTS_ENABLED` is `true`) reads the
shared `faa_status_cache` (never the FAA) and, for each ground stop, ground delay program or closure at a
followed airport, asks push-sender (`POST { favorite }`) for one push per user. push-sender claims it in
`favorite_alert_log (user_id, key)` (key `favorite:airport_program:<icao>:<kind>:<start>`), skips users who
turned `favorite_airports` off, and users who follow a flight with the same program's own `airport_program`
alert. `thread-id` is `airport:<icao>`, the payload carries `airport` and `kind: favorite_airport`.
TODO: a conditions level `major` (faa-status conditions summary) should trigger the same push.

Dedupe: once-only alerts use a fixed key (`takeoff`, `gate_assigned:departure`, `inbound_late`...),
the others `<kind>[:<side>]:<delivery>` where the delivery is the event's `provider_event_id` without
`:delay`, so a retried call or the two events of one delivery send nothing twice. The claim comes before
the send: a crash in between loses that alert rather than doubling it. Two deliveries processed at the
same moment can each see the same last delay and both send one (the webhook calls push-sender one event
after another, so this needs two deliveries for one flight in the same second).

Connections (`_shared/connections.ts`, the same rules as the app's Connection card): two flights connect when
the first lands where the second leaves from and the second is scheduled to leave after the first lands, within
24 hours; a flight back to where the first came from is a return trip. Each flight arrives into one connection
and leaves from one, the shortest gaps first. The minimum connection times are typical figures for the 40
busiest airports, by kind of connection (domestic or international on each side, Schengen counted as
domestic), with defaults elsewhere, in `_shared/connection_rules.json`; FlightKit ships a copy and a test fails
when the two differ. For an event, push-sender reads the flights around this one (leaving from where it lands
within 24 hours, or landing where it leaves within 24 hours before), pairs them per user among the ones each
follows, and reads the airports' countries; nothing calls the provider.

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

## flight-insights

The flight sheet's two paid sections, Arrival Forecast and Where's My Plane. Both read AeroAPI through
`_shared/aeroapi.ts`, so every provider request is charged against the daily spend cap (`charge_usage`)
before it goes out. Answers are cached whole in `forecast_cache` (12 hours per flight number) and
`inbound_cache` (10 minutes per flight), empty answers included, so reopening a flight costs nothing.
Both tables are service role only. The app turns the calls on with `INSIGHTS_ENABLED` (below).

`GET /flight-insights?mode=arrival_forecast&ident=AF84`

```json
{
  "ident": "AF84",
  "fetched_at": "2026-11-03T10:00:00.000Z",
  "stale": false,
  "forecast": {
    "ident": "AF84",
    "days": 60,
    "observed": 13,
    "late_percent": 45,
    "average_late_minutes": 42,
    "percents": { "early": 16, "on_time": 23, "late15": 15, "late30": 15, "late45": 15, "canceled": 8, "diverted": 8 }
  }
}
```

- `ident` is a designator: an IATA (two characters) or ICAO (three letters) airline code, one to four
  figures and an optional letter (spaces dropped, any case). Anything else is 400 `invalid_request`.
- The history (`/history/flights/{ident}`) is read in 7 day windows, the provider's longest, newest
  first, until 30 finished flights are seen or 60 days are covered. `days` is the span read (7 to 60).
- Each finished flight falls in one bucket: `canceled`, `diverted`, else the gate arrival against the
  scheduled one (runway times when the gate ones are missing), rounded to the minute: `early` below 0,
  `on_time` 0 to 14, `late15` 15 to 29, `late30` 30 to 44, `late45` 45 or more. A flight not yet arrived
  is not counted. A diverted flight's two provider rows count once.
- `percents` has every bucket and adds up to exactly 100 (largest remainder). `late_percent` is
  `late15 + late30 + late45`; `average_late_minutes` is the mean delay of the flights 15 minutes late or
  more (0 when none). `observed` is the number of finished flights.
- `forecast` is null when no flight of the number finished in the span.

`GET /flight-insights?mode=inbound&flight_id=<flights.id>`

```json
{
  "flight_id": "c2000000-0000-0000-0000-000000000001",
  "fetched_at": "2026-11-03T10:00:00.000Z",
  "stale": false,
  "legs": [
    {
      "id": "AFR1145-1793689200-schedule-0001p",
      "ident": "AF1145",
      "origin_iata": "LHR",
      "destination_iata": "CDG",
      "scheduled_out": "2026-11-03T07:00:00.000Z",
      "scheduled_in": "2026-11-03T08:15:00.000Z",
      "status": "arrived",
      "delay_minutes": 12
    }
  ]
}
```

- `legs` are the flights the aircraft flies before this one, newest first. The chain starts from the
  flight's own `inbound_fa_flight_id` (`/flights/{id}`, one call) and follows each leg's, one call per
  leg, while the leg left no more than 25 hours before this flight's scheduled departure, for at most 8
  legs. The first leg found outside the 25 hours ends the walk (it is paid for and left out).
- `id` is the provider's flight id; `origin_iata` and `destination_iata` fall back to the ICAO or local
  code when a field has no IATA code. `status` is a `flights.status` value. `delay_minutes` is the
  arrival against the schedule (actual, else estimate; gate, else runway), never below 0.
- `legs` is empty when the provider names no inbound flight or does not know it.
- An unknown `flight_id` is 404 `not_found`; a malformed one is 400 `invalid_request`.

Both modes:

- `stale` is true when the provider refused a refresh (the daily cap reached, an outage, its rate limit)
  and an older cached answer is served instead. With nothing cached the answer is 503
  `provider_unavailable`; the app then hides the section.
- Limit: 120 calls per user per hour (429 `rate_limited`). Every open of a flight sheet makes two.
- The answers in `supabase/functions/flight-insights/contract/` are written by the function's tests and
  decoded by `SupabaseInsightsTests` in FlightKit.
- Cost: an inbound refresh is 1 + legs calls to `/flights/{ident}` ($0.005 each). A forecast refresh is
  one `/history/flights/{ident}` result set per window, 9 at most; its price is not on the pricing page
  checked in `docs/provider-check.md` and is counted at a cautious $0.02 until confirmed.

## flight-brief

Short language-model texts written from facts the app already shows. **Switched off** until the owner says
yes on cost: without `LLM_ENABLED=true` and the Azure OpenAI settings (`docs/operations.md`) every call
answers 503 `llm_unavailable`, and the app ships with `LLMEnabled` NO (Info.plist, `LLM_ENABLED` in the
xcconfigs) so it makes no call and shows no section.

`POST /flight-brief` with `{ "kind", "subject", "facts": [{ "id", "value" }] }`. A signed-in user is required.

| kind | subject | what it writes |
| --- | --- | --- |
| `door_to_door` | flight id (uuid) | a short guide from the leave-by inputs, terminal, gate, walk, security wait |
| `delay_cause` | flight id (uuid) | why the flight is late: late inbound plane, METAR, FAA program, gate changes |
| `airport_summary` | airport code (IATA or ICAO) | current conditions from the weather, delays, FAA program and security wait |

Answer: `{ kind, subject, text, facts_used, generated_at, cached }`. `facts_used` is the list of fact ids the
text relies on.

Facts (`supabase/functions/flight-brief/facts.ts` holds the list per kind): each has an `id` from a fixed list
and a value of a strict type (a whole number in a range, a flag, an airport or flight code, a 24 hour clock
time local to the airport, a short code, a word from a list, a METAR or advisory line in a safe alphabet).
Free text, names, booking codes, documents and the vault have no id, so they cannot be sent; an unknown id,
a repeated id, a value that does not fit, or fewer than 2 or more than 24 facts is 400 `invalid_request`.
`FlightBriefTests` checks that every id the app sends is on the backend's list for its kind.

Guardrail: the prompt holds the facts and fixed instructions only. The model must answer JSON
`{ text, facts_used }`. The answer is dropped, with 503 `llm_unavailable` and nothing cached, when it is not
that JSON, cites no fact or an id that was not sent, writes a number that is not in a cited fact, spells a
large number out, holds a link, address or markup, or is shorter than 20 or longer than 480 characters.

Other errors: 401 `unauthorized`, 429 `rate_limited` (30 calls per user per hour, cache hits included), 503
`llm_unavailable` (off, not configured, the daily spend cap reached, the provider failed, or the answer
dropped). The app hides the section on any failure and shows no banner.

Cache: `llm_brief_cache`, one row per subject, kind and SHA-256 of the facts, served for 6 hours (rows are
pruned after a day). Identical facts never pay twice. Each model call is counted in `usage_counters` as
`llm:flight-brief` through `charge_usage`, under the same daily cap as AeroAPI (`AEROAPI_DAILY_CAP_USD`).

The example answer in `supabase/functions/flight-brief/contract/door_to_door.json` is checked by the function's
tests and decoded by `FlightBriefTests` in FlightKit.

## alternate-flights

The flight sheet's "Other flights" card: direct flights on a route later the same day, any airline, offered
when a followed flight is canceled or a connection is at risk or missed. Paid (AeroAPI schedules): the app
asks only when `INSIGHTS_ENABLED` is on, like `flight-insights`.

`GET /alternate-flights?origin=KSFO&destination=KORD&after=2026-11-03T15:20:00Z`

```json
{
  "origin": "KSFO",
  "destination": "KORD",
  "after": "2026-11-03T15:00:00.000Z",
  "fetched_at": "2026-11-03T15:20:00.000Z",
  "stale": false,
  "flights": [
    {
      "id": "UAL1958-1793563200-schedule-0000",
      "ident": "UA1958",
      "operator": "UAL",
      "origin_iata": "SFO",
      "destination_iata": "ORD",
      "scheduled_out": "2026-11-03T20:00:00.000Z",
      "scheduled_in": "2026-11-04T00:15:00.000Z",
      "estimated_out": null,
      "estimated_in": null,
      "status": "scheduled",
      "aircraft_type": "B772"
    }
  ]
}
```

- `origin` and `destination` are airport codes of 3 or 4 letters or figures (any case; the app sends ICAO);
  the same code twice is 400 `invalid_request`. `after` is an ISO time, now when missing, and must be within 2
  hours before and 2 days after now (400 `out_of_window`); anything else is 400 `invalid_request`.
- The provider's schedules (`/schedules/{date_start}/{date_end}`, operating flights only, no codeshares) are read
  for the 24 hours from the start of the UTC hour of `after` (`after` in the answer is that hour), at most 3
  result sets, and cached whole per route and hour for 30 minutes in `alternates_cache` (service role only,
  pruned daily), empty answers included. `flights` are the cached ones leaving at or after `after`, by departure.
- `id` is the provider's flight id, or `<ICAO designator>-<scheduled_out>` for a flight it does not track yet.
  `ident` is the IATA designator (else the provider's), `operator` the ICAO airline code from the ICAO
  designator, the airports IATA codes (else ICAO).
- A schedule has no status: `status` is `scheduled` and the estimates are null, unless `flights` already holds
  the flight (same provider id), whose status and gate times (actual, else estimated) are laid over, free.
- `stale` and 503 `provider_unavailable` as in flight-insights: a refused refresh serves the cached answer of any
  age, with nothing cached the app shows the card empty.
- Limit: 60 calls per user per hour (429 `rate_limited`).
- The answer in `supabase/functions/alternate-flights/contract/` is written by the function's tests and decoded
  by `ConnectionTests` in FlightKit.
- Cost: one to three `/schedules` result sets per route and hour, shared by everyone; the price is not on the
  pricing page checked in `docs/provider-check.md` and is counted at a cautious $0.02 until confirmed.
- Tapping a row in the app looks the flight up by number (`flight-lookup`) and follows it.

## nearby-flights

The map's radar: planes in the air around the user (only when location is already allowed) or around a chosen
airport. Paid (AeroAPI flight search, $0.05 a result set) and OFF: the function answers 503 `provider_unavailable`
(`{ "error": { "code": "provider_unavailable", "message": ... } }`, before auth or any database read) unless its
env `RADAR_ENABLED` is `true` and `AEROAPI_KEY` is set, and the app shows no radar button unless Info.plist
`RadarEnabled` (`RADAR_ENABLED` in the xcconfigs, NO everywhere) is yes.

`GET /nearby-flights?lat=37.62&lon=-122.38&radius_km=100`

```json
{ "box": { "south": 36.5, "north": 38.75, "west": -123.75, "east": -121 }, "fetched_at": "2026-11-07T18:00:00.000Z",
  "stale": false, "truncated": false,
  "flights": [ { "id": "UAL1-1", "ident": "UA1", "operator": "UA", "type": "B789", "lat": 37.7123, "lon": -122.1,
                 "altitude": 35000, "groundspeed": 460, "heading": 1, "origin": "SFO", "destination": "LHR" } ] }
```

- `lat` -90 to 90 and `lon` -180 to 180 are required (else 400 `invalid_request`). `radius_km` is clamped to 10 to
  150 (default 100): a bigger ask is not refused, it gets the 150 km box. The box is the radius's square, snapped
  outward to a 0.25 degree grid and cut at the poles and the date line, so one call is bounded and everyone
  looking at the same area shares one read. The answer's `box` is the snapped box that was read.
- `flights` are planes with a position and a ground speed of 40 knots or more, one per provider id, sorted by
  `ident`, 80 at most. `altitude` is feet, `groundspeed` knots, `heading` degrees true (null if unknown), `origin`
  and `destination` IATA (else ICAO) codes, `ident` the IATA designator (else the provider's), `operator` the IATA
  (else ICAO) airline code. `truncated` is true when the provider had result sets beyond the two read.
- The provider read is `/flights/search` with `query=-latlong "south west north east"`, at most 2 result sets, each
  counted in `usage_counters` through `charge_usage` (so it stops at the daily spend cap) and cached whole for 60
  seconds per snapped box in `radar_cache` (service role only, pruned daily). `stale` and 503 `provider_unavailable`
  as in `alternate-flights`: a refused refresh (cap, outage, provider rate limit) serves the cached row of any age
  with `stale: true`; with nothing cached the call fails and the radar shows its unavailable note.
- Limit: 90 calls per user per hour (429 `rate_limited`): one refresh a minute plus a few area changes.
- UNVERIFIED: the `-latlong` search term, its corner order and the result item shape (`last_position`, `origin`,
  `destination`, `aircraft_type`, `operator*`) follow FlightAware's search syntax and the `/flights/{id}/position`
  shapes in `aeroapi_types.ts`; the OpenAPI file is not in this repo. The first real answer must confirm them
  before the radar is switched on. Price: $0.05 per result set from `docs/provider-check.md` (flight search).
- The answer in `supabase/functions/nearby-flights/contract/` is checked by the function's tests
  (`UPDATE_CONTRACT=1` rewrites it) and decoded by `NearbyFlightsTests` in FlightKit.
- The app sends the place rounded to two decimals, never asks for location permission on its own (it reads the
  grant the leave-by reminders asked for), refreshes every 60 seconds only while the radar is on screen, and
  follows a tapped plane by searching around it.

## flight-schedules

The "add a flight" search for days or weeks ahead: what the airlines plan to fly on a day, from airline
schedules. Paid (AeroAPI schedules). A schedule is a plan: no status, no estimates, nothing is stored in
`flights`; the app follows a row through `flight-lookup`.

`POST /flight-schedules` with `{ "origin": "KSFO", "destination": "KORD", "date": "2026-11-03" }`

```json
{
  "date": "2026-11-03",
  "fetched_at": "2026-11-01T12:00:00.000Z",
  "stale": false,
  "truncated": false,
  "flights": [
    {
      "ident": "UA2306",
      "airline": "UAL",
      "origin": "KSFO",
      "destination": "KORD",
      "scheduled_out": "2026-11-03T16:35:00.000Z",
      "scheduled_in": "2026-11-03T20:52:00.000Z",
      "aircraft_type": "B39M"
    },
    {
      "ident": "AA1781",
      "airline": "AAL",
      "origin": "KSFO",
      "destination": "KORD",
      "scheduled_out": "2026-11-03T18:10:00.000Z",
      "scheduled_in": "2026-11-03T22:31:00.000Z",
      "aircraft_type": "A321"
    },
    {
      "ident": "UA1958",
      "airline": "UAL",
      "origin": "KSFO",
      "destination": "KORD",
      "scheduled_out": "2026-11-03T20:00:00.000Z",
      "scheduled_in": "2026-11-04T00:15:00.000Z",
      "aircraft_type": "B772"
    },
    {
      "ident": "AS1314",
      "airline": "ASA",
      "origin": "KSFO",
      "destination": "KORD",
      "scheduled_out": "2026-11-03T21:50:00.000Z",
      "scheduled_in": "2026-11-04T02:05:00.000Z",
      "aircraft_type": "B738"
    }
  ]
}
```

- At least one of `origin`, `destination` and `ident` (else 400 `invalid_request`). `origin` and `destination`
  are airport codes, IATA or ICAO, any case (unknown is 400, the same twice is 400). `ident` is an airline code
  and a number such as `UA1958` or `UAL1958`; `airline` (IATA or ICAO) narrows by operator. The provider gets
  `ident` as `airline` plus `flight_number`.
- `date` is `YYYY-MM-DD`, the local day at the origin, else at the destination. Within 330 days ahead and no
  more than 2 days back, else 400 `out_of_window`; a bad date is 400 `invalid_request`. A flight number alone
  has no place: the provider is asked from 10:00Z the day before (midnight at UTC+14) to noon UTC the day after, and only the
  flights leaving on `date` in their origin's timezone are kept (a 20:00 New York departure is 01:00Z the next
  day and still counts for `date`).
- `time` (optional) is minutes after local midnight, an integer 0 to 1439 (else 400 `invalid_request`). With an
  `origin` or `destination` it narrows the provider window to 4 hours either side of it, within the local day;
  a flight number alone ignores it. The app sends it for one-place searches only.
- The provider's schedules (operating flights only, no codeshares) are read for that window, at most 3 result
  sets, and cached whole per search and day for 6 hours in `schedules_cache` (service role only, pruned daily),
  empty answers included; a search with a `time` is cached apart from the whole day. `truncated` is true when
  the provider still had result sets after the third (a busy airport's day): the answer holds the first flights
  only, and the app says so. `flights` are sorted by `scheduled_out`; `origin` and `destination` are ICAO codes,
  `ident` the IATA designator (else the provider's), `airline` the ICAO airline code, times ISO in UTC.
- `stale` and 503 `provider_unavailable` as in `alternate-flights`: a refused refresh serves the cached answer of
  any age, with nothing cached the call fails.
- Limit: 30 calls per user per hour (429 `rate_limited`).
- The answer in `supabase/functions/flight-schedules/contract/` is written by the function's tests.
- Cost: one to three `/schedules` result sets per search and day, shared by everyone; counted at the same cautious
  $0.02 as `alternate-flights` until the price is confirmed.

## security-wait

The security (TSA) wait at a US airport, per checkpoint: the flight sheet's Good to Know row (departure
airport, from 4 hours before departure until the flight leaves) and the airport sheet's Security section.
Free: no paid provider is called. Sources and why: `docs/data-sources.md`, "Security wait times".

`GET /security-wait?airport=SFO`

```json
{
  "airport": "KSFO",
  "iata": "SFO",
  "fetched_at": "2026-11-03T15:30:00.000Z",
  "available": true,
  "reason": null,
  "live": false,
  "source": { "id": "estimate_tsa_throughput", "name": "Estimate from TSA checkpoint traffic", "url": "https://www.tsa.gov/foia/readingroom" },
  "checkpoints": [
    { "id": "t1", "name": "Harvey Milk Terminal 1", "terminal": "1", "precheck": true, "standard_minutes": 15, "precheck_minutes": 5 },
    { "id": "t3-e", "name": "Terminal 3 E", "terminal": "3", "precheck": false, "standard_minutes": 15, "precheck_minutes": null }
  ]
}
```

- `live` is true only when a live source measured the figures (`source` names it). There is no live source
  today, so every answer is an estimate; the app says "Estimate" and never "Live" for it.
- Estimates: `estimate_tsa_throughput` per checkpoint when the airport has rows in `security_checkpoints` and
  `security_throughput` (a typical week of TSA's hourly throughput), else `estimate_typical_day`, one row
  `id: "all"`, `name: "All checkpoints"`, for the airport's local hour. Minutes are rounded to 5, never below 5.
- `terminal` is the airport's own name for the terminal ("1", "B", "International"), null when unknown or
  shared. `precheck` is true with PreCheck lanes, false without (`precheck_minutes` then null), null unknown.
- Checkpoints are sorted by terminal (numbers in order), then name.
- Outside the US and its territories: `available: false`, `reason: "outside_us"`, `source: null`, no
  checkpoints. An unknown or malformed code is 400 `invalid_request`.
- Answers are cached whole for 5 minutes per airport (`security_wait_cache`, service role only, pruned daily).
  A failing live source falls back to the estimate; an old live figure is never served.
- Limit: 120 calls per user per hour (429 `rate_limited`).
- The answers in `supabase/functions/security-wait/contract/` are written by the function's tests and decoded
  by `SecurityWaitTests` in FlightKit.

## share-flight and flight-page

Live flight sharing. The sheet's Share hands over `https://somalabs.me/f/<token>`; anyone with the link sees
the flight, live, with no account, until 24 hours after it arrives or until the sharer taps Stop Sharing.

- `POST /share-flight { "flight_id": "<uuid>" }` answers `{ "url": "https://somalabs.me/f/<43 chars>",
  "expires_at": "2026-11-04T20:55:00.000Z" }`. Each call makes a new random token (32 bytes, base64url);
  `flight_shares` keeps only its SHA-256. The caller must follow the flight or keep it in the Passport, else
  404 `not_found`; a flight down for more than 24 hours is 409 `out_of_window`.
- `GET /share-flight?flight_id=` answers `{ "active": true, "expires_at": "..." }` while the caller has a link
  that still opens, else `{ "active": false, "expires_at": null }`.
- `DELETE /share-flight?flight_id=` revokes every link of the caller's to that flight: `{ "revoked": 2 }`.
- Expiry is computed, not stored: 24 hours after the best arrival time (gate, else runway, else estimate,
  else schedule), so a delay keeps the link open longer (`_shared/share.ts`).
- Limit: 60 calls per user per hour, all three methods together (429 `rate_limited`).
- The answers in `supabase/functions/share-flight/contract/` are written by the function's tests and decoded
  by `FlightShareTests` in FlightKit.

`GET /flight-page/<token>` is the page itself: self-contained HTML (inline CSS and SVG, no script), the
app's dark design, the airline mark, route, times in status colours, terminal, gate and belt, a progress bar
in the air, a static great circle map on a Natural Earth outline, Open Graph tags, a meta refresh every 60 s
and a "Get Soma Flight" link. It reads the flights row, its airports and airline only: never the sharer's
seat, booking code or notes, never the sharer's name. Unknown, revoked and expired tokens all answer the same
404 page. `GET /flight-page/<token>/og.png` is the 1200 by 630 preview image (the route map, drawn by resvg).
Cached 30 s (page) and 300 s (image) by the CDN in front.

Environment: `SHARE_BASE_URL` (default `https://somalabs.me/f/`), `GET_APP_URL` (default
`https://somalabs.me/flight`), `PUBLIC_SUPABASE_URL` (the project URL browsers reach, for signed logo URLs).

## friends (and the Friends RPCs)

Mutual friends, made only by invitation: a single-use link `https://somalabs.me/i/<token>` (32 random bytes,
SHA-256 kept, open 7 days) or the 8-character friend code shown in the Friends tab (Crockford base32). No
contacts, no phone or email lookup. Migration `20261031000022_friends.sql`, tests `supabase/tests/friends_test.sql`.

`POST /friends` (signed in; 60 calls per user per hour, codes typed 10 per hour; 429 `rate_limited`):

- `{ "action": "invite" }` -> `{ "id", "url", "expires_at" }`. At most 20 open links per user.
- `{ "action": "preview", "token" }` -> `{ "state": "open|expired|used|self|friends", "display_name", "emoji" }`;
  `token` may be the bare token or the whole link. Unknown: 404 `not_found`.
- `{ "action": "accept" | "decline", "token" }` -> `{ "friend_id": "<uuid>" | null }`. The first answer closes
  the link; a used or expired link is 409 `out_of_window`, one's own link 400 `invalid_request`.
- `{ "action": "request", "code" }` -> `{ "result": "sent" | "accepted" | "friends" }`: a request to the
  code's owner (`accepted` when they had asked the caller already). Unknown code: 404 `not_found`.
- `{ "action": "respond", "invitation_id", "accept" }` -> `{ "answered" }` (a request made to the caller).
- `{ "action": "revoke", "invitation_id" }` -> `{ "revoked" }` (a link or request the caller made).
- `{ "action": "reset_code" }` -> `{ "code" }`: the old code stops working.

Reads and own changes go straight to PostgREST, as the signed-in user: `rpc/friends_me` (code, pause, name,
emoji), `rpc/friends_list`, `rpc/friend_requests`, `rpc/friend_flights { p_friend }` (upcoming and in-air
followed flights, flight columns only, never seat, booking code, notes or pass), `rpc/friend_passport
{ p_friend }` (totals only), `rpc/friend_remove { p_friend }`; `PATCH friendships` (`share_flights`,
`share_passport`, `alerts` on the caller's own rows), `PATCH friend_settings` (`sharing_paused`), `PATCH
profiles` (`display_name`, `emoji`). Each read checks both rows of the friendship, the friend's switch and
their pause. push-sender sends a friend's take-off, landing and delays of 30 minutes or more to friends who
turned alerts on for them, in the Delays and Take-off and Landing categories.

Environment: `INVITE_BASE_URL` (default `https://somalabs.me/i/`). The landing site must send `/i/*` to the
app (universal link, `applinks:somalabs.me`) or to `somaflight://i/<token>`.

somalabs.me routes `/f/*` to the function (landing site's repository). Supabase rewrites a `text/html` answer
to `text/plain` on its own domain, so the landing must serve the HTML with its own content type: a route
handler that fetches `https://<project>.supabase.co/functions/v1/flight-page/<path>` and returns the body with
the function's status and headers. A plain rewrite is enough only once the project serves functions from a
custom domain (where the rewrite to `text/plain` does not apply); check the content type before relying on it.
## faa-status

The FAA's live programs at a US airport: the flight sheet's Good to Know (each airport's card), the airport
sheet's issues card and the Operations Report. Free: the FAA's public NAS status feed, the JSON behind
nasstatus.faa.gov (`GET https://nasstatus.faa.gov/api/airport-events`; the older XML at
`/api/airport-status-information` has the same programs with text times and no ids). Neither is formally
documented: the parser (`_shared/faa_nas.ts`) reads the field names of real answers and of the FAA status
page's own code, and skips anything it does not recognise.

`GET /faa-status?airport=SFO`

```json
{
  "airport": "KSFO",
  "iata": "SFO",
  "available": true,
  "reason": null,
  "stale": false,
  "fetched_at": "2026-10-31T20:10:00.000Z",
  "programs": [
    {
      "airport": "SFO",
      "kind": "ground_delay",
      "reason": "low clouds",
      "reason_raw": "WEATHER / LOW CEILINGS",
      "average_minutes": 47,
      "trend": null,
      "extension": null,
      "starts_at": "2026-10-31T16:00:00.000Z",
      "ends_at": "2026-11-01T03:59:00.000Z",
      "updated_at": "2026-10-31T16:05:44.000Z",
      "advisory_url": "https://www.fly.faa.gov/adv/adv_otherdis.jsp?advn=27&..."
    }
  ]
}
```

- `kind`, most serious first: `closure`, `ground_stop`, `ground_delay`, `departure_delay`, `arrival_delay`,
  `deicing`. The app drops a kind it does not know, so the backend may add one.
- `reason` is the cause in plain words ("low clouds", "heavy traffic", "thunderstorms", "strong wind",
  "runway or taxiway work"...), null when the FAA gave none; `reason_raw` is the FAA's own text.
- `average_minutes`: ground delay programs and departure or arrival delays. `trend` (`increasing`,
  `decreasing`, `steady`): departure and arrival delays. `extension` (`low`, `medium`, `high`): how likely the
  FAA thinks a ground stop runs past `ends_at`.
- `starts_at`, `ends_at`: the program's planned window, null when unknown or open ended. A program whose
  `ends_at` has passed is never answered.
- `airport` is the FAA's code: the IATA code at every airline airport (else the ICAO code without its K).
- Closures: only a full closure counts. A closure "to non scheduled transient general aviation" and the
  feed's free-form notices restrict private flights only, and are left out.
- Which end matters (the app's `FAAFacts.matters` and the sweep): departure delays and deicing at the origin,
  arrival delays at the destination, closures, ground stops and ground delay programs at either end.
- Outside the US and its territories: `available: false`, `reason: "outside_us"`, no programs, the feed not
  read (there is no national program feed to read). An unknown or malformed code is 400 `invalid_request`.
- `conditions` (every airport, US or not; absent only when the function runs without it): what rules over the
  airport's NOTAMs, METAR and TAF say, with no language model and no national feed. `{ level, summary,
  reasons, sources }`: `level` is `normal`, `minor` or `major`; `reasons` (most serious first, at most 5) are
  `{ source: "notam" | "metar" | "forecast", level: "minor" | "major", text, starts_at, ends_at }` with plain
  English in `text` and no clock times (the app shows `starts_at` and `ends_at` in the airport's time zone);
  `summary` is the first reason's text, null on a normal day; `sources` is `{ metar, taf, notam }`, each
  false when that source could not be read (a missing NOTAM key or a failing feed is said, never read as an
  all clear). `conditions` is null when nothing at all could be read. Rules (`_shared/conditions.ts`): an
  airport closed by notice is major (closed with exceptions minor; closed to private flights only is
  ignored); one whole runway closed is minor, two or more major; a runway closed in part and an ILS out of
  service are minor; taxiway, construction and obstacle notices are not counted. Weather is read by the core's
  `weatherImpact` (thunderstorms, freezing precipitation, snow, low ceilings, fog, low visibility, strong wind
  and gusts, heavy rain): a severe reading is major, a moderate one minor, now (METAR) and over the next 12
  hours (TAF periods; TEMPO and PROB periods are never above minor and read "at times"). Notices count while
  in effect or starting within 6 hours. At US airports the reasons come next to the FAA's `programs`. The
  weather is kept 10 minutes per airport in the function instance and the notices come from the same
  `faa_notam_cache` rows `faa-notams` fills (so the NOTAM key is needed for them; without it `sources.notam`
  is false). A failing summary never fails the answer (`conditions: null`).
- Cache: the whole feed in `faa_status_cache` (one row, service role only) for 5 minutes, shared by every
  airport. When the FAA does not answer, a copy up to 30 minutes old answers with `stale: true` (and
  `fetched_at` its read time); older, 503 `provider_unavailable`.
- Limit: 120 calls per user per hour (429 `rate_limited`).
- `POST /faa-status?mode=sweep`, service role only (pg_cron `faa-status-sweep`, every 5 minutes): refreshes
  the feed and hands each ground stop, ground delay program or closure that holds a followed flight to
  push-sender as an `airport_program` alert (see Push alerts). A flight is held when someone follows it with
  `notify` on, it is scheduled (or unknown) and has not left the gate, it leaves between an hour ago and 12
  hours from now, and the program covers its departure (its arrival for a closure of the destination).
  A stale feed sends nothing. At most 200 alerts per run. Answer `{ ok, mode, stale, programs, flights, sent,
  failed }`.
- The answers in `supabase/functions/faa-status/contract/` are written by the function's tests and decoded by
  `FAATests` in FlightKit.

## faa-notams

The NOTAMs (notices to air missions) of an airport that a passenger can feel, in plain English with the
published text kept, most felt first: the Operations Report lists them, and Good to Know shows one line per
airport ("2 runway closures at SFO") when a whole runway or the airport is closed or an ILS is out.

Source: the FAA NOTAM API (`https://external-api.faa.gov/notamapi/v1/notams?icaoLocation=KSFO`, from the
api.faa.gov portal). Free, but every call carries the `client_id` and `client_secret` headers of an FAA
developer account: function secrets `FAA_NOTAM_CLIENT_ID` and `FAA_NOTAM_CLIENT_SECRET` (and optionally
`FAA_NOTAM_URL` should the FAA move the endpoint). Without both, the function answers `configured: false`
with no notams and calls nothing; the app then hides every NOTAM row.

`GET /faa-notams?airport=SFO`

Airports outside the US work the same way: the FAA NOTAM API also serves ICAO NOTAMs, and the function asks
for any airport in `airports` by its ICAO code (`airport=CDG` asks `icaoLocation=LFPG`). The decoder reads
the ICAO wording too (`E) RWY 09L/27R CLOSED DUE WIP`, `AERODROME CLOSED`, `ILS RWY 27L UNSERVICEABLE`).
Coverage of foreign airports in the FAA service is not guaranteed: an airport with no notice the FAA holds
simply answers an empty list.

```json
{
  "airport": "KSFO",
  "iata": "SFO",
  "configured": true,
  "stale": false,
  "fetched_at": "2026-10-31T08:00:00.000Z",
  "notams": [
    {
      "number": "10/101",
      "kind": "runway_closed",
      "title": "Runway 10L/28R closed",
      "detail": null,
      "relevance": 80,
      "raw": "!SFO 10/101 SFO RWY 10L/28R CLSD 2610310500-2610311300",
      "starts_at": "2026-10-31T05:00:00.000Z",
      "ends_at": "2026-10-31T13:00:00.000Z",
      "ends_estimated": false
    }
  ]
}
```

- `kind` and `relevance` (0 to 100, the order of the list): `airport_closed` 100 (2 when closed to private
  flights only, "Closed to private and charter flights"; 50 with other exceptions), `runway_closed` 80 (50 in
  part), `ils_out` 60, `construction` 35 on a runway or 20 elsewhere, `taxiway_closed` 25, `obstacle_light` 5.
  Ties go to the notice in effect first. Every other notice (frequencies, procedures, airspace, birds) is
  left out, as are cancellations.
- The decoder (`_shared/notam.ts`, `decodeNotam`) reads the US domestic form, the bare body and the ICAO form
  (its E) field). `raw` is the domestic text when the API gives it, else the body.
- Only notices in effect now or starting within 36 hours, at most 30. `ends_at` null is permanent or until
  further notice; `ends_estimated` true when the end is the FAA's estimate ("EST").
- Cache: per airport in `faa_notam_cache` for 15 minutes (not-configured answers are never stored). When the
  API fails, a copy up to 6 hours old answers with `stale: true`; none, 503 `provider_unavailable`.
- Limit: 120 calls per user per hour (429 `rate_limited`).
- The answers in `supabase/functions/faa-notams/contract/` are written by the function's tests and decoded by
  `FAATests` in FlightKit.

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
  out. `wx` holds the present weather groups ("-RA BR", null when none), `clouds` every layer, `dewpointC`
  and `altimeterHpa` the rest of the METAR, `tafIssuedAt` when the TAF was issued. Each forecast period has
  its own `wx` and `clouds`, and `change` says how it starts: null for the base forecast, `FM`, `BECMG`,
  `TEMPO` or `PROB` (with `probability` in percent); TEMPO and PROB periods overlap the one they sit in.
  The app reads these through the core's weather impact (`impact.rs`). An airport with no usable METAR is 404 `not_found`; a failed METAR request is never cached (the old
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
        "ceilingFt": 2500,
        "change": null,
        "probability": null,
        "wx": "-RA",
        "clouds": [
          {
            "cover": "SCT",
            "baseFt": 1500
          },
          {
            "cover": "BKN",
            "baseFt": 2500
          },
          {
            "cover": "OVC",
            "baseFt": 10000
          }
        ]
      },
      {
        "from": "2026-10-29T21:00:00.000Z",
        "to": "2026-10-30T00:00:00.000Z",
        "category": "VFR",
        "windDirDeg": 80,
        "windKt": 7,
        "gustKt": null,
        "visibilitySm": 6,
        "ceilingFt": 10000,
        "change": "FM",
        "probability": null,
        "wx": "VCSH",
        "clouds": [
          {
            "cover": "SCT",
            "baseFt": 4000
          },
          {
            "cover": "OVC",
            "baseFt": 10000
          }
        ]
      },
      {
        "from": "2026-10-30T00:00:00.000Z",
        "to": "2026-10-30T15:00:00.000Z",
        "category": "VFR",
        "windDirDeg": 90,
        "windKt": 3,
        "gustKt": null,
        "visibilitySm": 6,
        "ceilingFt": 4000,
        "change": "FM",
        "probability": null,
        "wx": null,
        "clouds": [
          {
            "cover": "OVC",
            "baseFt": 4000
          }
        ]
      },
      {
        "from": "2026-10-30T15:00:00.000Z",
        "to": "2026-10-30T19:00:00.000Z",
        "category": "VFR",
        "windDirDeg": 100,
        "windKt": 6,
        "gustKt": null,
        "visibilitySm": 6,
        "ceilingFt": 5000,
        "change": "FM",
        "probability": null,
        "wx": "-RA BR",
        "clouds": [
          {
            "cover": "OVC",
            "baseFt": 5000
          }
        ]
      },
      {
        "from": "2026-10-30T19:00:00.000Z",
        "to": "2026-10-31T00:00:00.000Z",
        "category": "IFR",
        "windDirDeg": 100,
        "windKt": 5,
        "gustKt": null,
        "visibilitySm": 3,
        "ceilingFt": 900,
        "change": "FM",
        "probability": null,
        "wx": "-RA BR",
        "clouds": [
          {
            "cover": "OVC",
            "baseFt": 900
          }
        ]
      }
    ],
    "wx": "-RA",
    "clouds": [
      {
        "cover": "BKN",
        "baseFt": 900
      },
      {
        "cover": "BKN",
        "baseFt": 2600
      },
      {
        "cover": "BKN",
        "baseFt": 4600
      },
      {
        "cover": "OVC",
        "baseFt": 13000
      }
    ],
    "dewpointC": 20,
    "altimeterHpa": 1021.1,
    "tafIssuedAt": "2026-10-29T17:30:00.000Z"
  }
}
```

## airport-weather, airport-stats and airport_regulars

The Airports feature (see [airports.md](airports.md)). The exact shapes are the contract files the
functions' tests write and the app's `AirportsTests` decode:

- `airport-weather/contract/list.json`: one batch of METARs in plain words (`condition`, `summary`,
  `category`, wind, temperature, `metar_raw`, `stale`) and, for US airports, the FAA programs
  (`faa: { stale, fetched_at, programs }`, the same program shape as `faa-status`). A failed METAR or
  FAA read leaves that part `null`.
- `airport-weather?...&forecast=1` adds `forecast` to each airport: the TAF of any airport worldwide that has
  one, `{ issued_at, taf_raw, periods, stale }`, `null` when the airport has no TAF or NOAA is down with
  nothing kept. A period is `{ from, to, category, wind_dir_deg, wind_kt, gust_kt, visibility_sm,
  ceiling_ft, change, probability, wx, summary }` with `change` one of `FM`, `BECMG`, `TEMPO`, `PROB` (null
  for the base forecast) and `summary` the period in plain words ("Light rain, wind 12 kt gusting 25 kt,
  visibility 3 mi, cloud base 800 ft", "At times: ..." for TEMPO, "30% chance: ..." for PROB). One batch
  request for the TAFs not kept; kept 10 minutes, stale up to an hour. Without `forecast=1` the key is
  absent. The airport sheet reads the same TAF through `airport-board?kind=weather` (the `Weather` model's
  `forecast`).
- `airport-stats/contract/detail.json`: `{ available, reason, provider, icao, fetched_at, stale,
  departures, arrivals, today, next_7_days }`. A direction is `{ total, on_time, delayed, canceled,
  avg_delay_minutes, trend: [{ hour, avg_delay_minutes, flights, estimated }], worst_routes,
  worst_airlines }`; `today` is `{ departures, airlines, airports_served, countries_served,
  busiest_airlines: [{ operator, flights }], busiest_routes: [{ icao, flights }] }`. `next_7_days` is
  `null` until a schedules feed exists.
- `airport-stats/contract/list.json`: `{ available, reason, provider, airports: [{ icao, iata,
  fetched_at, stale, departures, arrivals, error }] }` with the directions reduced to their counts.
- `airport-stats/contract/no_provider.json`: `BOARD_PROVIDER=none` answers `available: false,
  reason: "no_provider"` and every number `null`, with no provider call.
- `airport_regulars(p_icao)`: the caller and friends sharing their Passport, by flights through the
  airport (canceled flights excluded), at most 10, `last_visit` cut to the month.

## App configuration and sign in

- Debug builds use `Apps/<platform>/Config.Debug.xcconfig`: the local stack (`http://127.0.0.1:58321`), its
  public demo anon key, and an Info.plist that allows local networking. Release builds use
  `Config.Release.xcconfig`, which is empty: the URL and anon key must come from a gitignored
  `Config.local.xcconfig` next to it, otherwise the app refuses to start ("no server configured"). A plain
  http URL is only accepted for this machine. Never put the service role key in any of these files.
- `INSIGHTS_ENABLED` (Info.plist `InsightsEnabled`) turns the paid flight sheet sections on
  (`flight-insights`): YES in `Config.Debug.xcconfig` and, since the owner's yes on 2026-11-06, in
  `Config.Release.xcconfig` (answers unavailable until `AEROAPI_KEY` is set). Off, the app shows neither section
  and makes no call. Screenshot runs (`-useFakes`) always show the fakes.
- Sign in with Apple needs a provisioning profile. The Mac Debug build signs to run locally and leaves the
  capability out (`SomaFlight-Debug.entitlements`), so only email sign-in works there; a Mac Release or iOS
  device build needs the team and a profile with Sign in with Apple, and fails to sign without one.
- The email link returns as `somaflight://auth-callback?code=...` (PKCE). The app ignores any other form,
  including a fragment carrying tokens. The local stack lists the callback in `additional_redirect_urls`.
- Sign-out deletes this device's `push_tokens` rows (clients keep delete on their own rows) before the
  session ends.
