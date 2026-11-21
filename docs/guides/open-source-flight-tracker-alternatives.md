# Open source alternatives to Flighty, Flightradar24, FlightAware, App in the Air and TripIt

Soma Flight is an open source (AGPL-3.0) flight tracker for iPhone, iPad, Mac and Apple Watch that follows your own flights live and keeps a log of every flight you take. Its whole stack is public, including the Supabase backend, so you can read how it works, change it and run your own server. It is a young project in public beta and has no affiliation with any of the apps below; this page lists neutral facts as of November 2026 to help you compare.

## At a glance

| | Soma Flight | Flighty | Flightradar24 | FlightAware | App in the Air | TripIt |
|---|---|---|---|---|---|---|
| Source code | Open, AGPL-3.0 | Closed | Closed | Closed | Closed | Closed |
| Self-hostable backend | Yes (Supabase) | No | No | No | No | No |
| Main job | Your flights: live status, alerts, flight log | Your flights: live status, alerts, flight log | Live map of air traffic | Flight tracking and aviation data | Travel assistant | Itinerary organiser |

Soma Flight's default flight data comes from FlightAware AeroAPI, a commercial API. Running your own backend with live data means paying for your own data plan; see [Flight data providers](flight-data-providers.md).

## If you use Flighty

Soma Flight covers the same kind of job (following your own flights and keeping a log) and reads the CSV file Flighty exports from its settings ("Export Flights"), so you can move your history over. Import maps its columns (date, airline, flight, airports, gate and runway times, tail, seat, cabin, reason, notes). See [How to import past flights](import-past-flights.md).

## If you use Flightradar24 or FlightAware

Those are built around tracking any aircraft on a live map. Soma Flight is built around the flights you follow: push alerts, a Live Activity, "Leave by" time, connections, and a log. It shows a followed flight's live position on its sheet, and a nearby radar exists in code but is off by default because it uses a paid area search.

## If you use App in the Air or TripIt

Soma Flight reads trips from a confirmation email you share with it (schema.org `FlightReservation` markup or the email's text and PDF) and from your calendar, then follows each upcoming flight. It does not manage hotels, cars or other bookings.

## What Soma Flight does differently

- **Open code under AGPL-3.0**: the apps, the Rust core, the web app and the backend. Airline logos and marks are excluded ([NOTICE](../../NOTICE)).
- **Self-hosting**: run the backend on your own Supabase project. See [Self-host the backend](self-host-supabase-backend.md).
- **Privacy**: no ads, no analytics SDK, no tracking. Imports are read on the device; location is used only for "Leave by" and never leaves the device.
- **Published methods**: the [CO2 method](../co2-method.md), the [Schengen rule](schengen-day-counter.md) and the [offline position estimate](offline-flight-position.md) are documented and tested.

## What it does not have (yet)

- No Android app.
- The App Store release (1.0) is pending; install through the TestFlight public beta.
- The web app is a first cut.
- Live airport stats (on-time share, delay trend, boards) and schedules days ahead need a paid data plan on the backend.

## Related

- [README](../../README.md)
- [How to import past flights](import-past-flights.md)
- [How to track a flight](track-a-flight.md)
- [Self-host the backend on Supabase](self-host-supabase-backend.md)
