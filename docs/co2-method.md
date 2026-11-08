# How Soma Flight estimates a flight's CO2

Soma Flight shows an estimate of the greenhouse gas emissions of each flight, for one passenger, and the total for the flights in Passport. This page is the whole method. It runs on the phone from a small table of published factors: nothing is sent anywhere, and no offset is sold or suggested.

## Source

UK Government GHG Conversion Factors for Company Reporting, 2025 edition, published by the Department for Energy Security and Net Zero (DESNZ) in June 2025.

- Publication: https://www.gov.uk/government/publications/greenhouse-gas-reporting-conversion-factors-2025
- Table: "Business travel- air", passenger flights, unit `passenger.km`, `kg CO2e`, **With RF** (flat file IDs `21_316_3160` to `21_316_3177`).
- Method: "2025 Government greenhouse gas conversion factors for company reporting: Methodology paper", section 8 (aviation), paragraphs 8.9 (short and long haul), 8.38 and 8.39 (distance uplift), 8.40 to 8.44 (radiative forcing).

## The formula

```
kg CO2e = great circle distance (km) x factor (kg CO2e per passenger.km)
```

- **Distance**: the great circle distance between the two airports, from their coordinates.
- **Routing uplift (8%)**: DESNZ adds 8% to the great circle distance for indirect routes, delays and circling. That uplift is **already inside** the published factors (methodology paragraph 8.39: "applied already to the conversion factors"), so the app does not add it a second time. Multiplying the plain great circle distance by the factor gives the uplifted result.
- **Radiative forcing: included.** Flying warms the climate through more than its CO2 (contrails, water vapour, NOx). DESNZ publishes factors with and without this effect; the "With RF" factors apply a 1.7 multiplier to the CO2 part, its central estimate (methodology paragraph 8.43, after Lee et al., 2021). We use **With RF** because it is closer to a flight's full climate effect. The figure is labelled "CO2e" and says that non-CO2 effects are included. The multiplier is uncertain; DESNZ says so, and so do we.
- **Per passenger**: the factors spread a flight's emissions over its passengers by seat class (a business seat takes more cabin floor than an economy one) and leave out the share for cargo.

## Haul

| Haul | Rule | DESNZ rows used |
|---|---|---|
| Domestic | both airports in the United Kingdom | "Domestic, to/from UK" |
| Short-haul | any other flight under 3,700 km | "Short-haul, to/from UK" |
| Long-haul | any other flight of 3,700 km or more | "Long-haul, to/from UK" |

DESNZ now prefers sorting UK flights by destination region, and once used the 3,700 km cut (the range of a Boeing 737, methodology paragraph 8.9). Soma Flight tracks flights everywhere, so it uses the distance rule. The UK short-haul and long-haul rows are the only DESNZ rows with a split by haul and class, so they stand in for flights between any two countries. The "Domestic, to/from UK" factor is for the UK's short domestic network (434 km on average); it is not used for domestic flights elsewhere, which go by distance.

## Factors (kg CO2e per passenger.km, With RF, 2025)

| Seat class | Domestic (UK) | Short-haul | Long-haul |
|---|---|---|---|
| Economy | 0.22928 | 0.12576 | 0.11704 |
| Premium economy | 0.22928 | 0.12576 (economy) | 0.18726 |
| Business | 0.22928 | 0.18863 | 0.33940 |
| First | 0.22928 | 0.18863 (business) | 0.46814 |

- **Domestic** has one factor for every class ("Average passenger"): DESNZ gives no split.
- **Short-haul** has economy and business rows only. Premium economy counts as economy and first as business.
- **Unknown class**: economy, the most common seat.
- **Private flights**: no figure. DESNZ has no factor for them and we do not guess one.
- **Canceled flights**: not counted.

## Examples

| Flight | Distance | Class | Factor | Estimate |
|---|---|---|---|---|
| Paris CDG to Rome FCO | 1,105 km | Economy | 0.12576 | 139 kg |
| London LHR to Edinburgh | 534 km | Any | 0.22928 | 122 kg |
| San Francisco to Paris CDG | 8,950 km | Business | 0.33940 | 3.0 t |

## What the estimate leaves out

It is an average for the haul and class, not for the aircraft type, the airline, the load factor on the day or the actual route flown. A new long-haul twin on a full flight emits less than the average; an old aircraft on a half-empty one emits more. Each new DESNZ edition (every June) can be dropped into `Packages/FlightKit/Sources/FlightKit/Models/FlightEmissions.swift`; the tests check the code against the table above.
