# Soma Flight v1: design

Date: 2026-10-28
Status: approved in conversation, awaiting written review
Scope: sub-projects 1 (flight data backend) and 2 (core app on iOS and macOS)

## 1. Goal

Soma Flight is a public App Store app for iOS and macOS that tracks flights in real time and keeps a personal history of past flights with stats. Its visual language takes inspiration from the reference screenshots in `~/Desktop/Screenshot FLight app` (dark, dense, globe-first, red/amber/green delay colours), under Soma Flight branding. It must not reuse another product's name, marks, or trade dress.

Later platforms (iPad, Apple Watch, Apple Vision Pro) are shells over the same shared package and are out of scope here.

### Success criteria for v1

- A signed-in user can find a flight by flight number, route, or airport, follow it, and see its status, gates, delays, and live position on the globe.
- Status changes reach the user as a push notification and a Live Activity update within about a minute of the provider alert, without any per-user polling.
- Any airport can be opened to see a departures board, an arrivals board, delay stats, a per-hour delay chart, and current METAR/TAF weather.
- Landed followed flights move into the user's history, and a Passport view shows stats over that history, filtered by year.
- Provider spend stays bounded by shared caching and per-user limits, with an alert to the owner past a daily threshold.

## 2. Decisions

| Topic | Decision |
|---|---|
| Audience | Public App Store product, commercial data license required |
| Live scope | Followed flights plus airport boards and delay stats. No global radar |
| History | The user's own past flights and stats. No track replay |
| Backend | Supabase with user accounts (new dedicated project `soma-flight`) |
| Flight data | FlightAware AeroAPI behind edge functions, alerts by webhook |
| Weather | aviationweather.gov METAR and TAF (free, public) |
| Map | MapKit globe with realistic elevation, drawn on the client |
| Targets | iOS 26 and macOS 26, Swift 6 strict concurrency |
| Friends | Out of v1 |

Provider pricing was checked only through third-party guides on 2026-10-28 (AeroAPI Standard reported around $100 per month minimum, metered per result set). The plan's first backend task confirms prices on FlightAware's own pricing page before any commercial key is bought. Cirium is the fallback if AeroAPI terms do not allow consumer redistribution.

## 3. Architecture

```
iOS / macOS app (SwiftUI, shared package FlightKit)
   |  supabase-swift: auth, Postgres through RLS, Realtime
   v
Supabase project "soma-flight"
   |- Postgres tables (section 4)
   |- Edge functions: flight-lookup, follow-flight, aeroapi-webhook, airport-board, push-sender, delete-account
   |- pg_cron: refresh watched airport boards, prune caches, close alert subscriptions
   v
External: AeroAPI (flights, boards, alerts), aviationweather.gov (METAR/TAF), APNs
```

Rules:

1. The app never calls AeroAPI. Only edge functions hold the key.
2. A real flight is one shared row. Many followers of the same flight cost one alert subscription.
3. Live path: AeroAPI alert, then `aeroapi-webhook`, then a row in `flight_events` and an update to `flights`, then Realtime to open apps and `push-sender` to APNs for closed apps and Live Activities.
4. Airport boards are fetched once per airport per TTL and served to every viewer from `airport_snapshots`.

## 4. Data model (Postgres)

- `flights`: id, provider_id (AeroAPI fa_flight_id, unique), ident (for example `AF84`), operator, origin and destination ICAO and IATA, scheduled, estimated, and actual out/off/on/in times, gate and terminal at both ends, baggage belt, aircraft type, registration, status, last position (lat, lon, altitude, ground speed, heading, time), alert_id, updated_at. Readable by any signed-in user. Written only by service role.
- `flight_events`: id, flight_id, provider_event_id (unique, for idempotency), kind (gate_change, delay, departure, arrival, cancel, diversion, position), payload jsonb, received_at. Readable by signed-in users. Written by service role.
- `webhook_inbox`: raw alert body, received_at, processed_at, error. Service role only. Kept so events can be replayed.
- `user_flights`: user_id, flight_id, created_at, notify (bool). RLS: owner only.
- `past_flights`: id, user_id, flight_id (nullable for manual entries), date, origin, destination, airline, flight number, aircraft type, registration, distance_km, block minutes, delay minutes, seat. RLS: owner only.
- `airport_snapshots`: airport ICAO, kind (departures, arrivals, stats, weather), payload jsonb, fetched_at, last_viewed_at. Readable by signed-in users. Written by service role.
- `push_tokens`: user_id, device token, kind (alert or live_activity), flight_id for Live Activity tokens, platform, updated_at. RLS: owner only.
- `usage_counters`: day, endpoint, calls, estimated_cost. Service role only.
- `profiles`: user_id, display name, units, plan (free or pro), created_at, status (active or deleted).

Account deletion sets `profiles.status` to deleted and removes the user's rows in `user_flights`, `past_flights`, and `push_tokens`, then deletes the auth user. This is the App Store required in-app path.

## 5. Edge functions

