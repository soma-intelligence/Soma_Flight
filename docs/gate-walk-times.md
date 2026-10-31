# Gate walk times

Soma Flight adds the walk from the security checkpoint to the departure gate to a computed "Leave by" time, and shows it on the flight sheet ("About 12m walk to gate B32"). Code: `Packages/FlightKit/Sources/FlightKit/Reminders/GateWalk.swift`. Tests: `GateWalkTests.swift`.

## What the figure is

Typical minutes for an adult with a cabin bag, from the main checkpoint to the middle of the concourse, including any train or tram ride and its wait. It is not the farthest gate and not a door-to-door time. The leave time already holds a separate bag drop margin and the security queue.

## How it is chosen

1. The gate's concourse, read from the gate name ("B32" is concourse B, "E10A" concourse E). When a concourse letter exists in several terminals (JFK B in T4 and T8), the flight's terminal decides; without a terminal the longest walk wins, so nobody leaves late.
2. A numbered gate inside a known range (LAX West Gates 200 to 299, DCA 46 to 59, MCO airsides).
3. The flight's terminal ("Terminal 1", "T1" and "1" are the same).
4. The airport's typical figure.
5. Airports outside the table: 10 minutes at a large airport, 6 at a medium one, 3 at a small one. Sizes are OurAirports' own types, bundled as `Resources/Reference/airport_sizes.json` by `Packages/FlightKit/Scripts/build_airport_sizes.py` from `supabase/seed/airports.csv`.

## The table

The 40 busiest US airports by FAA CY2023 enplanements: ATL, DFW, DEN, ORD, LAX, JFK, LAS, MCO, MIA, CLT, SEA, PHX, EWR, SFO, IAH, BOS, FLL, MSP, LGA, DTW, PHL, SLC, BWI, DCA, SAN, IAD, TPA, BNA, AUS, MDW, HNL, DAL, PDX, STL, RDU, HOU, SMF, MSY, SJC, SNA.

Method: distances measured on each airport's published terminal map from the main checkpoint to the middle of each concourse, at about 70 m a minute (a walk with a cabin bag, slower than the 80 m a minute of an unladen adult), rounded to the minute, plus about 2 minutes a stop for a train (ATL Plane Train, DEN, IAD AeroTrain, SEA SEA Underground, LAS tram to D). These are estimates, not measurements, and airports rebuild often. They aim to be right to within a few minutes; the leave time already rounds generously elsewhere.

Known soft spots, to check against the real maps before launch:

- ATL: the international terminal has its own checkpoint, closer to E and F than the figures (which start at the domestic terminal).
- LGA and SAN rebuilt their terminals in 2022 to 2025; gate numbering may have moved.
- DTW and RDU terminal names vary between "McNamara"/"Evans" and numbers in the provider's data.
- JFK's New Terminal One opens in 2026; its figure is a placeholder at 7 minutes.

To change a figure, edit `GateWalkTable.entries` and its test; the tests check that the table holds 40 airports once each and that every figure is between 2 and 25 minutes.
