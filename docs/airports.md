# Airports

The Airports feature: a round button under the map controls opens the Airports card (a list of the
user's airports and the big hubs, each with its status, and a dot per airport on the globe). A row
opens the airport card, which this feature extends with a status card, the provider's delay trend,
the day's traffic, Runway Regulars, the user's history at the airport and a bottom bar.

The owner's rule for now is "keep it free". So the feature is split in two: what is free and real
today, and what needs a paid flight data plan. Without a plan the app says so in one calm line
("Live airport stats need a data plan"). It never makes numbers up. The fakes (`-useFakes`, and
`-fakeNoProvider` for the no-plan state) fill every part so the screens can be judged.

## What is real and free today

| Part | Source | Function |
| --- | --- | --- |
| Airport names, codes, city, country, flag, local time | the bundled reference data | none (on device) |
| Weather in plain words ("Partly cloudy with light winds.") and the flight category | NOAA METARs from aviationweather.gov, one batch request for up to 40 airports | `airport-weather` |
| Ground stops, ground delay programs, delays, closures (US airports) | FAA NAS status, the feed `faa-status` already reads | `airport-weather` (list), `faa-status` (card) |
| NOTAMs (US and ICAO NOTAMs of other countries) | FAA NOTAM API, when its key is set | `faa-notams` (card) |
| Inferred disruption outside the US (level and reasons from notices, METAR and TAF; rules only) | NOTAMs above, aviationweather.gov | `faa-status` `conditions` (card), shown like an FAA program, labelled inferred |
| Terminal forecast (TAF), any airport that has one | aviationweather.gov | `airport-board` weather (card), `airport-weather?forecast=1` |
| The status dot and line of every airport | worked out on device from the programs and the weather (`AirportStatus.of`) | none |
| Runway Regulars | our own Passport data: the caller and friends who share their Passport | `airport_regulars(p_icao)` RPC |
| Your History Here | the user's own Passport, already on the device | none |
| Favourite airports | kept on the device (UserDefaults) | none |

`airport-weather` caches each METAR for 10 minutes per function instance and serves a stale one for up
to an hour when aviationweather.gov fails. The answer carries `Cache-Control: private, max-age=300`.
It is rate limited to 120 calls an hour per user.

## What needs a paid plan

Everything counted from flights needs a board provider (`BOARD_PROVIDER`):

- on-time share, average delay and canceled share, for departures and arrivals (list columns, status card);
- the delay trend by hour, with the estimated hours ahead;
- the most disrupted routes and airlines;
- the day's traffic: departures, airlines, airports and countries served, busiest airlines (one split
  bar, drawn with our own monograms, never a logo) and busiest routes;
- the departures and arrivals boards themselves (`airport-board`, unchanged).

`airport-stats` is provider agnostic. It reads the same board snapshots as `airport-board` (same
lease, same 5 minute freshness), so the card and the boards never pay twice for one airport. With
`BOARD_PROVIDER=none` it answers `{"available": false, "reason": "no_provider"}` at once, calls no
provider and counts nothing against the rate limit. The app then hides every paid number and shows
the data plan note.

"Next 7 Days" needs a schedules feed (future timetables). No provider is wired for it yet, so
`next_7_days` is always `null` from the backend, and the app says so under the tab. The fakes fill it.

## Cost per airport refresh

One airport refresh is the two board snapshots (departures and arrivals). A snapshot lives 5 minutes
and is shared by every user who opens that airport in that window.

| Provider | Calls per refresh | Price | Cost per refresh | Notes |
| --- | --- | --- | --- | --- |
| AeroAPI | up to 8 result sets: per direction, the done list and the scheduled list, up to 2 pages each | $0.005 per result set | up to $0.04 | B2C use needs the Standard plan ($100 a month minimum). Personal ($5) is not for a public app. |
| FlightLabs | 2 (`/advanced-flights-schedules`, once per direction) | Starter $24.99 for 4,000 calls, overage $0.00813 | about $0.012 on Starter | free and trial answers are for personal and test use only |
| Aviationstack | 2 (`/flights` with `dep_icao` or `arr_icao`, limit 100) | Basic $49.99 for 10,000 requests, then about $0.02 | about $0.01 on Basic | Free plan (100 a month) is non-commercial |

Prices were read on 2026-10-31 (see [free-providers.md](free-providers.md)).

What a user does costs:

- one airport card open: 1 refresh, if nobody opened it in the last 5 minutes;
- the Airports list: up to 20 airports per `airport-stats` call, so up to 20 refreshes. Each refresh
  is shared, but a cold list is the expensive part. On AeroAPI a cold list is up to $0.80, and a list
  kept open and refreshed every 5 minutes for an hour is up to $9.60. On Aviationstack Basic a cold
  list is 40 requests, so 10,000 requests last 250 cold lists.

Before switching a provider on, consider limiting the list's live numbers to the user's own airports
(favourites and trips), or warming only the 20 busiest hubs on a schedule and sharing them.

## Runway Regulars and privacy

`airport_regulars(p_icao)` is `security definer` with an empty search path and returns at most 10
rows: the caller, and friends who share their Passport with the caller, where both friendship rows
exist, sharing is not paused and the account is active. Canceled flights do not count. The last visit
is cut to the month. Anonymous callers cannot run it (`archive_test` keeps it on the allow list).

## Favourites

There is no favourites table in Supabase, so favourites stay on the device and do not follow the
account. A table with row level security on `user_id` would be the next step.

## Files

- Backend: `supabase/functions/airport-weather`, `supabase/functions/airport-stats`,
  `supabase/functions/_shared/metar_words.ts`, `supabase/functions/_shared/airport_codes.ts`,
  `supabase/migrations/20261031000035_airport_regulars.sql`, `supabase/tests/airport_regulars_test.sql`.
- App: `Models/AirportOverview.swift`, `Services/AirportOverviewService.swift`,
  `Services/Fakes/FakeAirportOverviewService.swift`, `Stores/AirportsListStore.swift`,
  `UI/Screens/Airports/`, and the airport card in `UI/Screens/AirportView.swift`.
- Screens: `docs/screens/screens/airports-*.png`, from
  `SNAPSHOTS=1 swift test --package-path Packages/FlightKit --filter AirportsSnapshotTests`.
