# Soma Flight on Apple Watch

Soma Flight has an Apple Watch app (watchOS 26 or later) that shows My Flights and each followed flight's screen, with complications for the next flight on the watch face and in the Smart Stack. It gets everything from the iPhone over WatchConnectivity and keeps the last snapshot on the watch, so it works offline; the watch itself never calls the network.

## What it shows

**My Flights**: the followed flights in the widgets' order, in the air first, then by departure. Landed flights leave an hour after arrival.

**A flight's screen** (`Packages/FlightKit/Sources/FlightWatchKit/WatchFlightDetail.swift`):

- the flight number and a big status: "On Time", "25m Late", "In the Air", "Landed", "Canceled", coloured by delay;
- the countdown in words: "Departs in 5 hrs", "Arrives in 2h", "Departing", "Landed";
- both airports with their times;
- what you look for now: the departure gate, terminal and seat before takeoff; the arrival gate, terminal and baggage belt after;
- progress while in the air;
- the boarding pass, when one is kept with the flight.

The wording comes from the same code as the iPhone widgets and the Live Activity, so all three say the same thing.

**"Updated 12 min ago"**: when the phone wrote the snapshot, so you know how fresh it is.

## Complications

Rectangular, circular, corner and inline families (`Apps/WatchWidgets/WatchComplications.swift`). Tapping one opens its flight (`somaflight://flight/<id>`).

Smart Stack relevance rises from four hours before the next departure, peaks from an hour before it until half an hour after arrival, and stays in between while in the air. The timeline has an entry at each of those steps, and the watch reloads the complications when the phone sends a new snapshot.

## How it syncs

1. The iPhone app sends a snapshot of the followed flights over WatchConnectivity.
2. The watch keeps it in its App Group (`WatchFlightsModel`), redraws the complications if what they show changed, and shows "Updated ..." from the snapshot's time.
3. With no phone nearby and no network, the app and complications keep showing the last snapshot.

The watch app links `FlightWatchKit` and `FlightActivityKit` only: no Supabase client, no account on the watch.

## Install

The watch app is embedded in the iPhone app (the `SomaFlight-iOS` target depends on `SomaFlightWatch` in `project.yml`). Install Soma Flight on the iPhone (the [TestFlight public beta](https://testflight.apple.com/join/RWVpDdDF) for now), then install the watch app from the Watch app on the iPhone if it does not install automatically. To build it yourself, run the `SomaFlightWatch` target from the Xcode project; see [Build from source](build-from-source.md).

## Related

- [How to track a flight](track-a-flight.md)
- [Where is my flight when there is no connection?](offline-flight-position.md)
- [README](../../README.md)
