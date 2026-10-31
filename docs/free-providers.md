# Free and freemium flight data providers

Checked 2026-10-31 for running Soma Flight (a free public App Store app published by Soma Labs, a
company) on sources other than FlightAware AeroAPI. Every price and limit below was read that day on
the pages linked; providers change them, so recheck before any purchase. The code is in
`supabase/functions/_shared/providers/` (selection: `select.ts`) and the secrets are listed in
[operations.md](operations.md#function-secrets).

## Verdict in one table

| Source | Gives us | Free tier | Terms for our app | Verdict |
| --- | --- | --- | --- | --- |
| OpenSky Network | live positions, callsign, icao24; past legs by aircraft with estimated airports | 400 credits a day anonymous, 4,000 with a free account | written licence required for a for-profit entity and for any live product | needs a written licence |
| ADS-B Exchange | live positions | none ($10 a month Community API on RapidAPI) | Community API is non-commercial; commercial use is an Enterprise licence | needs a paid licence |
| Aviationstack | status, schedules, gates, terminals, belt, delays, aircraft, some live positions | 100 requests a month | Free plan is personal, non-commercial | needs a paid plan (Basic $49.99 a month) |
| FlightLabs | status and timetables with gates, terminals, belt; live feed with registration | none (7 day trial capped at 50 requests) | free and trial answers are personal and test use only | needs a paid plan (Starter $24.99 a month) |
| AeroAPI (today) | everything, plus alert webhooks | $5 a month Personal, not for B2C | Standard ($100 minimum) allows B2C | keep for production |

None of the free tiers may legally feed a public app run by a company. The layer still supports
them so the owner can test with free keys and switch to a paid plan by changing secrets, not code.

## OpenSky Network

- API: <https://openskynetwork.github.io/opensky-api/rest.html>. Base `https://opensky-network.org/api`.
- Auth: OAuth2 client credentials only. Token from
  `https://auth.opensky-network.org/auth/realms/opensky-network/protocol/openid-connect/token`
  (`grant_type=client_credentials`, client id and secret from the account page), valid 30 minutes,
  sent as `Authorization: Bearer`. The docs say basic auth with username and password is no longer
  accepted. Anonymous calls still work for live state vectors.
- Credits per day: anonymous 400, standard account 4,000, active feeder 8,000; states, tracks and
  flights have separate buckets. `/states/all` costs 1 credit for a box up to 25 square degrees, 2 up
  to 100, 3 up to 400, 4 above or global. Seen on the live API on 2026-10-31: a query by `icao24`
  alone cost 4 (the remaining count went from 399 to 395), so the adapter searches a 5 by 5 degree box
  around the last position or the origin airport (1 credit) when it has no icao24. `/flights/*` cost
  4 credits for a day or less. A 429 carries `X-Rate-Limit-Retry-After-Seconds`.
- Endpoints we use: `GET /states/all` (`icao24`, or `lamin`/`lomin`/`lamax`/`lomax`), and
  `GET /flights/aircraft` (`icao24`, `begin`, `end`, at most 2 days). Flights endpoints answer 403
  anonymously ("You cannot access historical flights", seen 2026-10-31) and are filled by a nightly
  batch: only yesterday and older. There is no callsign filter on `/states/all`.
- Aircraft registration: the metadata endpoint `GET /api/metadata/aircraft/icao/{icao24}` answers
  410 Gone (checked 2026-10-31). The aircraft database file
  (`s3.opensky-network.org/data-samples/metadata/aircraftDatabase.csv`, 94 MB, last modified
  2024-11-04) falls under the same terms, so we do not import it.

Maps to our row: position only (`position_lat`, `position_lon`, `position_altitude_ft` from
`baro_altitude` in metres, `position_ground_speed_kt` from `velocity` in m/s, `position_heading` from
`true_track`, `position_at` from `time_position`). Status, times, gates, terminals, belt, type and
registration: none. The estimated departure and arrival airports of `/flights/aircraft` are guesses
from the track, a day late.

Terms (<https://opensky-network.org/about/terms-of-use>, General Terms of Use and Data License
Agreement): the licence is "solely for the purpose of non-profit research and non-profit education";
"Any use by a for-profit or commercial entity requires written permission and a license"; and
"Operational use of the REST API in any live product, service, or automated system also requires a
written license". They also forbid passing the data to anyone outside your institute and require a
citation in any publication. Verdict: **needs a written licence** (contact `contact@opensky-network.org`).

## ADS-B Exchange

- Community API (formerly API Lite): <https://www.adsbexchange.com/api-lite/>. Sold through RapidAPI,
  $10 a month for 10,000 requests, positions by location, hex, callsign or squawk.
- The page calls it "built for non-commercial use" and points commercial use to the Enterprise API
  (<https://www.adsbexchange.com/products/enterprise-api/>, price on request). The RapidAPI purchase
  carries RapidAPI's terms plus a personal use licence.
- Maps to our row: position only, like OpenSky.
- Verdict: **needs a paid licence** (Enterprise). No adapter was built: OpenSky covers the same
  capability for testing, and either one needs a contract before production.

## Aviationstack

- Docs: <https://aviationstack.com/documentation> (the live page is a script app; read through its
  2025-12-27 archive, <http://web.archive.org/web/20251227120633/https://aviationstack.com/documentation>).
  Base `https://api.aviationstack.com/v1`, key in the query string (`access_key`), JSON.
- Plans (<https://aviationstack.com/pricing>): Free $0, 100 requests a month, "Personal use",
  "Non-Commercial Use", no support. Basic $49.99 a month ($44.99 yearly), 10,000 requests, commercial
  use, then about $0.02 per request. Professional $149.99, 50,000. Business $499.99, 250,000. Paid
  plans bill overage past the allowance; an error does not count as a request.
- HTTPS: the archived docs say HTTPS is available on all plans and "You don't need a paid plan for
  accessing HTTPS protocol anymore". The adapter still treats it as a setting: an `http://`
  `AVIATIONSTACK_BASE_URL` is refused on the hosted project, and needs `AVIATIONSTACK_ALLOW_HTTP=true`
  on a local stack, because the key would travel in clear text.
- Free tier features: real-time `/flights` (filters `flight_iata`, `flight_icao`, `dep_icao`,
  `arr_icao`, `flight_status`, `limit` up to 100), airports, airlines, airplanes. Not free:
  `flight_date` (historical, Basic and up, last 3 months), `/timetable` and `/flightsFuture` (Basic
  and up; 1 request a minute on free, 1 per 10 s on paid), routes, autocomplete.
- Errors: `{ "error": { "code", "message" } }` with `invalid_access_key` (401),
  `https_access_restricted` and `function_access_restricted` (403), `usage_limit_reached` and
  `rate_limit_reached` (429). Checked live: a bad key answers 401 `invalid_access_key` on both HTTP
  and HTTPS.

Maps to our row (`aviationstack.ts`):

| Our column | Aviationstack field |
| --- | --- |
| `ident`, `operator` | `flight.iata` (else `icao`), `airline.iata` (else `icao`) |
| `origin_*`, `destination_*` | `departure.icao`/`iata`, `arrival.icao`/`iata` |
| `scheduled_out`, `estimated_out`, `actual_out` | `departure.scheduled`, `estimated`, `actual` |
| `estimated_off`, `actual_off` | `departure.estimated_runway`, `actual_runway` |
| `scheduled_in`, `estimated_in`, `actual_in` | `arrival.scheduled`, `estimated`, `actual` |
| `estimated_on`, `actual_on` | `arrival.estimated_runway`, `actual_runway` |
| `gate_*`, `terminal_*`, `baggage_belt` | `departure.gate`/`terminal`, `arrival.gate`/`terminal`/`baggage` |
| `aircraft_type`, `registration` | `aircraft.icao`, `aircraft.registration` |
| `status` | `flight_status` (`scheduled`, `active` as en route or departed, `landed`, `cancelled`, `diverted`; `incident` stays unknown), actual times first |
| position | `live` (metres to feet, km/h to knots) |
| `scheduled_off`, `scheduled_on` | not given: null |

Codeshare listings (`flight.codeshared` set) are skipped; the operating flight carries the data.
Times: the documented example writes times with `+00:00` but its two airports show the same clock
time, so the docs do not settle whether these are UTC or local clock times with a wrong offset.
`AVIATIONSTACK_TIMES=local` (default) reads them as the airport's clock at `departure.timezone` /
`arrival.timezone`; `utc` takes the offset at its word. Check one real answer against the airline's
own site before relying on either. The provider has no stable flight id: ours is
`aviationstack:<ICAO ident>:<origin>:<flight_date>` (two departures of one number from one airport on
one day would collide; rare).

Verdict: **Free is non-commercial, so it needs Basic ($49.99 a month) or higher for the app.**

## FlightLabs (goflightlabs.com)

- Docs: <https://www.goflightlabs.com/llms.txt> and one page per endpoint (`/real-time`,
  `/flights-schedules`, `/flight-info-by-flight-number`). Base `https://www.goflightlabs.com` (the
  Postman collection uses `app.goflightlabs.com`; `FLIGHTLABS_BASE_URL` overrides). Key as
  `Authorization: Bearer` (preferred) or `access_key`; the adapter uses the header so the key is never
  in a URL. Checked live: no key answers 401 `{"error":"You need to get your API Key to do API calls."}`.
- Plans (home page pricing, 2026-10-31): trial of 7 days or 50 requests, whichever first, card
  required. Starter $24.99 a month for 4,000 calls; Basic $49.99 for 10,000 (15 requests per 10 s);
  Pro $149.99 for 100,000; Premium $249.99 for 500,000; Elite $499.99 for 1,000,000; overage
  $0.00813 a call; Enterprise from $10,000 a year.
- Endpoints we use: `/advanced-flights-schedules` (`iataCode` IATA only, `type`, `flight_iata` or
  `flight_icao`): the airport's timetable with gates, terminals, belt, UTC and local times, delays,
  aircraft type, status; registration is not included (the docs say so). `/flight`
  (`flight_number`): dates and airports as display strings ("San Francisco (SFO)", "15:45"), used only
  to find where a number leaves from. `/flights` (`flightIcao`, `flightIata`, `hex`, `regNum`): the
  live feed with position, registration and icao24.

Maps to our row (`flightlabs.ts`): `scheduled_out`, `estimated_out`, `actual_out` from
`dep_time_utc`, `dep_estimated_utc`, `dep_actual_utc` (else the `_ts` epochs); the same on arrival;
`gate_*`, `terminal_*`, `baggage_belt` from `dep_gate`, `arr_gate`, `dep_terminal`, `arr_terminal`,
`arr_baggage`; `aircraft_type` from `aircraft_icao`; `status` from `status`. Runway times,
`registration` and `scheduled_off/on` are not in the timetable: null. Position and airframe from the
live feed. Our id: `flightlabs:<ICAO ident>:<origin>:<origin-local date>`. An ident lookup costs two
requests (`/flight` then the timetable); a poll or a board one.

Terms (<https://www.goflightlabs.com/terms>, "Modified and Effective on October 26, 2026"): "The Free
plan cannot be used for any commercial or public use or redistribution under any circumstances";
trial answers "are licensed for personal and trial use only"; commercial use is "authorized only
while the user maintains an active and paid subscription", and data kept after the subscription ends
needs a Lifetime License. Verdict: **needs a paid plan; Starter ($24.99) is the cheapest compliant
option found.**

## How the layer uses them

| Secret | Values | Default |
| --- | --- | --- |
| `STATUS_PROVIDER` | `aeroapi`, `aviationstack`, `flightlabs`, `none` | `aeroapi` |
| `BOARD_PROVIDER` | `aeroapi`, `aviationstack`, `flightlabs`, `none` | `aeroapi` |
| `POSITION_PROVIDER` | `aeroapi`, `aviationstack`, `flightlabs`, `opensky`, `none` | `aeroapi` |

Unset secrets keep today's AeroAPI behaviour exactly. An unsupported value (`opensky` for status, a
typo) selects `none` and logs it. `none` answers `provider_unavailable` for lookups and boards (the
app shows cached data) and no position. A selected provider without its key answers
`provider_unavailable` (503) on use; the function still starts.

Quotas: every non-AeroAPI request is charged first against `provider_quota`
(`charge_provider_quota`, migration 20261031000027), per provider and period (month for
Aviationstack and FlightLabs, UTC day for OpenSky). Past the allowance the call is refused with
`provider_unavailable` (503) before it goes out, and the functions fall back to what they have
cached, as with the AeroAPI daily spend cap (which still applies to AeroAPI). A counter outage also
refuses: a free tier is never overrun blind. Allowances default to the free tiers and follow
`AVIATIONSTACK_MONTHLY_QUOTA`, `FLIGHTLABS_MONTHLY_QUOTA`, `OPENSKY_DAILY_CREDITS`.

Without AeroAPI there is no webhook, so `follow-flight` makes no alert and `maintenance?mode=poll`
(cron `provider-poll`, every 5 minutes) polls followed flights. Each flight is asked about at four
points: 2 h before the best departure time (gate and delay), 15 min after it (departed), 30 min before
the best arrival time (estimate) and 20 min after it (landed, belt). `POLL_POINTS=extended` adds 6 h
and 45 min before departure, 90 min before arrival and 60 min after it. A point missed by more than
30 minutes is skipped. Answers that change nothing are dropped; changes go through `process_alert`,
the webhook's own transaction, so events, gate history and pushes work as they do with alerts. The
poller may use `POLL_QUOTA_SHARE` (default 0.7) of each allowance, spread evenly over the month by a
daily pace counter, so users' lookups keep the rest.

## Polling math: followed flights a day

flights a day = allowance x 0.7 / 30 days / polls per flight (`flightsPerDay` in `poll.ts`, tested).

| Plan | Requests a month | Core (4 polls) | Extended (8 polls) |
| --- | --- | --- | --- |
| Aviationstack Free | 100 | 0.58 (one flight every two days) | 0.29 |
| Aviationstack Basic, $49.99 | 10,000 | 58 | 29 |
| Aviationstack Professional, $149.99 | 50,000 | 291 | 145 |
| FlightLabs trial | 50 in all | 8 flights in total | 4 in total |
| FlightLabs Starter, $24.99 | 4,000 | 23 | 11 |
| FlightLabs Basic, $49.99 | 10,000 | 58 | 29 |
| FlightLabs Pro, $149.99 | 100,000 | 583 | 291 |

The other 30% serves lookups (one request each on Aviationstack, two on FlightLabs) and boards (one
request per board refresh, each viewed airport refreshing at most every 5 minutes). On a free tier
that is about 30 requests a month: keep `BOARD_PROVIDER=none` there.

OpenSky positions: `flight-position` refreshes a followed airborne flight at most once per 2 minutes
for all its viewers, 1 credit a refresh, so 400 credits a day are about 13 flight-hours of someone
watching, and 4,000 about 133.

Shared caching stays: one row per real flight, boards cached 5 minutes behind a refresh lease, route
searches 10 minutes, positions 2 minutes.

## Recommendation

1. Keep AeroAPI Standard for production, as GOAL.md says. Polling at four points cannot meet the
   goal's "within about a minute of the provider alert, with no per-user polling": a gate change
   between two polls reaches the phone up to hours late. The free layer is a fallback and a test bed.
2. If the owner wants to avoid the $100 minimum anyway, the cheapest compliant setup found is
   FlightLabs Starter ($24.99, about 23 followed flights a day) or Aviationstack Basic ($49.99,
   about 58), with `POSITION_PROVIDER` on the same provider or `none`, never OpenSky or ADS-B
   Exchange without their written licence.
3. Free keys are fine on a local stack to test the adapters, never in the App Store build's backend.
4. Before any switch, fetch one real answer from the chosen provider, replace the `*_built.json`
   fixture with it, and settle the Aviationstack time question.

## Test fixtures

`supabase/functions/_shared/fixtures/providers/`:

- Real answers: `opensky_states_bbox_ksfo_20261031.json` and
  `opensky_states_icao24_c0130c_20261031.json` (anonymous `GET /api/states/all`, 2026-10-31).
- Documentation example, verbatim: `aviationstack_flights_doc.json` (the `/v1/flights` example).
- Built by us from the documented field lists, because the provider has no anonymous access or
  published sample: every `*_built.json` (Aviationstack AF84, FlightLabs timetable, `/flight` and live
  feed, OpenSky `/flights/aircraft`). Replace them with real answers once a key exists.
