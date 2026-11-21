# Flight data providers for Soma Flight, and which are free

Soma Flight's backend gets live flight status from FlightAware AeroAPI by default, and also has adapters for Aviationstack, FlightLabs and OpenSky Network, picked with function secrets and no code change. Weather (NOAA aviationweather.gov) and US airport programs (FAA NAS status) are free. As checked on 2026-10-31, none of the free flight status tiers allows use in a public app run by a company, so the free adapters are for testing; production needs a paid plan, which for AeroAPI's alert webhooks means the Standard tier.

## Choosing a provider

Set these as Supabase function secrets (`supabase secrets set NAME=value`):

| Secret | Used by | Values |
|---|---|---|
| `STATUS_PROVIDER` | `flight-lookup`, `follow-flight`, `maintenance` | `aeroapi` (default), `aviationstack`, `flightlabs`, `none` |
| `BOARD_PROVIDER` | `airport-board` | `aeroapi` (default), `aviationstack`, `flightlabs`, `none` |
| `POSITION_PROVIDER` | `flight-position` | `aeroapi` (default), `aviationstack`, `flightlabs`, `opensky`, `none` |
| `AEROAPI_KEY` | every AeroAPI caller | your AeroAPI key |
| `AVIATIONSTACK_KEY`, `FLIGHTLABS_KEY` | provider callers | your keys |
| `OPENSKY_CLIENT_ID`, `OPENSKY_CLIENT_SECRET` | `flight-position` | optional; OpenSky also answers anonymously |

The adapters live in `supabase/functions/_shared/providers/` (selection in `select.ts`).

## AeroAPI versus the polling providers

- **AeroAPI** sends alert webhooks: the provider calls `aeroapi-webhook` when a followed flight changes, so the backend never polls. This is how alerts reach the phone within about a minute.
- **Any other status provider** has no webhook. Setting `STATUS_PROVIDER` to anything other than `aeroapi` turns on the polling refresh (`provider-poll` pg_cron job, every 5 minutes), which spends a share of each plan's allowance (`POLL_QUOTA_SHARE`, default 0.7) on four polls per flight, or eight with `POLL_POINTS=extended`.

## Free tiers and terms (checked 2026-10-31)

| Source | Gives | Free tier | Terms for a public app by a company |
|---|---|---|---|
| OpenSky Network | live positions | 400 credits a day anonymous, 4,000 with a free account | written licence required |
| ADS-B Exchange | live positions | none | commercial use needs an Enterprise licence (no adapter) |
| Aviationstack | status, schedules, gates, delays, some positions | 100 requests a month | free plan is personal and non-commercial |
| FlightLabs | status, timetables, gates, live feed | none (7 day trial, 50 requests) | free and trial use is personal and test only |
| FlightAware AeroAPI | everything, plus alert webhooks | Personal tier with up to $5 a month free usage; B2C use excluded | Standard tier allows B2C |

Providers change prices and terms. Recheck before any purchase. The full write-up with every source: [Free and freemium flight data providers](../free-providers.md) and [FlightAware AeroAPI pricing and terms](../provider-check.md).

## Always free in Soma Flight

| Data | Source |
|---|---|
| METAR, TAF | NOAA aviationweather.gov |
| Ground stops, ground delay programs, closures (US) | FAA NAS status |
| NOTAMs | FAA NOTAM API, with a free developer key |
| Security wait estimate (US) | TSA FOIA checkpoint throughput, processed into the database |
| Airports, airlines, aircraft types | Bundled seed data (OurAirports, Wikidata and others, see [Data sources](../data-sources.md)) |

## Keeping the bill bounded

Every AeroAPI request goes through a usage counter. When today's estimated spend plus the request would pass `AEROAPI_DAILY_CAP_USD` (default 50), the request is not sent and the caller gets `provider_unavailable`; cached answers keep being served. `usage-alert` can email the owner when spend nears the cap. See [Backend operations](../operations.md#daily-aeroapi-spend-cap).

## Running with no provider

Set the three providers to `none` (an unsupported value also selects `none`). No flight status provider is called, but weather, FAA status, Passport, import, export, CO2 and the Schengen count all keep working. For screens with demo data and no backend at all, run a Debug build with `-useFakes YES`.

## Related

- [Self-host the backend on Supabase](self-host-supabase-backend.md)
- [Airport weather, METAR and FAA status](airport-weather-metar.md)
- [How to track a flight](track-a-flight.md)
- [README](../../README.md)