- `flight-lookup` (user JWT): search by ident and date, by route and date, or by airport. Calls AeroAPI, upserts `flights`, returns results. Per-user limit of 30 searches per hour.
- `follow-flight` (user JWT): inserts `user_flights`, and creates the AeroAPI alert if the flight has none. Free plan: 3 active followed flights; Pro: unlimited. Until the paywall ships, `plan` is set by hand for testers.
- `aeroapi-webhook` (shared secret): stores the raw body in `webhook_inbox`, then parses it, updates `flights`, inserts `flight_events` keyed on the provider event id, and calls `push-sender`. Duplicate events are ignored.
- `airport-board` (user JWT): returns the cached snapshot if younger than 5 minutes, otherwise refreshes from AeroAPI (boards) or aviationweather.gov (weather, 15 minutes). Sets `last_viewed_at`.
- `push-sender` (internal): sends APNs alert pushes and Live Activity updates to the followers of a flight, using token based APNs auth.
- `delete-account` (user JWT): the deletion path in section 4.

pg_cron jobs:

- Every 5 minutes, refresh boards for airports viewed in the last hour.
- Hourly, delete alert subscriptions 24 hours after a flight lands, and move each follower's landed flight into `past_flights`.
- Daily, compare `usage_counters` to a threshold and email the owner if it is crossed.

Delay stats (on time, delayed 15+, canceled, per-hour bars, average takeoff and landing delay, most disrupted routes and airlines) are computed in the function from the board data, not bought as a separate product.

## 6. App

### Code layout

```
Soma_Flight/
  Packages/FlightKit/
    Models     Flight, FlightEvent, Airport, AirportBoard, PastFlight, Weather (Codable, Sendable)
    Services   protocols FlightService, AirportService, AuthService, HistoryService, plus Supabase implementations and fakes
    Stores     @Observable MyFlightsStore, FlightDetailStore, AirportStore, PassportStore, SessionStore
    Cache      SwiftData store of the last known state for offline use
    UI         shared views: flight card, timeline, delay bar, board row, Swift Charts delay chart, weather block
    MapLayer   MapKit globe, great-circle route arcs, live plane annotation, airport pins
  Apps/iOS     tab bar shell, notification handling, Live Activity and widget extension
  Apps/macOS   floating sidebar over a full-window map
  supabase/    migrations, functions, SQL tests
```

Each service is a protocol so stores are testable with fakes. Views talk only to stores.

### Screens

- **Home**: full-bleed globe. iOS uses a bottom sheet and a floating tab bar (My Flights, Passport) with a search button. macOS uses a floating sidebar with the same sections.
- **My Flights**: cards for live and upcoming flights with status colour, times, gate, and delay. Empty state invites a search.
- **Flight detail**: route arc and live plane on the map, timeline of scheduled, estimated, and actual times, gates and terminals, baggage belt, aircraft and registration, and the departure and arrival airports as links to the airport sheet.
- **Add flight**: one search field accepting flight number, route, or airport, with recent searches.
- **Airport sheet**: issues banner when delays are high, departure and arrival performance splits, per-hour delay chart, departures and arrivals boards with filters (day, direction, airline), and weather with VFR/IFR category, ceiling, visibility, wind, and gusts.
- **Passport**: year filter (all time plus each year), totals (flights, distance, flight time, airports, airlines), hours lost to delays, most flown aircraft, a route map of past flights, and a past flights list sortable by date, origin, destination, airline, and aircraft.
- **Settings**: account, units (km or miles, 24 h or 12 h), alert types, privacy, export history (JSON and CSV), delete account.
- **Sign in**: Sign in with Apple and email.

### Live updates

- Realtime subscription on the user's followed flights while the app is open.
- Notifications for gate change, delay of 15 minutes or more, departure, landing, cancellation, and diversion.
- A Live Activity and Dynamic Island for the next followed flight, started on device and updated by APNs.

### Look

Dark first, light supported. Dense type with small caps labels, red/amber/green delay colours, Swift Charts bars, Liquid Glass on floating controls. Soma Flight name and icon only.

## 7. Errors and staleness

- Every flight, board, and weather payload carries `updated_at`. The UI shows its age and dims data older than its TTL rather than presenting it as current.
- Edge functions return typed errors: `provider_unavailable`, `not_found`, `rate_limited`, `plan_limit`, `unauthorized`. The app maps each to a short message and keeps showing the last cached data.
- Offline, the SwiftData cache opens My Flights, flight detail, and Passport with the last known state and an offline banner.
- Webhook failures leave the row in `webhook_inbox` with an error so it can be replayed.

## 8. Privacy and App Store

- RLS on every user table. Users never read another user's followed or past flights.
- In-app account deletion (section 4) and history export.
- Privacy manifest, notification and Live Activity usage text, and a privacy policy page before submission.
- Location is not requested in v1.

## 9. Testing

- FlightKit: unit tests on stores with fake services, and decoding tests on recorded AeroAPI and METAR fixtures.
- Edge functions: Deno tests with a mocked AeroAPI, covering idempotent webhook handling, cache TTL, rate limits, and plan limits.
- Database: SQL tests proving RLS isolation between two users and the deletion path.
- UI: snapshot checks of key screens on the iOS and macOS simulators, light and dark.
- End to end: follow one real flight on the AeroAPI personal tier and confirm push and Live Activity updates before buying the commercial tier.

## 10. Out of scope for v1

Friends and sharing, calendar and email import, iPad, Watch and Vision shells, global live radar, track replay, operational report summaries, and the paywall flow (the plan field exists, the purchase UI comes later).

## 11. Later sub-projects

1. Paywall and Pro subscription (StoreKit 2).
2. Friends and sharing.
3. Import from calendar and email.
4. iPad, Watch, and Vision shells.
