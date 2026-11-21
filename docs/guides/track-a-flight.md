# How to track a flight by flight number or route

In Soma Flight, type a flight number ("AF 84", "AF84", "air france 84"), a route ("SFO AUS") or an airport into Search, pick the day, and tap Follow. The flight then updates on its own: times, gates, terminals, delays, baggage belt and status, with push alerts, a Live Activity on the Lock Screen and the next flight in the widgets and on the Apple Watch.

## Steps

1. Open **Search** (or run the "Find a Flight" Shortcut).
2. Type one of:
   - a flight number, with or without a space: `AF 84`, `AF84`;
   - an airline name and number: `air france 84`;
   - a route as two airport codes: `SFO AUS`, `LHR JFK`;
   - an airport code, which opens that airport's departures and arrivals board.
3. Pick the day. Lookups reach from 10 days back to 2 days ahead, in the origin airport's local date.
4. Tap the flight, then **Follow**. Each alert category can be switched on or off in Settings > Notifications.

A flight number search also returns the same flight number on the day before and after (local at the origin), so a flight that left New York late on the 29th and is still in the air on the 30th in Paris is found. A route search returns the flights leaving that day.

## What you see once you follow it

| Place | What it shows |
|---|---|
| My Flights | Every followed flight, in the air first, then by departure. Landed flights leave an hour after arrival and move to [Passport](flight-passport-stats.md). |
| Flight sheet | Scheduled, estimated and actual times for gate out, takeoff, landing and gate in; gates, terminals, belt; aircraft type and registration when the provider sends them; the live position while in the air; the "Leave by" time; a connection card when you follow the next leg. |
| Live Activity | Countdown to departure, time left in the air, arrival gate. On the Lock Screen and in the Dynamic Island. |
| Widgets | The next flight on the Home Screen. |
| Apple Watch | My Flights and the flight's screen, with complications. See [Apple Watch app](apple-watch-app.md). |
| Siri and Shortcuts | "Next Flight Status", "Flight Status", "Open Flight", "Open Next Flight", "Find a Flight". |

## How updates reach the phone

With the default provider (FlightAware AeroAPI), following a flight registers a provider alert. The provider calls the backend's `aeroapi-webhook`; one SQL transaction merges the change into the shared `flights` row and writes a `flight_events` row, then `push-sender` sends the alert and the Live Activity update. There is no per-user polling. A merged flight never moves backwards: actual times are set once and the status only rises. While the flight sheet is open in the air, `flight-position` refreshes the live position at most once every 2 minutes per flight, shared by every follower.

The endpoints are documented in the [API contract](../api-contract.md) (`flight-lookup`, `follow-flight`, `flight-position`).

## Without an account or a server

Debug builds run on fakes with the launch argument `-useFakes YES`, so you can try every screen on a simulator with demo flights and no key. See [Build from source](build-from-source.md).

## Related

- [Which flight alerts Soma Flight sends](flight-alerts.md)
- [When to leave for the airport](leave-for-the-airport.md)
- [Where is my flight when there is no connection?](offline-flight-position.md)
- [Flight data providers](flight-data-providers.md)
- [README](../../README.md)
