# Data sources

Reference data that ships in the repo, where it comes from, under which licence, and when it was retrieved.
No dataset here is share-alike.

## Airports

- File: `supabase/seed/airports.csv`, generated into `supabase/migrations/20261028000002_airports_seed.sql`
  by `supabase/scripts/build_airports_seed.ts`.
- Source: OurAirports, https://ourairports.com/data/ (`airports.csv`).
- Licence: public domain.
- Time zones are derived from the coordinates with geo-tz (MIT).

## Airlines

- File: `supabase/seed/airlines.csv` (138 rows), generated into `supabase/migrations/20261030000003_reference_seed.sql`
  and `Packages/FlightKit/Sources/FlightKit/Resources/Reference/airlines.json` by
  `supabase/scripts/build_reference_seed.ts`.
- Retrieved: 2026-10-29.
- ICAO code, IATA code, callsign (property P432), official website (P856) and country (P17, then the
  headquarters country P159): Wikidata, https://query.wikidata.org/sparql. Licence CC0.
  The candidate list is ours (history, fakes, the three alliances, the large carriers); Wikidata fills the
  facts. Where several items share an ICAO code the one with the matching IATA code and the most sitelinks wins.
  The query is the one built by the retrieval script: a `VALUES ?icao { ... }` list over
  `?a wdt:P230 ?icao` with `OPTIONAL` blocks for P229, P432, P856, P17, P159, and
  `FILTER NOT EXISTS { ?a wdt:P576 ?d }` (not dissolved).
- Not on Wikidata, so entered by hand from public knowledge (codes and website only): `KAL` Korean Air,
  `ARG` Aerolineas Argentinas. `NKS` Spirit Airlines is dissolved on Wikidata (2026-05-02) and is kept because
  it appears in the fake data and in past flights.
- Alliance: our assignment of full members of Star Alliance, oneworld and SkyTeam, checked against the current
  membership statements (P114 without an end time) on Wikidata. We differ from Wikidata on purpose for regional
  affiliates (left empty), Copa (Star Alliance only), Vueling and Eurowings (not members) and Aeroflot (SkyTeam
  membership suspended since 2022).
- Colours: `color_primary` is a seed colour set from the airline's brand as we know it, not read from a
  file. Rows start with `colors_source = 'seed'`; Task 8 replaces them from the provider's brand colours.
  `UAL`, `AFR` and `RYR` are written with `colors_source = 'locked'` (livery seed of Task 12).
- Phone: left empty for every airline, no reliable machine readable source on the airlines' own sites.
- X and Facebook handles: read from links on the airline's own homepage on 2026-10-29, kept only when the
  handle clearly belongs to that airline; empty otherwise.

## Aircraft types

- File: `supabase/seed/aircraft_types.csv` (91 rows).
- Source: our own list of ICAO type designators (ICAO Doc 8643 designators are public identifiers), with our
  own family grouping and marketing names. It covers `TravelFacts.aircraftNames` and the types in the fakes.
- Licence: ours.

## Country regions

- File: `supabase/seed/country_regions.csv` (250 rows): the 249 ISO 3166-1 alpha-2 codes plus `XK` (Kosovo).
- Country names: Wikidata labels (CC0, ISO 3166-1 alpha-2 codes by property P297, retrieved 2026-10-29),
  shortened by hand for common usage.
- Regions: our assignment from the UN M49 geoscheme subregions (https://unstats.un.org/unsd/methodology/m49/),
  which is public information. Middle East = Western Asia plus Egypt. Central America = M49 Central America
  including Mexico. M49 has no region for Antarctica, which we place in `oceania` (the gateways are
  in Oceania).

## Not used: OpenFlights

OpenFlights (airlines.dat, planes.dat, airports.dat) is licensed under the Open Database License (ODbL),
which is share-alike: a database built from it would have to be published under the ODbL too. We use
OurAirports (public domain) and Wikidata (CC0) instead, and write nothing derived from OpenFlights.
