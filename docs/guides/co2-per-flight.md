# How to see the CO2 of a flight in Soma Flight

Soma Flight estimates each flight's greenhouse gas emissions for one passenger, in kg CO2e, and totals them in Passport. The estimate is the great circle distance between the two airports times a UK government (DESNZ 2025) conversion factor per passenger.km, chosen by haul and seat class, with radiative forcing included. It runs on the phone from a small table of published factors: nothing is sent anywhere, and no offset is sold or suggested.

## Where to find it

- **Flight sheet**: one row with the flight's CO2e and the seat class it is for (`UI/Detail/EmissionsCard.swift`).
- **Passport**: the CO2 emissions section totals your flights, "for one passenger, in the seat class you noted (economy when none), non-CO2 effects included".

## The formula

```
kg CO2e = great circle distance (km) x factor (kg CO2e per passenger.km)
```

| Haul | Rule | Economy | Premium economy | Business | First |
|---|---|---|---|---|---|
| Domestic (UK) | both airports in the UK | 0.22928 | 0.22928 | 0.22928 | 0.22928 |
| Short-haul | any other flight under 3,700 km | 0.12576 | 0.12576 | 0.18863 | 0.18863 |
| Long-haul | 3,700 km or more | 0.11704 | 0.18726 | 0.33940 | 0.46814 |

Factors are DESNZ 2025 "Business travel, air", With RF. The 8% routing uplift is already inside the published factors, so the app does not add it again.

## Worked examples

| Flight | Distance | Class | Estimate |
|---|---|---|---|
| Paris CDG to Rome FCO | 1,105 km | Economy | 139 kg |
| London LHR to Edinburgh | 534 km | Any | 122 kg |
| San Francisco to Paris CDG | 8,950 km | Business | 3.0 t |

## Rules worth knowing

- **Unknown class** counts as economy.
- **Private flights** get no figure: DESNZ has no factor for them.
- **Canceled flights** are not counted.
- **Radiative forcing** (contrails, water vapour, NOx) is included through DESNZ's 1.7 multiplier on the CO2 part. The multiplier is uncertain, and the app says so.

## What it leaves out

It is an average for the haul and class. The aircraft type, the airline, the load factor on the day and the route actually flown are left out.

The full method, sources and paragraph references: [How Soma Flight estimates a flight's CO2](../co2-method.md). The code is `Packages/FlightKit/Sources/FlightKit/Models/FlightEmissions.swift`, and its tests check it against the table.

## Related

- [Flight passport and lifetime stats](flight-passport-stats.md)
- [How to import past flights](import-past-flights.md)
- [README](../../README.md)
