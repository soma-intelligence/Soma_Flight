# Where is my flight when there is no connection?

Soma Flight estimates a flight's position on the device when it cannot hear about the flight: the phone is offline, or the flight is in the air and its last update is more than 5 minutes old (airline Wi-Fi that only lets messages through). The estimate places the plane on the great circle between the two airports using the best departure and arrival times and a climb, cruise and descent profile, shows the phase of flight, and is always labelled as an estimate with the time of the last real update.

## What the app keeps before you board

From 24 hours before departure until 3 hours after arrival, the flight sheet saves an offline pack for the flight in the account's on-device cache (`Packages/FlightKit/Sources/FlightKit/Models/OfflineFlightPack.swift`):

- the flight as last heard (times, gates, status);
- both airports, with coordinates and time zones;
- the aircraft type, for its cruise speed;
- the route as 129 points on the great circle (about 70 km apart on a long haul).

Region names along the way and the sun's position come from tables bundled in the app, so nothing else is needed. Up to 20 packs are kept, newest first, and they are wiped with the cache at sign-out.

## How the estimate works

`FlightEstimate` (`Models/FlightEstimate.swift`) runs when:

| Reason | Condition |
|---|---|
| Offline | The device has no connection and the flight is in the air or due to be |
| Stale | The device is online but the flight in the air has had no update for 5 minutes |

It gives:

- **Progress**, 0 to 100% of the trip, as the share of the best gate-to-gate time elapsed (the same rule the Live Activity uses);
- **Coordinate and heading** on the great circle at that progress, from `RouteEstimator` (runway times, climb, cruise, descent);
- **Phase** of flight;
- **Probably landed** when the best arrival time has passed with no landing heard;
- **Last update**, the time of the last real data.

No estimate is shown for a flight that has landed, arrived, been canceled or diverted, or one that is online and fresh. The app then shows what it has.

## What it cannot know

The estimate follows the great circle. Real routes bend around weather, airspace and tracks, and a hold or a diversion after the last update is not seen. It is a best guess with its age printed next to it.

## Apple Watch

The Watch app keeps the last snapshot the iPhone sent in its App Group, so it and its complications also work with no connection. See [Apple Watch app](apple-watch-app.md).

## Related

- [How to track a flight](track-a-flight.md)
- [Apple Watch app](apple-watch-app.md)
- [README](../../README.md)
