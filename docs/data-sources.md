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
- Historical rows kept on purpose: `NKS` (see above) and `ASQ` ExpressJet (ceased operating in 2020), which can
  still appear in older flight data. `TWB` is T'way Air, rebranded Trinity Airways; its callsign `SONOROUS`
  comes from Wikidata and is unverified.
- Alliance: our assignment of full members of Star Alliance, oneworld and SkyTeam, checked against the current
  membership statements (P114 without an end time) on Wikidata. We differ from Wikidata on purpose for regional
  affiliates (left empty), Copa (Star Alliance only), Vueling and Eurowings (not members) and Aeroflot (SkyTeam
  membership suspended since 2022).
  Rechecked 2026-10-29 for Hawaiian, Asiana and ITA. Hawaiian (`HAL`): the oneworld members page
  (https://www.oneworld.com/members, fetched that day) lists Alaska but not Hawaiian, so the row has no
  alliance; Wikidata and some press say otherwise. Asiana (`AAR`): still Star Alliance today; trade press
  (ch-aviation, Milesopedia, Oct 2026) reports it leaves on 2026-12-16 at 23:59 KST ahead of the Korean Air
  merger, so the row is `star_alliance` for now and must be emptied or moved after that date. ITA Airways
  (`ITY`): Star Alliance full member since 2026-04-01 (trade press: LoyaltyLobby, One Mile at a Time). The
  alliance sites themselves answered 403 to our fetch, so these two are not primary-source checks.
- Colours: `color_primary` is a seed colour typed from memory of the airline's brand. No airline site was
  read for colours. Rows start with `colors_source = 'seed'`; Task 8 replaces them from the provider's brand colours.
  `UAL`, `AFR` and `RYR` are written with `colors_source = 'locked'` (livery seed of Task 12).
- Phone: left empty for every airline, no reliable machine readable source on the airlines' own sites.
- X and Facebook handles: read from links on the airline's own homepage on 2026-10-29, kept only when the
  handle clearly belongs to that airline; empty otherwise.

## Aircraft types

- File: `supabase/seed/aircraft_types.csv` (91 rows).
- Source: our own list of ICAO type designators (ICAO Doc 8643 designators are public identifiers), with our
  own family grouping and marketing names. It covers `TravelFacts.aircraftNames` and the types in the fakes.
- Licence: ours.
- `A220` is not an ICAO designator (`BCS1` and `BCS3` are). It stays because the fake data and
  `TravelFacts.aircraftNames` use it.

## Country regions

- File: `supabase/seed/country_regions.csv` (250 rows): the 249 ISO 3166-1 alpha-2 codes plus `XK` (Kosovo).
- Country names: Wikidata labels (CC0, ISO 3166-1 alpha-2 codes by property P297, retrieved 2026-10-29),
  language tags stripped and shortened by hand to common English names (China, South Korea, Russia, Vietnam, Türkiye, ...). The generator rejects names containing `@` or longer than 40 characters.
- Regions: our assignment from the UN M49 geoscheme subregions (https://unstats.un.org/unsd/methodology/m49/),
  which is public information. Middle East = Western Asia plus Egypt. Central America = M49 Central America
  including Mexico. M49 has no region for Antarctica, which we place in `oceania` (the gateways are
  in Oceania).

## Not used: OpenFlights

OpenFlights (airlines.dat, planes.dat, airports.dat) is licensed under the Open Database License (ODbL),
which is share-alike: a database built from it would have to be published under the ODbL too. We use
OurAirports (public domain) and Wikidata (CC0) instead, and write nothing derived from OpenFlights.

## World land outline (Passport map)

- File: `Packages/FlightKit/Sources/FlightKit/Resources/Reference/world_land.json` (127 rings, 3,503 points,
  about 45 KB), generated by `python3 -I Scripts/world/build_land.py ne_110m_land.geojson <out>`.
- Source: Natural Earth 1:110m physical vectors, land (`ne_110m_land`), https://www.naturalearthdata.com,
  read from its official GitHub mirror
  https://github.com/nvkelso/natural-earth-vector/blob/master/geojson/ne_110m_land.geojson
  (SHA-256 `9e0729ee253ca7d7a5c4ae9395fb1902264c5377c52e224d13dd85010e2835d9`).
- Retrieved: 2026-10-29.
- Licence: public domain (Natural Earth terms of use). No attribution required; credited here anyway.
- Processing: every ring simplified with Douglas-Peucker at 0.15 degrees, coordinates rounded to 2 decimals,
  rings under 4 points dropped. The app draws it flat (equirectangular, standard parallel 40 degrees) and
  cuts Antarctica and the far north.
