# Flight passport and lifetime flight stats in Soma Flight

Passport is Soma Flight's log of every flight you have taken. A followed flight moves there on its own an hour after it reaches the gate, and you can add or import older ones. From that history the app shows a map of every route and lifetime stats: flights, distance, hours in the air, airports, airlines, aircraft, countries, delays and CO2e, plus a Year in Review and a printable route poster.

## How flights get into Passport

- **Automatically.** A pg_cron job, `archive-landed-flights`, runs every hour on the backend. Follows of flights that arrived, landed, were canceled or diverted more than an hour ago move to `past_flights`. The app hides them from My Flights at the same hour.
- **By hand.** Passport > Add Past Flight.
- **By import.** From another tracker's CSV, any CSV, your calendar or a confirmation email. See [How to import past flights](import-past-flights.md).

## What the stats show

The numbers are computed by the Rust core (`core/flightcore/src/passport.rs` and `passport_detail.rs`), so the app and the backend always agree. Canceled flights are excluded.

| Group | Figures |
|---|---|
| Totals | Flights, domestic and international, long haul (4,000 km or more), distance (with laps of the Earth and trips to the Moon and the Sun), flight time, time in the air and taxiing |
| Records | Shortest and longest flight by distance and by time |
| Calendar | Flights per year, per month, per weekday |
| Places | Airports by visits, countries, regions visited out of each region's total |
| Airlines and routes | Top airlines and routes, by flights and by distance |
| Aircraft | Types, manufacturers, tails (registrations), seat positions (window, middle, aisle), trip reasons, aircraft ages (`aircraft.rs`) |
| Delays | Delayed flights (arrived 15 minutes late or more), their mean delay, total time lost to delays |
| Climate | CO2e for one passenger per flight and in total, see [CO2 per flight](co2-per-flight.md) |

Years follow the local departure date at the origin airport.

## The map

Every route is drawn as its great circle on a flat world map (equirectangular, 83°N to 57°S), split at the antimeridian. The land outline is bundled (`world_land.json`, see [Data sources](../data-sources.md#world-land-outline-passport-map)).

## Year in Review and the route poster

In Settings > Travel Tools:

- **Year in Review**: cards for one year (distance, time in the air, where you went, the longest flight, time lost to delays, the favourite route and aircraft). Drawn on the phone and shared only when you share them.
- **Route poster**: the map of your routes as a PDF.

## Friends and Runway Regulars

Friends you choose to share your Passport with can see it. On an airport card, Runway Regulars lists you and those friends by flights through that airport (at most 10, last visit to the month).

## Related

- [How to import past flights](import-past-flights.md)
- [How to export your flight history](export-flight-history.md)
- [How to see the CO2 of a flight](co2-per-flight.md)
- [How to count Schengen 90/180 days](schengen-day-counter.md)
- [README](../../README.md)
