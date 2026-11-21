# How to count Schengen 90/180 days with Soma Flight

Soma Flight counts the days you spent in the Schengen area over the last 180 days from the flights in your Passport, and says how many of the 90 allowed days are left and the last day you may stay. Open Settings > Travel Tools > Schengen 90/180. The count reads flights only, so a crossing by land or sea is not seen; treat it as a planning aid and check official sources before you travel.

## The rule it applies

The short-stay rule for visitors: at most 90 days in any 180-day period (Regulation (EU) 2016/399, article 6).

- Every day in the area counts, the day of entry and the day of exit included.
- The 180 days are the ones ending on the day being checked.
- Days are local calendar dates at the airports.

## How stays are read from flights

Code: `Packages/FlightKit/Sources/FlightKit/Models/Schengen.swift`, tests in `SchengenTests.swift`.

| Flight | Effect |
|---|---|
| From outside into the area | A stay starts on the arrival date at the destination |
| From the area to outside | The stay ends on the departure date at the origin |
| Inside the area, no stay open | A stay starts on that departure date (you came in by land) |
| Out of the area, no stay open | Counts the departure day alone |
| Canceled | Ignored |

## Which countries count

The 29 states that apply the rule, from the bundled `connection_rules.json`, with Bulgaria and Romania included since 1 January 2025. Ireland and Cyprus are not in it. Monaco, San Marino and the Vatican have no border with the area and count as inside; Andorra does not. Svalbard (ENSB) is Norwegian but outside the area.

## What the screen shows

- Days used in the current 180-day window and days remaining.
- Whether you are inside the area now (the last flight went in and none came out).
- The last day you may stay (or arrive and stay) without passing 90 days in any window, or a note when the limit is already passed.
- Your stays, entry to exit.

## Limits

- Trips by train, car or ferry are not seen. Between a flight into the area and the next flight out, the count assumes you stayed inside.
- It is not a legal or immigration tool. Your passport stamps and the official EU short-stay calculator decide.

## Related

- [Flight passport and lifetime stats](flight-passport-stats.md)
- [How to import past flights](import-past-flights.md)
- [README](../../README.md)
