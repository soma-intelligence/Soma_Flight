# Airport weather, METAR and FAA status in Soma Flight

Soma Flight shows each airport's current weather in plain words ("Partly cloudy with light winds.") from its latest METAR, the flight category (VFR, MVFR, IFR, LIFR), the TAF forecast when the airport has one, and, for US airports, FAA ground stops, ground delay programs, delays and closures. Weather comes free from NOAA's aviationweather.gov and US programs from the FAA's NAS status feed, so none of it needs a paid flight data plan.

## Where it shows

- **Airports card** (the round button under the map controls): your airports and the big hubs, each with a status dot and line, and a dot per airport on the globe.
- **Airport card**: a status card, weather and forecast, FAA programs and NOTAMs, Runway Regulars, your history at the airport.
- **Flight sheet**, Good to Know: per airport, the weather in a few words ("18°C and scattered clouds"), a disruption row when delays build (saying whether the weather is the cause) and the FAA programs.

## What is free and what needs a paid plan

| Part | Source | Needs |
|---|---|---|
| Name, codes, city, country, local time | Bundled reference data (OurAirports) | Nothing |
| Current weather, flight category | NOAA METAR, aviationweather.gov | Nothing |
| Terminal forecast (TAF) | aviationweather.gov | Nothing |
| Ground stops, ground delay programs, closures (US) | FAA NAS status | Nothing |
| NOTAMs | FAA NOTAM API | A free FAA developer key (`FAA_NOTAM_CLIENT_ID`, `FAA_NOTAM_CLIENT_SECRET`) |
| Inferred disruption outside the US | Rules over NOTAMs, METAR and TAF, labelled "inferred" | Nothing |
| On-time share, delay trend, day's traffic, departures and arrivals boards | A board provider | A paid plan (`BOARD_PROVIDER`) |

Without a board provider the app says so in one line ("Live airport stats need a data plan") and never invents numbers. Details: [Airports](../airports.md).

## How the weather is fetched

`airport-weather` asks aviationweather.gov for up to 40 airports in one batch request, caches each METAR for 10 minutes and serves a stale one for up to an hour when NOAA fails. With `forecast=1` it adds each airport's TAF, decoded into periods (`FM`, `BECMG`, `TEMPO`, `PROB`) with a plain-words summary ("Light rain, wind 12 kt gusting 25 kt, visibility 3 mi, cloud base 800 ft"). It is rate limited to 120 calls an hour per user.

```
GET /functions/v1/airport-weather?airports=SFO,JFK,LHR&forecast=1
Authorization: Bearer <user JWT>
```

The airport sheet reads the raw METAR and TAF too (`airport-board?kind=weather`), with temperature, wind, gusts, visibility, ceiling and category. Shapes are in the [API contract](../api-contract.md#airport-weather-airport-stats-and-airport_regulars).

## Weather impact

The Rust core's `impact.rs` reads a METAR or TAF period and says whether the weather is likely slowing the airport, which side of the operation it hits and a short reason. `weather.rs` computes the FAA flight category from ceiling and visibility. The thresholds are rules of thumb from how airports run.

## Related

- [Which flight alerts Soma Flight sends](flight-alerts.md) (FAA program alerts)
- [Flight data providers and which are free](flight-data-providers.md)
- [Data sources](../data-sources.md)
- [README](../../README.md)
