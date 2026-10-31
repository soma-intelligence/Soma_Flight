# Data sources

Reference data that ships in the repo, where it comes from, under which licence, and when it was retrieved.
No dataset here is share-alike. Three airline logo files are CC BY-SA (see Airline logos): the `OMA` and
`ROT` wordmarks, shipped unchanged or only scaled and rasterized, and the `KLM` crown symbol, which we cropped
(a tighter viewBox). The crop is an adaptation: it carries the same license (CC BY-SA 3.0), and Acknowledgements
shows its author, a link to the license deed, its source and "Modified: cropped". The other cropped symbols
all come from public domain files.

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

## Airline logos (Wikimedia Commons)

- Files: `assets/logos/commons/<ICAO>.svg` (as published on Commons) or `<ICAO>.png` (PNG sources, scaled to
  192 px on the longest side), `assets/logos/commons/png/<ICAO>.png` (every logo rendered at 192 px on the
  longest side, transparent), `assets/logos/commons/symbol/<ICAO>.svg|png` and `symbol/png/<ICAO>.png` (the
  airline's compact symbol mark, same rules), `manifest.json` (`logos` = wordmarks, kind `wordmark`; `symbols` =
  symbol marks, kind `symbol`, with `symbol_source`; per ICAO: file, sha256, Wikidata item, source page, licence
  short name and URL, author, credit, attribution text, retrieval date), `rejected.json` (every airline without a
  usable wordmark, with the reason) and `symbols-report.json` (every symbol candidate and its verdict). The app's
  credit list `Packages/FlightKit/Sources/FlightKit/Resources/Licenses/airline-logos.json` is written from the
  manifest (one entry per airline for the wordmark, a nested `symbol` credit when a symbol ships) and shown in
  Acknowledgements under "Airline logos (Wikimedia Commons)".
- Built by `python3 -I Scripts/logos/fetch_commons.py`; review sheets `docs/logos/library.png` (symbol and
  wordmark side by side, dark and light), `docs/logos/symbols-at-size.png` (every symbol at 24, 34 and 64 pt)
  and `docs/logos/crops-review.png` (the cropped symbols beside their source) by `python3 -I Scripts/logos/build_sheets.py` (which also draws `docs/logos/flags.png`, the 251 bundled flags).
- Retrieved: 2026-10-29.
- Method: for each of the 138 airlines in `supabase/seed/airlines.csv`, the Wikidata item with that ICAO airline
  code (P230) is chosen by the reference seed rule (not dissolved, matching IATA code, most sitelinks), and its
  logo image (P154) is looked up on the Commons API (`prop=imageinfo`, `extmetadata`). SVG is preferred over PNG;
  JPEG is not taken. Downloads are checked against the SHA-1 Commons reports and against the declared type, and
  are rendered only through an `<img>` element in headless Chromium. One request per second at most, with a
  descriptive User-Agent; every answer is cached so a rerun does not hit the network.
- Licences accepted: public domain (including PD-textlogo, too simple for copyright), CC0, CC BY and CC BY-SA.
  Anything else (non-free, fair use, NC or ND, unknown) is rejected and recorded.
- Counts: 109 accepted (102 SVG, 7 PNG): 107 public domain, 2 CC BY-SA (`OMA` Oman Air, CC BY-SA 4.0;
  `ROT` TAROM, CC BY-SA 3.0). 29 without a usable logo: 26 whose Wikidata item has no logo image (usually
  because the logo is non-free and lives only on a Wikipedia as fair use; `KAL` and `ARG` were found), 3 whose
  only logo is a JPEG (`ASH`, `MEA`, `RJA`). No file was rejected for its licence: Commons hosts free files only.
  Since the symbol pass, `AAL`'s wordmark is "American Airlines wordmark (2013).svg" (its item lists two logos;
  the "AA Symbol" now ships as its symbol).
- Symbols (Task 8c, same day): looked up in this order: Wikidata P8972 (small logo or icon), P2910 (icon), a P154
  logo named as a symbol, then the files of the airline's Commons category (P373 and its "logos" subcategories)
  whose names say symbol, tail, icon, emblem, crown and similar. Wikidata answers are taken as the airline's mark;
  a name match ships only when the script's reviewed table (`SYMBOL_REVIEW`) accepts that file as the mark of the
  airline's current branding. Nothing is cropped or edited. 6 symbols: `DLH` crane and `NOZ` avatar (P8972),
  `KAL` taegeuk (P2910), `AAL` flight symbol (P154, symbol-named), `DAL` widget and `KLM` crown (Commons
  category). Licences: 5 public domain, 1 CC BY-SA 3.0 (`KLM`, by 京市). Exception, later the same day: the `KLM`
  crown's viewBox was cropped to the crown (manifest `changes`; the source canvas is twice its width). That
  adaptation stays CC BY-SA 3.0, its credit carries `changes`, and Acknowledgements says "Modified: cropped" and
  links the license deed (as it does for every CC file). 103 airlines keep their wordmark only.
  Rejected candidates and why are in `symbols-report.json`. About 80 KB.
- Cropped symbols (Task 8d, same day, owner approved): where the symbol only exists inside the full logo, it is
  cut out of the stored Commons file by `python3 -I Scripts/logos/crop_symbols.py` (run at the end of
  `fetch_commons.py` too), following `assets/logos/commons/crops.json`. Method: crop only. For an SVG the spec
  names the elements that draw the symbol (index paths from the root, found with `--inspect ICAO`); every other
  drawn element (the wordmark) is removed, defs, styles and gradients stay, and the viewBox is set tight around
  what is left (exact Bezier extrema, transforms, clip paths, half the stroke width). Path data, colours and
  transforms are not touched: nothing is redrawn, recoloured, scaled or distorted. A PNG source would be cut by
  pixel box and refused under 192 px on its long side (no upscaling). The file is parsed as XML only (Python
  standard library, no external entities, nothing in it is run); each spec pins the source's sha256, so a changed
  source is refused until looked at again; the output is byte-identical on a rerun. Manifest entries: kind
  `symbol`, `method: "crop"`, `derived_from` (the stored source file), `crop` (the kept index paths), licence,
  author, source page and Commons metadata inherited from the source logo, attribution = the source's plus
  ", cropped to the symbol". The app's credit list gives such a symbol `method` and `derived_from`; a CC BY or
  CC BY-SA source would keep its licence and attribution (none of the 31 is: all public domain). 31 cropped:
  `AAR` `ACA` `AEE` `AFR` `AHY` `AIC` `ANZ` `BEL` `CTN` `DAH` `EIN` `IBE` `ICE` `KQA` `LAN` `LGL` `MXY` `PAL` `SAA`
  `SWA` `SWR` `SXS` `THY` `TOM` `TRA` `TSC` `TVF` `TWB` `VOI` `VXP` `WJA`. 11 not cropped, reasons in
  `crops.json` (`skipped`): the symbol is one path with the letters (`AUA`, `CPA`, `ETH`, `EWG`, `MSR`, `RAM`),
  the stored PNG is 192 px wide so the crop would be under 192 px (`CEB`, `KZR`, `OMA`, `RWD`), no symbol in the
  logo (`UAL`). Review sheet: `docs/logos/crops-review.png` (source logo, symbol at 64 and 24 pt, dark and
  light). About 0.4 MB. 37 airlines now have a symbol.
- Size: about 2.3 MB for `assets/logos` with the crops.
- Use: `LOGO_PROVIDER=commons` makes `brand-assets-sync` load this library into the private `brand-assets`
  bucket (`supabase/functions/_shared/brand/commons.ts`), from `COMMONS_LOGO_BASE` when set (an http URL
  serving this folder, since the edge runtime cannot read the repo), else the repo copy. Kind `logo` is the
  symbol when there is one, else the wordmark; kind `wordmark` (provider only, not yet a sync kind) is the
  wordmark for wide slots. No dark variant, no tail, no brand colours.
- Trademark: a copyright licence (or public domain status) does not grant trademark rights. Airline names and
  logos remain the airlines' trademarks, and 104 of the files carry the Commons "trademarked" notice. The Airhex
  licence replaces this library once signed; until then the legal note of the v1.1 spec (section 4) applies.

## Security wait times

Checked on 2026-10-30 for the `security-wait` function. A public app with no paid contract may only use
sources that are public and whose terms allow reuse.

- TSA MyTSA web service (`apps.tsa.dhs.gov/MyTSAWebService/GetConfirmedWaitTimes.ashx`,
  `GetTSOWaitTimes.ashx`, `GetAirportCheckpoints.ashx`): every endpoint answered HTTP 302 to
  `http://www.tsa.gov/` on 2026-10-30. The DHS page that documents it (dhs.gov/mytsa-api-documentation) is
  still up, but the service is gone; the wait times now live only inside the MyTSA app. Not used.
- Airports' own live waits: several large US airports show checkpoint waits on their websites (JFK, EWR and
  LGA through the Port Authority, and others), fed by queue sensors. None publishes them as an open API, and
  the sites are "all rights reserved" (for example the Port Authority's notices). The JSON behind those pages is
  an internal backend, not offered for reuse, so it is not used. ACI publishes a standard for checkpoint wait
  APIs (airportscouncil.org) and Swedavia and Copenhagen run documented ones, but none of those covers a US
  airport. An airport that grants written permission can be added as a live provider (`LIVE_PROVIDERS` in
  `supabase/functions/security-wait/handler.ts`).
- Paid APIs, noted only, not used: FlightQueue (flightqueue.com/developers) Pro API $99 a month for 5,000 calls
  then $3 per 1,000, Enterprise $499 a month for 100,000 calls then $1 per 1,000; its live checkpoint data
  covers few airports (JFK in the US). Qsensor runs a REST API for queue times (price on request).
- TSA FOIA throughput (used for the estimate): TSA's FOIA Reading Room (tsa.gov/foia/readingroom) posts a
  weekly PDF of passengers screened per airport, checkpoint and hour; the latest seen covers 18 to 24 October
  2026. The data.gov record lists it as public, a work of the US government
  (usa.gov/government-works), so it may be reused. `supabase/scripts/import_tsa_throughput.py` downloads the
  newest weekly PDFs (cached in the gitignored `supabase/.tsa-cache`, never committed), extracts every row
  from pdftotext word boxes, and reduces them to a typical week per checkpoint (median passengers per weekday
  and local hour). Its output is a seed migration that replaces `security_checkpoints` and
  `security_throughput`; the first one, 20261030000016, covers 30 August to 24 October 2026 (8 reports):
  591 checkpoints at 411 airports. Employee, crew and FIS checkpoints, arrival rechecks, private terminals and
  paid suites are left out. The report never says which checkpoints have PreCheck, so PreCheck is unknown
  unless the name says it. To refresh: run the script with the next migration number as `--out`.
  `security-wait/model.ts` turns each checkpoint's week into a wait with a documented queue model (assumed
  lanes of 150 passengers an hour sized against the busiest hour, a carried-over backlog, bunched arrivals);
  its constants are calibrated, not measured: with this data, checkpoints whose busiest hour passes 1,000
  passengers wait 15 to 30 minutes at that hour and mostly 5 to 10 through the day, and nothing passes 35.
  An airport with no rows gets a typical US day instead. Both are labelled estimates in the app and never
  shown as live.
