# Soma Flight v1.1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Match reference screens 29 to 53 (flight detail, My Flights row, Add Flight, Passport tab, full Passport, Aircraft Stats) with good quality logos for every airline the logo provider covers, round flags, and side-view aircraft for every airline and type pair (licensed profiles, our renderer as fallback), all kept up to date, on fakes wherever data or artwork costs money.

**Architecture:** New user fields and reference tables in Postgres; reference data (airlines, aircraft types, countries) generated from one set of CSVs into both a SQL seed and bundled app JSON. New Passport and aircraft statistics live in the Rust core with shared fixtures, exposed through the WASM and UniFFI bindings. Brand assets (logos, dark logos, tail logos, brand colours, side-view profiles) are synced by a service-role edge function from licensed providers behind adapters (`LogoProvider`, `SideViewProvider`) into a private Storage bucket keyed by airline ICAO (and aircraft type for side views), versioned in `airline_assets`, re-downloaded only when changed, checked weekly; the app reads them by ICAO through a signed-URL endpoint and keeps a versioned disk cache. Fallbacks: a monogram for logos, our own vector renderer (family bases plus liveries derived from brand colours) for side views and for every blueprint. Flags are bundled.

**Tech Stack:** as v1 (Swift 6, SwiftUI, iOS 26 and macOS 26, XcodeGen, supabase-swift 2.55.5, Rust core `flightcore` with wasm-bindgen and UniFFI, Supabase Postgres 17 with pgTAP, Deno 2 edge functions), plus circle-flags (MIT) SVGs, Natural Earth 1:110m land (public domain), Wikidata (CC0).

**Spec:** `docs/superpowers/specs/2026-10-29-soma-flight-v1-1-screens-design.md` (parent: `docs/superpowers/specs/2026-10-28-soma-flight-v1-design.md`)

**Owner actions (blockers for turning production on, not for building):**
1. Request quotes and sign the logo licence (Airhex or another provider behind `LogoProvider`); then set `LOGO_PROVIDER` and `AIRHEX_KEY` as project secrets.
2. Choose the side view source (Logostream API or an Airliners Illustrated direct licence), request quotes and sign; then the concrete `SideViewProvider` adapter is written against its delivery format and `SIDE_VIEW_PROVIDER` is set.
3. Confirm with the providers or counsel that showing airline names, logos, colours and liveries in a commercial app is covered (spec 4.3 legal note).
4. Approve the AeroAPI cost before the arrival forecast and inbound chain are wired to real data.
Until then every task runs on fakes and recorded fixtures, production shows monograms and our own renderer, and no purchase or contract is part of this plan.

**Start point:** worktree `/Users/quentin/Desktop/Soma/Soma_Flight/.worktrees/backend`, branch `feat/backend`. Start only after app plan Task 12 (settings, export, privacy manifest, final snapshots, named SwiftData store) is committed, and plan against HEAD at that point: Task 12 changes `FlightDetailView` (notify switch), `FlightDetailStore` (`notify`, `setNotify`), `SettingsView`, `CacheStore.onDisk(url:)` and `PastFlightExport`, so read those files fresh before Tasks 3, 15 and 16.

## Global Constraints

- Name: Soma Flight only. Never the reference app's name, logo, icon, illustrations or copy text. Every user-facing string is our own English copy; the strings this plan pins are the ones to use.
- No Pro, no paywall, no upsell, no Friends tab, no "Get Pro" button, nothing blurred.
- Design match: layout, hierarchy, spacing, type scale, colours and component shapes follow refs 29 to 53 closely. Each screen task ends with side-by-side PNGs (reference left, ours right) made by `Scripts/compare.py` under `docs/screens/compare/v2-*.png`, checked by the task reviewer.
- Swift 6 language mode, strict concurrency complete, iOS 26.0 and macOS 26.0. Views talk only to stores or pure helpers; stores talk only to service protocols.
- Statistics that the app shows over past flights are computed in the Rust core `flightcore`, with shared JSON fixtures in `core/fixtures/` produced by an independent Python generator (stdlib only), replayed by Rust, Deno (WASM) and Swift (UniFFI) tests.
- Backend: Deno edge functions export `handler(req, deps)`; their tests run on the local stack and delete every row, user and Storage object they create (in `finally`). Every SQL function has `set search_path = ''`, is revoked from `public, anon, authenticated`, and the pgTAP guard in `supabase/tests/archive_test.sql` stays green.
- No paid API calls and no purchase: AeroAPI paid sections (arrival forecast, inbound chain) run on fakes and are hidden in live builds; provider adapters are tested on recorded fixtures; the only live provider call allowed is the logo provider's free demo key, on the local stack in Debug; production syncs are no-ops until the owner sets the licensed keys.
- Brand assets: logos for every airline the provider lists, vector or PNG of at least 3x the largest display size (192 px for the 64 pt logo), dark variant when offered; side views at least 1200 px wide; both stored only in our bucket, versioned, refreshed weekly, and never fetched by the app from a provider (no provider key in the app).
- Reference data licences: OurAirports (public domain), Wikidata (CC0), circle-flags (MIT, licence shipped in the app's Acknowledgements), Natural Earth (public domain). No ODbL or share-alike data.
- Commits: conventional messages, explicit paths (`git add <paths>`, never `-A`), no attribution lines of any kind.
- Never the em dash character anywhere (code, comments, docs, copy, commits).
- English UI copy.

## Review Focus

1. **Airline or aircraft missing from the reference data** (unknown ICAO, an operator stored as a name like "United", a type like "C25B" with no family): one airline key per carrier, monogram logo, generic side view, the flight still counted. Tests in Task 3 (`resolvesAirlineByNameIataIcao`), Task 10 (`unknownAirlineMonogram`), Task 11 (`unknownTypeFallsBackToGeneric`).
2. **Overnight or date line flights** (SFO to CDG lands +1 day, HND to SFO lands the previous local day): the arrival marker reads `+1` or `-1`, "Overnight" only when the local date advances, the time zone line has the right sign. Tests in Task 15 (`dayMarkerAcrossDateLine`) and Task 16 (`timeZoneChangeNegative`).
3. **Editing booking code, seat or notes with bad input or while offline**: invalid text shows an inline error and is not sent; a failed save restores the server value and keeps the typed text in the field; clearing a field stores null. Tests in Task 1 (check constraints) and Task 15 (`saveDetailsRollsBack`, `invalidSeatNotSent`).
4. **Sparse or tiny history** (no block times, no countries, no seats, no registrations, a year with zero or one flight): every section hides or shows a dash, no division by zero, shortest equals longest for one flight, median of one aircraft is its age. Tests in Task 4 and Task 5 fixtures (`empty`, `single_flight`, `sparse`) and the sparse snapshots in Tasks 20 and 22.
5. **Brand assets absent, failing or changed** (no licence key, provider 404 or 503, corrupt file on disk, a logo redrawn upstream): monogram or our own renderer at once, no retry storm (a miss is remembered for a day), a corrupt file is deleted, a new version replaces the old file and only changed files are downloaded. Tests in Task 8 (`notConfiguredIsNoOp`, `unchangedVersionNotDownloadedAgain`) and Task 10 (`negativeCacheSkipsNetwork`, `corruptFileIsDropped`, `newVersionReplacesFile`).

---

## File Structure

```
supabase/
  migrations/20261030000001_v11_user_fields.sql      user fields, countries, air time, off/on times, aircraft table
  migrations/20261030000002_reference_tables.sql     airlines, aircraft_types (DDL, RLS, grants)
  migrations/20261030000003_reference_seed.sql       generated inserts
  migrations/20261030000004_brand_assets.sql         private bucket brand-assets, airline_assets
  migrations/20261030000005_brand_sync_jobs.sql, 20261030000006_side_view_jobs.sql   pg_cron sync
  seed/airlines.csv, aircraft_types.csv, country_regions.csv
  scripts/build_reference_seed.ts (+ _test.ts)       CSVs to SQL seed and app JSON
  functions/_shared/brand/                           LogoProvider + AirhexLogoProvider, SideViewProvider, sync
  functions/brand-asset/, functions/brand-assets-sync/
  tests/v11_fields_test.sql, reference_test.sql, brand_assets_test.sql
core/
  flightcore/src/passport_detail.rs, aircraft.rs
  fixtures/passport_detail.json, aircraft.json, gen_passport_detail.py, gen_aircraft.py
Packages/FlightKit/Sources/FlightKit/
  Models/      Airline.swift, AircraftType.swift, Country.swift, FollowDetails.swift, Livery.swift, Insights.swift
  App/         ReferenceData.swift
  Services/    BrandAssetService.swift, InsightsService.swift, AircraftFactsService.swift, Supabase/SupabaseBrandAssetService.swift
  Stores/      PassportDetail.swift (Swift wrappers over the core), FrequentlyUsed.swift
  UI/Brand/    AirlineLogo.swift, CountryFlag.swift
  UI/Aircraft/ AircraftGeometry.swift, Families/*.swift, AircraftSideView.swift, LiveryRenderer.swift, AircraftImage.swift, Blueprint.swift
  UI/Detail/   DetailHeader.swift, DepartArrive.swift, DetailTiles.swift, GoodToKnow.swift, Timetable.swift,
               AirlineCard.swift, RouteHistory.swift, ForecastSection.swift, PlaneSection.swift
  UI/Screens/  MyFlightRow.swift, Passport/FullPassportView.swift, Passport/PassportMap.swift, Passport/PassportLists.swift,
               Aircraft/AircraftStatsView.swift, Aircraft/AircraftPanels.swift, AcknowledgementsView.swift
  Resources/   Reference/{airlines,aircraft_types,countries,livery_seed,world_land}.json, Flags.xcassets, Licenses/*.txt
Scripts/       compare.py (Set 2 entries), flags/build_flags.py, world/build_land.py
```

---

### Task 1: Data model migration and contract

**Files:**
- Create: `supabase/migrations/20261030000001_v11_user_fields.sql`, `supabase/tests/v11_fields_test.sql`
- Modify: `supabase/functions/_shared/aeroapi_types.ts` (`toFlightRow`), `supabase/functions/_shared/aeroapi_test.ts`, `supabase/tests/archive_test.sql` (guard), `docs/api-contract.md`

**Interfaces:**
- Produces (Postgres):
  - `create type seat_class as enum ('economy','premium_economy','business','first')`, `create type trip_reason as enum ('personal','business')`.
  - On both `user_flights` and `past_flights`: `seat_class seat_class`, `seat text check (seat ~ '^[0-9]{1,3}[A-K]$')` (past_flights already has `seat`: add the check only), `reason trip_reason`, `booking_code text check (booking_code ~ '^[A-Z0-9]{5,8}$')`, `notes text check (char_length(notes) <= 2000)`.
  - `past_flights`: `origin_country text`, `destination_country text` (ISO 3166-1 alpha-2), `air_minutes int`. Backfill countries from `airports.country`.
  - `flights`: `scheduled_off, scheduled_on, estimated_off, estimated_on timestamptz`.
  - `aircraft(registration text primary key, aircraft_type text, airline_icao text, delivered_on date, name text)`, empty, `select` to `authenticated`, written by service role only.
  - `archive_landed_flights()` replaced (`create or replace`, same signature, same grants) so each archived row also copies `seat_class, seat, reason, booking_code, notes` from the follower's `user_flights` row, sets both countries from `airports`, and `air_minutes = round(extract(epoch from actual_on - actual_off)/60)` when both exist and `actual_on > actual_off`.
- Produces (TS): `toFlightRow` maps AeroAPI `scheduled_off, scheduled_on, estimated_off, estimated_on`.

- [ ] **Step 1: Write the failing pgTAP test** `v11_fields_test.sql`: user A updates `seat_class, seat, reason, booking_code, notes` on own follow (succeeds); user B's update of A's row touches 0 rows; `throws_ok` for seat `'hello'`, booking code `'ab'`, notes of 2001 characters; archiving a flight A follows (landed 25 h ago, `actual_off`/`actual_on` 7 h apart) copies all five fields, sets `origin_country 'US'`, `destination_country 'FR'`, `air_minutes 420`; a follow with no extra fields archives with nulls; `aircraft` is readable by authenticated, not writable.
- [ ] **Step 2: Extend the guard** in `archive_test.sql`: `is(count of public functions, not extension-owned (no pg_depend deptype 'e'), whose proconfig lacks search_path="" , 0)`.
- [ ] **Step 3: Write the failing Deno test** in `aeroapi_test.ts`: `toFlightRow maps off and on times` (fixture `flight_af84.json` with `scheduled_off` set gives a non-null `scheduled_off`).
- [ ] **Step 4:** `supabase db reset && supabase test db` and `deno test -A supabase/functions/_shared/aeroapi_test.ts`. Expected: FAIL.
- [ ] **Step 5:** Write the migration and the mapping. Restate `archive_landed_flights()` from `20261029000004_jobs.sql` in full with the additions; keep its comment block accurate.
- [ ] **Step 6:** Same commands. Expected: PASS, guard green.
- [ ] **Step 7:** Add to `docs/api-contract.md` a section "Tables the app reads and writes": `user_flights` user fields (client `update` through PostgREST, RLS owner only), `past_flights` new columns, `aircraft`, and the four new `flights` times.
- [ ] **Step 8:** Commit `feat(db): v1.1 user fields, countries, air time`.

### Task 2: Reference data (airlines, aircraft types, countries)

**Files:**
- Create: `supabase/seed/airlines.csv`, `supabase/seed/aircraft_types.csv`, `supabase/seed/country_regions.csv`, `supabase/scripts/build_reference_seed.ts`, `supabase/scripts/build_reference_seed_test.ts`, `supabase/migrations/20261030000002_reference_tables.sql`, `supabase/migrations/20261030000003_reference_seed.sql` (generated), `supabase/tests/reference_test.sql`, `Packages/FlightKit/Sources/FlightKit/Resources/Reference/{airlines,aircraft_types,countries}.json` (generated), `docs/data-sources.md`

**Interfaces:**
- Produces CSV columns, exactly:
  - `airlines.csv`: `icao,iata,name,callsign,alliance,country,color_primary,color_secondary,phone,website,x,facebook`. `alliance` is empty or `star_alliance|oneworld|skyteam`; colours `#RRGGBB`. Rows: at least the airlines of the owner's history (`UAL, DLH, AFR, ACA, TRA, TVF, BEL, FLE, RYR`), every carrier in `Resources/Fakes/*.json`, and the members of the three alliances; the logo sync (Task 8) later adds every airline the provider lists. ICAO, IATA, callsign, alliance, website from Wikidata (CC0); seed colours from the airline's public site (replaced by provider brand colours at sync, except `UAL, AFR, RYR`, the livery seed of Task 12, whose rows the seed writes with `colors_source = 'locked'`); phone, X, Facebook from the airline's own site.
  - `aircraft_types.csv`: `icao_type,family,manufacturer,name` where `family` is one of `a220,a320,a330,a350,a380,b737,b737max,b747,b757,b767,b777,b787,ejet,crj,atr,other`. Our own list of at least 70 designators covering `TravelFacts.aircraftNames` and the fakes.
  - `country_regions.csv`: `iso2,name,region` for every ISO 3166-1 alpha-2 code plus `XK`, region one of `europe,north_america,central_america,caribbean,south_america,africa,middle_east,asia,oceania` (our assignment from UN M49 subregions; Middle East = Western Asia plus Egypt; Central America = M49 Central America including Mexico).
- Produces tables: `airlines(icao text pk check (icao ~ '^[A-Z]{3}$'), iata text, name text not null, callsign text, alliance text, country text, color_primary text not null, color_secondary text, phone text, website text, x text, facebook text, colors_source text not null default 'seed' /* seed, locked, or the provider name */, colors_updated_at timestamptz)`, `aircraft_types(icao_type text pk, family text not null, manufacturer text not null, name text not null)`; RLS on, `select` to authenticated, writes service role only. (Countries are app and core data only, no table.)
- Produces script: `deno run -A supabase/scripts/build_reference_seed.ts` writes the seed migration and the three JSON files (camelCase keys: `{icao, iata, name, callsign, alliance, country, colorPrimary, colorSecondary, phone, website, x, facebook}`, `{icaoType, family, manufacturer, name}`, `{iso2, name, region}`). It fails with a message on: duplicate key, bad hex colour, unknown family or region, IATA not 2 characters.

- [ ] **Step 1: Write failing tests**: `build_reference_seed_test.ts` (`rejects duplicate icao`, `rejects bad colour`, `rejects unknown family`, `output is stable` (two runs byte-identical)); `reference_test.sql` (`airlines` has at least 60 rows, `UAL` has iata `UA` and alliance `star_alliance`, every `aircraft_types.family` is in the allowed set, authenticated cannot insert).
- [ ] **Step 2:** Run `deno test -A supabase/scripts/` and `supabase test db`. Expected: FAIL.
- [ ] **Step 3:** Write the CSVs, DDL migration and script; run the script.
- [ ] **Step 4:** `supabase db reset && supabase test db`, `deno test -A supabase/scripts/`. Expected: PASS.
- [ ] **Step 5:** Write `docs/data-sources.md`: each dataset, its source URL, licence, retrieval date, and why OpenFlights (ODbL share-alike) is not used.
- [ ] **Step 6:** Commit `feat(db): airlines and aircraft types reference data`.

### Task 3: App reference directory, new model fields, follow details

**Files:**
- Create: `Models/Airline.swift`, `Models/AircraftType.swift`, `Models/Country.swift`, `Models/FollowDetails.swift`, `App/ReferenceData.swift`, `Tests/FlightKitTests/ReferenceDataTests.swift`, `Tests/FlightKitTests/FollowDetailsTests.swift`
- Modify: `Models/Flight.swift`, `Models/PastFlight.swift`, `Services/FlightService.swift`, `Services/Fakes/FakeServices.swift`, `Services/Supabase/SupabaseFlightService.swift`, `Services/Supabase/SupabaseHistoryService.swift` (columns), `App/AppEnvironment.swift`, `UI/Screens/Shared/TravelFacts.swift` (`aircraftName` reads `ReferenceData`), `Scripts/gen_past_flights.py`, `Resources/Fakes/past_flights.json`

**Interfaces:**
- Consumes: Task 2 JSON, Task 1 columns.
- Produces:
  - `struct Airline: Codable, Sendable, Hashable, Identifiable { id: String /* ICAO */; iata: String?; name: String; callsign: String?; alliance: Alliance?; country: String?; colorPrimary: String; colorSecondary: String?; phone: String?; website: URL?; x: URL?; facebook: URL? }`, `enum Alliance: String { case starAlliance = "star_alliance", oneworld, skyteam; var title: String }` ("Star Alliance", "oneworld", "SkyTeam").
  - `enum AircraftFamily: String, Codable, Sendable, CaseIterable { case a220, a320, a330, a350, a380, b737, b737max, b747, b757, b767, b777, b787, ejet, crj, atr, other; var isWidebody: Bool }`, `struct AircraftType: Codable, Sendable, Hashable, Identifiable { id: String; family: AircraftFamily; manufacturer: String; name: String }`.
  - `enum WorldRegion: String, Codable, Sendable, CaseIterable { case europe, northAmerica = "north_america", centralAmerica = "central_america", caribbean, southAmerica = "south_america", africa, middleEast = "middle_east", asia, oceania; var title: String }` with titles "Europe", "N. America", "C. America", "Caribbean", "S. America", "Africa", "Middle East", "Asia", "Oceania" and `static let gridOrder: [WorldRegion] = [.europe, .northAmerica, .asia, .caribbean, .africa, .centralAmerica, .middleEast, .oceania, .southAmerica]`; `struct Country: Codable, Sendable, Hashable, Identifiable { id: String /* ISO2 upper */; name: String; region: WorldRegion }`.
  - `struct ReferenceData: Sendable { airlines: [Airline]; types: [AircraftType]; countries: [Country]; static func bundled() -> ReferenceData /* loaded once */; func airline(_ code: String) -> Airline? /* ICAO, IATA or exact name, any case */; func airline(ident: String) -> Airline? /* via TravelFacts.airlineCode */; func type(_ icao: String) -> AircraftType?; func country(_ iso2: String) -> Country? }`, plus `EnvironmentValues.reference` defaulting to `.bundled()`. `AppEnvironment` gains `reference: ReferenceData`.
  - `enum SeatClass: String, Codable, Sendable, CaseIterable { case economy, premiumEconomy = "premium_economy", business, first; var title: String }` ("Economy", "Premium Economy", "Business", "First"); `enum TripReason: String, Codable, Sendable, CaseIterable { case personal, business; var title: String }`.
  - `struct FollowDetails: Codable, Sendable, Hashable { seatClass: SeatClass?; seat: String?; reason: TripReason?; bookingCode: String?; notes: String?; static let empty; static func normalizedSeat(_ s: String) -> String?? /* .some(nil) for empty = clear, nil = invalid */; static func normalizedBookingCode(_ s: String) -> String?? }`. Seat: trim, uppercase, must match `^[0-9]{1,3}[A-K]$`. Booking code: trim, uppercase, `^[A-Z0-9]{5,8}$`. Notes: trimmed, at most 2000 characters.
  - `PastFlight` gains optional `seatClass, reason, bookingCode, notes, originCountry, destinationCountry, airMinutes` (absent keys decode as nil). `Flight` gains `scheduledOff, scheduledOn, estimatedOff, estimatedOn: Date?` in `CodingKeys`, `init(from:)`, `encode(to:)` and the memberwise init (default nil).
  - `FlightService` gains `func followDetails(_ id: Flight.ID) async throws(APIError) -> FollowDetails?` (nil when not followed) and `func saveFollowDetails(_ id: Flight.ID, _ details: FollowDetails) async throws(APIError)`. Supabase: select and update the five `user_flights` columns for the resolved flight id. Fakes: in memory, honour `nextError`.
- `gen_past_flights.py` gives every generated flight a deterministic `seat_class`, `seat`, `reason`, `registration`, `origin_country`, `destination_country`, `air_minutes` (block minus 25), keeping the first eight hand-written rows unchanged except for countries.

- [ ] **Step 1: Write failing tests**: `resolvesAirlineByNameIataIcao` (`"United"`, `"UA"`, `"ual"` give `UAL`; `"ZZZ"` gives nil, Review Focus 1); `airlineFromIdent` (`UA990` gives `UAL`, `B6417` gives `JBU`); `typeFamily` (`B38M` gives `.b737max`, `C25B` gives nil); `everyFakeAirlineResolves`; `gridOrderHasNine`; `normalizedSeat` (`" 23a "` gives `23A`, `""` gives `.some(nil)`, `"hello"` gives nil); `normalizedBookingCode` (`"abc12d"` gives `ABC12D`, `"ab"` gives nil); `decodesPastFlightWithoutNewKeys`; `decodesFlightOffOn`; `fakeFollowDetailsRoundTrip`.
- [ ] **Step 2:** `swift test --package-path Packages/FlightKit --filter "ReferenceDataTests|FollowDetailsTests|ModelDecodingTests"`. Expected: FAIL.
- [ ] **Step 3:** Implement; regenerate the fake history with `python3 Packages/FlightKit/Scripts/gen_past_flights.py Packages/FlightKit/Sources/FlightKit/Resources/Fakes`.
- [ ] **Step 4:** Full `swift test --package-path Packages/FlightKit`. Expected: PASS (existing Passport tests unchanged).
- [ ] **Step 5:** Commit `feat(app): reference data, follow details, new flight fields`.

### Task 4: Rust core Passport detail

**Files:**
- Create: `core/flightcore/src/passport_detail.rs`, `core/fixtures/gen_passport_detail.py`, `core/fixtures/passport_detail.json`, `core/flightcore/tests/passport_detail_unit.rs`
- Modify: `core/flightcore/src/passport.rs` (new `PastFlight` fields with `#[serde(default)]`), `core/flightcore/src/lib.rs`, `core/flightcore/tests/fixtures.rs`, `core/flightcore-wasm/src/lib.rs`, `core/flightcore-ffi/src/lib.rs`, `supabase/functions/_shared/flightcore.ts`, `supabase/functions/_shared/flightcore_test.ts`, `Packages/FlightCoreFFI/Tests/FlightCoreTests/FixtureTests.swift`, generated outputs of `core/scripts/build-wasm.sh` and `core/scripts/build-xcframework.sh`, `Packages/FlightKit/Sources/FlightKit/Stores/PassportStats.swift` (`coreFlight` fills the new fields)

**Interfaces:**
- Produces (Rust, serde snake_case input, camelCase output):
  - `PastFlight` gains `origin_country: Option<String>, destination_country: Option<String>, air_minutes: Option<u32>, registration: Option<String>, seat_class: Option<SeatClass>, seat: Option<String>, reason: Option<TripReason>` (all `#[serde(default)]`; existing `passport.json` cases stay valid and unchanged).
  - `pub enum Region { Europe, NorthAmerica, CentralAmerica, Caribbean, SouthAmerica, Africa, MiddleEast, Asia, Oceania }` (snake_case), `pub struct CountryInfo { pub iso2: String, pub region: Region }`.
  - `pub fn compute_passport_detail(flights: &[PastFlight], year: Option<i32>, countries: &[CountryInfo]) -> PassportDetail` with fields: `flights, domestic, international, long_haul: u32`; `per_year: Vec<YearCount { year: i32, flights: u32 }>` (ascending, all-time history regardless of `year`); `per_month: [u32; 12]` (Jan first); `per_weekday: [u32; 7]` (Monday first), both in the origin's local time; `distance_km: u64, avg_distance_km: u32, earth_ratio: f64, moon_ratio: f64, sun_ratio: f64`; `shortest_by_distance, longest_by_distance, shortest_by_time, longest_by_time: Option<FlightRef>`; `flight_minutes, avg_flight_minutes, air_minutes, taxi_minutes: u64`; `airports: Vec<AirportVisits { icao, visits }>`; `airlines_by_flights, airlines_by_distance, routes_by_flights, routes_by_distance: Vec<Tally { key: String, flights: u32, distance_km: u64 }>`; `countries: Vec<CountryCount { iso2, flights }>`; `unknown_country_flights: u32`; `regions: Vec<RegionCount { region, visited: u32, total: u32 }>` (all nine, `Region` declaration order). `FlightRef { ident, origin_icao, destination_icao, departed_at, distance_km, block_minutes: Option<u32>, airline: Option<String> }`.
- Rules (pin in the fixture `meta.rules` and in the generator): canceled flights excluded; domestic when both countries known and equal, international when both known and different, neither when one is unknown; constants `EARTH_KM = 40_075`, `MOON_KM = 384_400`, `SUN_KM = 4_375_250` (circumference of the Sun), ratio = distance / constant; averages rounded half up, 0 when no flights; ties on shortest and longest go to the earliest `departed_at`, "by time" ignores flights without `block_minutes`; `taxi_minutes` sums `block - air` (saturating) over flights with both; tallies sort by their measure descending, then the other measure descending, then key ascending; airline key is `airline` as given (the app passes ICAO), route key `"ORIG-DEST"` ICAO, direction kept; a country counts once per flight (domestic flights count once); `regions.total` is the number of `countries` entries in that region, `visited` the distinct visited countries there.
- Visits rule (the generator implements the same text independently):

```
sort kept flights by departed_at (stable)
for each flight i:
  destination gets one visit
  origin gets one visit, unless i > 0 and flight[i-1].destination == origin
    and departed_at[i] - (departed_at[i-1] + 60 * block_minutes[i-1] or 0) < 28_800
sort visits descending, then icao ascending
```

- Bindings: WASM `computePassportDetail(flightsJson, year | undefined, countriesJson): string`; FFI `computePassportDetail(flights:year:countries:) -> PassportDetail`; TS wrapper `computePassportDetail(flights, year, countries): PassportDetail`.

- [ ] **Step 1: Write the generator and fixture** with cases: `empty`; `single_flight` (shortest equals longest); `domestic_international_unknown`; `weekday_tz_boundary` (Sunday 23:30 in Los Angeles counts Sunday); `connection_7h59_once` and `connection_8h00_twice`; `ratios` (280,017 km gives earth 6.987..., moon 0.728..., sun 0.064...); `taxi_and_air`; `tally_ties`; `year_filter_with_per_year_all_time`; `sparse` (no block, no countries, no airline).
- [ ] **Step 2: Write failing tests**: Rust `fixtures.rs` replays `passport_detail.json`; unit tests for the visit rule; Deno and Swift fixture replays.
- [ ] **Step 3:** `cargo test --manifest-path core/Cargo.toml`. Expected: FAIL.
- [ ] **Step 4:** Implement; run `core/scripts/build-wasm.sh` and `core/scripts/build-xcframework.sh`.
- [ ] **Step 5:** `cargo test --manifest-path core/Cargo.toml`, `deno test -A supabase/functions/_shared/flightcore_test.ts`, `swift test --package-path Packages/FlightCoreFFI`, `swift test --package-path Packages/FlightKit`. Expected: PASS.
- [ ] **Step 6:** Commit `feat(core): Passport detail stats`.

### Task 5: Rust core aircraft stats

**Files:**
- Create: `core/flightcore/src/aircraft.rs`, `core/fixtures/gen_aircraft.py`, `core/fixtures/aircraft.json`, `core/flightcore/tests/aircraft_unit.rs`
- Modify: the same binding, wrapper and fixture-replay files as Task 4

**Interfaces:**
- Produces:
  - `pub struct TypeInfo { pub icao_type: String, pub family: String, pub manufacturer: String }`, `pub struct AircraftFact { pub registration: String, pub delivered_at: Option<i64>, pub name: Option<String> }`.
  - `pub enum SeatPosition { Window, Middle, Aisle }`, `pub fn seat_position(seat: &str, family: &str) -> Option<SeatPosition>` from the economy layout of the family: 3-3 (`a320, b737, b737max, b757`: A F window, B E middle, C D aisle); `a220` 2-3 (A F window, E middle, C D aisle); `ejet, atr` A C D F (A F window, C D aisle); `crj` A B C D (A D window, B C aisle); 3-3-3 (`a350, b787`: A K window, B E J middle, C D F H aisle); 3-4-3 (`b777, b747, a380`: A K window, B E F J middle, C D G H aisle); 2-4-2 (`a330`: A K window, E F middle, C D G H aisle); 2-3-2 (`b767`: A K window, E middle, C D F H aisle). Other families or letters give None.
  - `pub fn compute_aircraft_stats(flights: &[PastFlight], year: Option<i32>, types: &[TypeInfo], facts: &[AircraftFact], as_of: i64) -> AircraftStats` with: `total_types: u32`; `manufacturers: Vec<Share { key, flights, percent }>` (percent rounded half up); `types_by_flights, types_by_minutes, types_by_distance: Vec<TypeTally { icao_type, flights, minutes: u64, distance_km: u64 }>`; `most_flown: Option<TypeTally>` (first of `types_by_flights`); `tails: Vec<TailTally { registration, flights, icao_type: Option<String>, airline: Option<String>, name: Option<String> }>`; `seat_classes: SeatClassCounts { economy, premium_economy, business, first }`; `seat_positions: PositionCounts { window, middle, aisle }`; `favourite_seat: Option<SeatTally { seat, flights }>`; `reasons: ReasonCounts { personal, business }`; `decades: Vec<DecadeCount { decade: i32, aircraft: u32 }>` (distinct registrations with a delivery date, ascending, empty decades between first and last included); `median_age_months: Option<u32>`; `newest, oldest: Option<AgedAircraft { registration, icao_type: Option<String>, delivered_at: i64, age_months: u32 }>`.
- Rules: canceled excluded; unknown types count in `total_types` but not in `manufacturers`; ages use whole months between `delivered_at` and `as_of` in UTC; median of an even count is the lower middle; ties: flights desc, then key asc.
- Bindings: WASM `computeAircraftStats(flightsJson, year, typesJson, factsJson, asOf)`, FFI `computeAircraftStats(flights:year:types:facts:asOf:)`, `seatPosition(seat:family:)`.

- [ ] **Step 1:** Generator and fixture cases: `empty`, `single_aircraft` (median equals its age), `seat_positions_every_layout`, `unknown_family_seat`, `decades_with_gap`, `manufacturer_percent_rounding`, `no_facts` (ages empty, newest nil), `year_filter`.
- [ ] **Step 2:** Failing Rust, Deno and Swift replays. **Step 3:** Run, FAIL. **Step 4:** Implement and rebuild both bindings. **Step 5:** Same four commands as Task 4, PASS.
- [ ] **Step 6:** Commit `feat(core): aircraft stats`.

### Task 6: Round country flags

**Files:**
- Create: `Scripts/flags/build_flags.py`, `Scripts/flags/PIN` (upstream commit SHA), `Packages/FlightKit/Sources/FlightKit/Resources/Flags.xcassets/**`, `Resources/Licenses/circle-flags.txt`, `UI/Brand/CountryFlag.swift`, `UI/Screens/AcknowledgementsView.swift`, `Tests/FlightKitTests/CountryFlagTests.swift`
- Modify: `UI/Screens/SettingsView.swift` (an "Acknowledgements" row)

**Interfaces:**
- Produces: `CountryFlag(code: String?, size: CGFloat)` drawing `Image("flag-<iso2 lowercase>", bundle: .module)`, unknown or nil code uses `flag-xx`; `static func assetName(_ code: String?) -> String`. `AcknowledgementsView` lists circle-flags (MIT, full licence text), OurAirports (public domain), Wikidata (CC0), Natural Earth (public domain), supabase-swift (MIT).
- Pipeline: `git clone https://github.com/HatScripts/circle-flags` into the scratchpad, `git checkout <sha>` (the latest commit on the day, written to `Scripts/flags/PIN`), then `python3 Scripts/flags/build_flags.py <clone> Packages/FlightKit/Sources/FlightKit/Resources/Flags.xcassets` copies `flags/<iso2>.svg` for every code in `countries.json` plus `xx.svg` into `flag-<iso2>.imageset/` with `Contents.json` setting `preserves-vector-representation: true`. Asset catalogs take SVG directly; a flag that fails the load test below is converted to PDF with `rsvg-convert` (ask the owner before installing librsvg).

- [ ] **Step 1: Write failing tests**: `everyCountryHasAFlag` (each `countries.json` code resolves with `Bundle.module.image(forResource:)` on macOS), `unknownCodeUsesFallback` (`"ZZ"` and nil give `flag-xx`), `assetNameLowercases`.
- [ ] **Step 2:** Run. FAIL. **Step 3:** Run the pipeline, implement. **Step 4:** Run. PASS. Render `docs/screens/components/flags.png` (a grid of 20 flags) through the snapshot suite.
- [ ] **Step 5:** Commit `feat(app): round country flags and acknowledgements`.

### Task 7: Brand asset store and read endpoint

**Files:**
- Create: `supabase/migrations/20261030000004_brand_assets.sql`, `supabase/tests/brand_assets_test.sql`, `supabase/functions/brand-asset/{handler.ts,index.ts,index_test.ts}`
- Modify: `docs/api-contract.md`

**Interfaces:**
- Produces (Postgres): private Storage bucket `brand-assets` (no client policies). `create type brand_asset_kind as enum ('logo','logo_dark','tail','side_view')`. Table `airline_assets(icao text not null references airlines(icao), kind brand_asset_kind not null, aircraft_type text not null default '' /* side views only */, path text not null, format text not null check (format in ('svg','pdf','png')), width int, version text not null, etag text, provider text not null, fetched_at timestamptz not null, checked_at timestamptz not null, primary key (icao, kind, aircraft_type))`, RLS on, `select` to authenticated, writes service role only. Object paths: `logos/<ICAO>/<kind>-<version>.<ext>`, `side-views/<ICAO>/<TYPE>-<version>.<ext>` (the version in the name makes every change a new object, so caches never mix versions).
- Produces (function): `GET /brand-asset?airline=<ICAO>&kind=logo|logo_dark|tail|side_view[&type=<ICAO type>]` (user JWT, 600 calls per user per hour) returns `{ version, format, width, url, expiresAt }` where `url` is a signed URL valid 3600 s; no row gives 404 `not_found` (the app falls back); unknown airline 404; `type` required for `side_view` and refused otherwise (400). The licence key never reaches the app: the app only sees our bucket.

- [ ] **Step 1: Write failing tests**: pgTAP (`airline_assets` readable, not writable by authenticated; the function guard stays green); Deno (local stack, `finally` removes objects, rows and users): `servesSignedUrlWithVersion`, `missingAssetIs404`, `sideViewNeedsType`, `typeRefusedForLogo`, `noJwt401`, `rateLimit429`.
- [ ] **Step 2:** `supabase test db`, `deno test -A supabase/functions/brand-asset`. FAIL. **Step 3:** Implement. **Step 4:** PASS.
- [ ] **Step 5:** Commit `feat(db): brand asset store and read endpoint`.

### Task 8: Logo and brand colour sync (adapter, Airhex on a recorded fixture)

**Files:**
- Create: `supabase/functions/_shared/brand/logo_provider.ts`, `supabase/functions/_shared/brand/airhex.ts`, `supabase/functions/_shared/brand/airhex_test.ts`, `supabase/functions/_shared/brand/sync.ts`, `supabase/functions/_shared/fixtures/airhex/*` (recorded), `supabase/functions/brand-assets-sync/{handler.ts,index.ts,index_test.ts}`, `supabase/migrations/20261030000005_brand_sync_jobs.sql`
- Modify: `docs/operations.md`, `docs/api-contract.md`

**Interfaces:**
- Produces:
  - `interface LogoProvider { readonly name: string; list(): Promise<ProviderAirline[]>; logo(icao: string, kind: "logo" | "logo_dark" | "tail"): Promise<ProviderFile | null>; colors(icao: string): Promise<BrandColors | null> }`, `ProviderAirline { icao: string; iata: string | null; name: string }`, `ProviderFile { bytes: Uint8Array; format: "svg" | "pdf" | "png"; width: number | null; version: string; etag: string | null }`, `BrandColors { primary: string; secondary: string | null }` (`#RRGGBB`).
  - `class AirhexLogoProvider implements LogoProvider { constructor(key: string, fetchFn?: typeof fetch) }`: prefers vector, else PNG at the largest size offered and never under 3x the 64 pt display size (192 px), asks for the dark variant when offered, reads brand colours from the provider's brand-colours endpoint. URLs, parameters and signing follow the provider's public API docs; the tests replay files recorded under `fixtures/airhex/` (taken from the docs' examples or one call with the provider's free demo key; no paid call).
  - `class FakeLogoProvider implements LogoProvider` (configurable list, files, colours, failures; counts calls).
  - `syncLogos(db, storage, provider, opts: { limit: number, now: Date }): Promise<SyncReport>` in `sync.ts`: upsert provider airlines missing from `airlines` (icao, iata, name, colours); take up to `limit` airlines with no `airline_assets` row or `checked_at` older than 7 days; for each kind, fetch, compare `etag` or a sha256 of the bytes with the stored `version`, upload a new object and upsert the row only when it changed, else bump `checked_at`; update colours (`colors_source` = provider name) unless `colors_source = 'locked'`. `SyncReport { checked, changed, added, failed }`. One airline failing does not stop the batch.
  - `POST /brand-assets-sync?mode=logos&limit=50` (service role only). Provider choice in `index.ts`: `LOGO_PROVIDER=airhex` with `AIRHEX_KEY` builds `AirhexLogoProvider`; anything else makes the call a logged no-op (`{ skipped: "provider not configured" }`), which is the production state until the licence is signed.
  - Migration: pg_cron job `brand-logos-sync` hourly at minute 17 through `public.invoke_edge_function('brand-assets-sync', 'mode=logos&limit=50')`; 2,050 airlines at 50 an hour are all checked within two days, then each again after 7 days, which is the weekly refresh.
  - Demo key: only in `supabase/functions/.env.local` for the local stack, so local Debug builds show provider logos; never set as a project secret. `docs/operations.md` says so and lists `LOGO_PROVIDER`, `AIRHEX_KEY` as "set after the licence is signed".

- [ ] **Step 1: Write failing tests**: `airhex_test.ts` on the recorded fixtures (`parsesList`, `prefersVectorElsePngAtLeast192`, `readsDarkVariantWhenOffered`, `readsBrandColors`, `sendsKeyAsDocumented`, `404IsNull`, `5xxThrowsProviderUnavailable`); `index_test.ts` with `FakeLogoProvider` on the local stack, cleaning up objects and rows: `firstRunUploadsAll`, `unchangedVersionNotDownloadedAgain` (second run: zero uploads, `checked_at` bumped), `changedEtagUploadsNewVersion` (old object removed after the row moves), `newProviderAirlineInserted`, `lockedColorsKept`, `oneFailureDoesNotStopBatch`, `notConfiguredIsNoOp`, `userJwtRefused`.
- [ ] **Step 2:** `deno test -A supabase/functions/_shared/brand supabase/functions/brand-assets-sync`. FAIL. **Step 3:** Implement. **Step 4:** PASS; `select jobname from cron.job` lists `brand-logos-sync`.
- [ ] **Step 5:** Commit `feat(functions): logo and brand colour sync`.

### Task 9: Side view sync (adapter, provider to be chosen)

**Files:**
- Create: `supabase/functions/_shared/brand/side_view_provider.ts`, `supabase/functions/_shared/fixtures/side_views/*` (recorded sample: two airlines, three types, from the candidate providers' public samples), `supabase/functions/_shared/brand/side_view_sync_test.ts`
- Modify: `supabase/functions/_shared/brand/sync.ts`, `supabase/functions/brand-assets-sync/handler.ts`
- Create: `supabase/migrations/20261030000006_side_view_jobs.sql`

**Interfaces:**
- Produces: `interface SideViewProvider { readonly name: string; list(): Promise<{ icao: string; aircraftType: string; version: string }[]>; file(icao: string, aircraftType: string): Promise<ProviderFile | null> }`; `class FakeSideViewProvider` and `class RecordedSideViewProvider(dir)` (replays the fixture folder). The concrete adapter (Logostream API or Airliners Illustrated delivery) is written once the owner picks one and signs; both fit this interface (a list of airline and type pairs with a version, one file per pair).
- `syncSideViews(db, storage, provider, opts)`: same pattern as `syncLogos`, rows `kind = 'side_view'` keyed by airline ICAO and aircraft type ICAO, pairs for airlines missing from `airlines` skipped and counted. `POST /brand-assets-sync?mode=side_views&limit=100`; pg_cron `brand-side-views-sync` hourly at minute 41; with `SIDE_VIEW_PROVIDER` unset it is a no-op.
- Image rule: vector or PNG at least 1200 px wide, transparent background, nose to the left (a provider drawing nose right is mirrored at upload and the row notes `mirrored`).

- [ ] **Step 1: Write failing tests** (local stack, cleanup): `uploadsPairsOnce`, `unchangedPairSkipped`, `changedPairNewVersion`, `unknownAirlineSkipped`, `noseRightMirrored`, `notConfiguredIsNoOp`.
- [ ] **Step 2:** Run. FAIL. **Step 3:** Implement. **Step 4:** PASS.
- [ ] **Step 5:** Commit `feat(functions): side view sync behind a provider adapter`.

### Task 10: App brand cache and AirlineLogo

**Files:**
- Create: `Services/BrandAssetService.swift`, `Services/Supabase/SupabaseBrandAssetService.swift`, `UI/Brand/AirlineLogo.swift`, `Tests/FlightKitTests/BrandAssetTests.swift`
- Modify: `App/AppEnvironment.swift` (`brand: any BrandAssetService`), `Services/Fakes/FakeServices.swift`, `UI/Screens/SearchView.swift` (`AirlineBadge` replaced), `UI/Screens/Passport/PassportCards.swift` (past flight rows)

**Interfaces:**
- Consumes: `Airline` (Task 3), `brand-asset` (Task 7).
- Produces:
  - `enum BrandAssetKind: String, Sendable { case logo, logoDark = "logo_dark", tail, sideView = "side_view" }`; `struct BrandAsset: Sendable, Hashable { data: Data; format: String; version: String }`; `protocol BrandAssetService: Sendable { func asset(_ icao: String, _ kind: BrandAssetKind, type: String?) async -> BrandAsset? }` (never throws; nil means fall back).
  - `SupabaseBrandAssetService(backend:cacheDir:transport:clock:)`: disk cache `Caches/SomaFlight/Brand/<ICAO>/<kind>[-<TYPE>]-<version>.<ext>` plus a small index; a cached asset is used at once and revalidated when older than 7 days (same version: touch; new version: download, replace, delete the old file); a 404 is remembered for 24 h; network failures keep the cached file and are retried at most once a minute per key; a file that does not decode (SVG through `Image`, PDF and PNG through the platform image type) is deleted and treated as a miss. `FakeBrandAssetService` returns nil, or seeded assets in tests.
  - `EnvironmentValues.brandAssets` (default `FakeBrandAssetService()`).
  - `AirlineLogo(airline: Airline?, code: String, size: CGFloat)`: `logoDark` in dark mode when present, else `logo`, else the monogram: `airline?.iata ?? String(code.prefix(2))` in white, bold, on `airline.colorPrimary` (or `TravelFacts.airlineTint(code)` when unknown), rounded square, corner radius `0.22 * size`. `static func monogram(airline: Airline?, code: String) -> String`.

- [ ] **Step 1: Write failing tests**: `monogramUsesIata`, `unknownAirlineMonogram` (Review Focus 1), `cacheHitSkipsNetwork`, `newVersionReplacesFile`, `sameVersionOnlyTouches`, `negativeCacheSkipsNetwork`, `networkFailureKeepsCachedFile`, `corruptFileIsDropped` (Review Focus 5), `darkModePicksDarkVariant`, with a fake transport counting requests and an injected clock.
- [ ] **Step 2:** Run. FAIL. **Step 3:** Implement. **Step 4:** Run. PASS; snapshot `docs/screens/components/AirlineLogo.png` (twelve airlines as monograms and as seeded fake logos, light and dark).
- [ ] **Step 5:** Commit `feat(app): versioned brand cache and airline logos`.

### Task 11: Aircraft side views (our renderer), first families

**Files:**
- Create: `UI/Aircraft/AircraftGeometry.swift`, `UI/Aircraft/Families/{A320Family,A350,B737,B737Max,B777,B787,Generic}.swift`, `UI/Aircraft/AircraftSideView.swift`, `Tests/FlightKitTests/AircraftGeometryTests.swift`, `Tests/FlightKitTests/AircraftSnapshotTests.swift`
- Modify: `Scripts/compare.py` (Set 2 support)

**Interfaces:**
- Produces: `enum AircraftLayer: Int, CaseIterable, Sendable { case gearFar, wingFar, engineFar, fuselage, windows, doors, wing, engine, tail, gear }` (draw order); `struct AircraftGeometry: Sendable { family: AircraftFamily; lengthM: Double; heightM: Double; layers: [AircraftLayer: [Path]]; finBox: CGRect /* logo slot, metres */; cheatlineBand: ClosedRange<Double>; titleAnchor: CGPoint }`, all paths in metres, x from the nose (0) aft, y from the ground up, nose to the left. `static func geometry(_ family: AircraftFamily) -> AircraftGeometry` (families without a drawing yet use `Generic.narrowbody` or `Generic.widebody` by `isWidebody`); `static func geometry(type: AircraftType?) -> AircraftGeometry` (nil gives `Generic.narrowbody`).
- `AircraftSideView(type: AircraftType?, livery: Livery? = nil, style: AircraftStyle = .livery)`, `enum AircraftStyle { case livery, blueprint }`; aspect ratio from `lengthM / heightM`. This task draws `.livery` with the plain scheme (white top, light grey belly, grey engines).
- Dimensions from the manufacturers' public airport planning documents (overall length, height, fuselage diameter, door count, window pitch about 0.53 m), drawn in our own line style. A320 family covers A319, A320, A321 (length per type).
- `compare.py`: a `V2_DIR` default `.superpowers/ref-v2` and `V2_REFS: dict[str, list[tuple[int, box]]]` keyed by our render name; `python3 Scripts/compare.py v2-<name>` writes `docs/screens/compare/v2-<name>.png`. Step 1 copies the 25 refs from `/private/tmp/claude-501/-Users-quentin--claude-spares-spare-mOGsw7/0af5a008-9882-4886-a712-efb5c5b0783e/scratchpad/ref/v2/` into `.superpowers/ref-v2/` (ignored by git; never commit reference images). If that folder is gone, stop and ask the owner for the originals.

- [ ] **Step 1:** Copy the refs; add Set 2 support to `compare.py`.
- [ ] **Step 2: Write failing tests**: `aspectMatchesDimensions` (each of `a320, a350, b737, b737max, b777, b787`: drawn bounding box width over height within 3% of the table in the test), `everyLayerPresent` (fuselage, windows, doors, wing, engine, tail, gear non-empty), `unknownTypeFallsBackToGeneric` (Review Focus 1), `a321LongerThanA319`.
- [ ] **Step 3:** Run. FAIL. **Step 4:** Implement. **Step 5:** Run. PASS. Render `docs/screens/aircraft/<family>.png` (plain) and compare the B777 and B787 against the plane crops of refs 33 and 52 (`v2-aircraft-b777`, `v2-aircraft-b787`).
- [ ] **Step 6:** Commit `feat(app): aircraft side views for six families`.

### Task 12: Liveries (derived from brand colours, small hand seed) and AircraftImage

**Files:**
- Create: `Models/Livery.swift`, `UI/Aircraft/LiveryRenderer.swift`, `UI/Aircraft/AircraftImage.swift`, `Resources/Reference/livery_seed.json`, `Tests/FlightKitTests/LiveryTests.swift`
- Modify: `UI/Aircraft/AircraftSideView.swift`, `App/ReferenceData.swift` (`func livery(_ icao: String) -> Livery`), `Tests/FlightKitTests/AircraftSnapshotTests.swift`

**Interfaces:**
- Produces:
  - `struct Livery: Codable, Sendable, Hashable { airline: String; fuselageTop: HexColor; belly: HexColor; bellySplit: Double /* fraction of fuselage height from the bottom */; cheatline: [Stripe]; tail: TailPaint; engines: HexColor; winglets: HexColor?; title: LiveryTitle?; static let plain: Livery; static func derived(from airline: Airline) -> Livery }`, `struct Stripe: Codable, Sendable, Hashable { color: HexColor; from: Double; to: Double /* fractions of fuselage height */; sweep: Double /* degrees */ }`, `enum TailPaint: Codable, Sendable, Hashable { case solid(HexColor), gradient([HexColor]), split(top: HexColor, bottom: HexColor, at: Double) }`, `struct LiveryTitle: Codable, Sendable, Hashable { text: String; color: HexColor; weight: String /* "semibold" | "bold" | "heavy" */; tracking: Double }`, `typealias HexColor = String` (`#RRGGBB`).
  - `Livery.derived(from:)`: white top, light grey belly at 0.3, tail solid `colorPrimary`, engines `colorPrimary`, one cheatline stripe in `colorSecondary` at 0.30 to 0.36 when present, title the airline name in `colorPrimary`. `ReferenceData.livery(_:)` returns the seed entry when one exists, else `derived`, else `.plain` for an unknown airline.
  - `livery_seed.json`: hand-tuned entries for `UAL`, `AFR`, `RYR` only (one widebody-led, one mixed, one narrowbody low-cost scheme), the quality bar the derived liveries are compared against and the fixtures for renderer tests. Colours from public photos of the current schemes; title text set in our font.
  - Renderer: `AircraftSideView(.livery)` fills each layer from the livery (top, belly and stripes clipped to the fuselage path), sets the title at `titleAnchor`, and draws the `tail` brand asset inside `finBox` only when `BrandAssetService` returns one (no monogram on fins).
  - `AircraftImage(airline: Airline?, type: AircraftType?, height: CGFloat)`: the provider side view (`BrandAssetService.asset(icao, .sideView, type: type.id)`) when cached or fetched, else `AircraftSideView(type:livery:)` with `ReferenceData.livery`. Every screen that shows an aircraft in colour uses `AircraftImage`; blueprint drawings always use our renderer.
- Snapshot matrix: seed airlines on the families present after Task 11 (UAL `a320 b737 b737max b777 b787`, AFR `a320 a350 b777 b787`, RYR `b737 b737max`) and derived liveries for `DLH, ACA, TRA, BEL, FLE` on one family each, to `docs/screens/liveries/<ICAO>-<family>.png` and `docs/screens/liveries/sheet.png`.

- [ ] **Step 1: Write failing tests**: `seedDecodes`, `derivedUsesBrandColors`, `derivedWithoutSecondaryHasNoStripe`, `unknownAirlineIsPlain`, `stripesInsideFuselage` (`0 <= from < to <= 1`), `noFinLogoWithoutAsset`, `aircraftImagePrefersProvider` and `aircraftImageFallsBackToRenderer` (seeded `FakeBrandAssetService`).
- [ ] **Step 2:** Run. FAIL. **Step 3:** Implement. **Step 4:** Run. PASS; render the matrix; compare the United B777 against ref 33's plane (`v2-livery-ual-b777`).
- [ ] **Step 5:** Commit `feat(app): liveries from brand colours and provider side views`.

### Task 13: Blueprint line style

**Files:**
- Create: `UI/Aircraft/Blueprint.swift`, `Tests/FlightKitTests/BlueprintTests.swift`
- Modify: `UI/Aircraft/AircraftSideView.swift`, `UI/Theme.swift`

**Interfaces:**
- Produces: `AircraftSideView(style: .blueprint)` strokes every layer at 1 pt in `Theme.blueprintInk` with no fill; `BlueprintTail(type: AircraftType?, registration: String)` draws the aft fuselage and fin from the same geometry at 2.5x, with the registration lettered on the aft fuselage in a monospaced font; `CabinPlan(classes: SeatClassCounts, favourite: String?)` a top view of a generic cabin with a class bar (Eco, Eco+, Business, First and their counts) and three seat glyphs (window, middle, aisle) with counts; `BlueprintPanel<Content>` the blue panel with a fine grid. Theme tokens: `blueprint` (panel), `blueprintGrid`, `blueprintInk`, `aircraftPage` (light blue page gradient), sampled from refs 45 to 51.
- `SeatClassCounts` and `PositionCounts` are the Swift records generated from Task 5.

- [ ] **Step 1: Write failing tests**: `blueprintHasNoFill` (render to a bitmap, interior pixel equals the panel colour), `tailUsesSameGeometry` (fin box scaled 2.5x), `unknownFamilyBlueprint` renders.
- [ ] **Step 2:** Run. FAIL. **Step 3:** Implement. **Step 4:** Run. PASS; compare `v2-blueprint-cabin` (ref 50) and `v2-blueprint-tail` (ref 47).
- [ ] **Step 5:** Commit `feat(app): blueprint aircraft drawings`.

### Task 14: Remaining aircraft families

**Files:**
- Create: `UI/Aircraft/Families/{A220,A330,A380,B747,B757,B767,EJet,CRJ,ATR}.swift`
- Modify: `UI/Aircraft/AircraftGeometry.swift`, `Tests/FlightKitTests/AircraftGeometryTests.swift`, `Tests/FlightKitTests/AircraftSnapshotTests.swift`

**Interfaces:**
- Produces: `AircraftGeometry.geometry(_:)` for every `AircraftFamily` except `.other`, which keeps the generic shapes. ATR draws propellers in the engine layer; the CRJ and E-Jets keep their engine and tail layouts (rear engines and T-tail for the CRJ).
- Adds to the livery snapshot matrix: UAL `b757 b767`, AFR `a220 a330` (seed liveries), ACA `a220`, BEL `a330`, DLH `a380 b747` (derived).

- [ ] **Step 1:** Extend `aspectMatchesDimensions` and `everyLayerPresent` to all fifteen families; add `crjHasRearEngines`. **Step 2:** Run. FAIL. **Step 3:** Implement. **Step 4:** Run. PASS; render plain, livery and blueprint for each new family.
- [ ] **Step 5:** Commit `feat(app): side views for the remaining families`.

### Task 15: Flight detail, part 1 (header, times, tiles, notes)

**Files:**
- Create: `UI/Detail/DetailHeader.swift`, `UI/Detail/DepartArrive.swift`, `UI/Detail/DetailTiles.swift`, `Tests/FlightKitTests/DetailPart1Tests.swift`
- Modify: `Stores/FlightDetailStore.swift`, `UI/Screens/FlightDetailView.swift`, `Tests/FlightKitTests/ScreenSnapshotTests.swift`, `Scripts/compare.py`

**Interfaces:**
- Consumes: `FollowDetails`, `FlightService.followDetails/saveFollowDetails` (Task 3), `AirlineLogo` (Task 10).
- Produces:
  - `FlightDetailStore`: `details: FollowDetails?` (nil when not followed), `isSavingDetails: Bool`, `detailsError: APIError?`, `func saveDetails(_ new: FollowDetails) async` (optimistic, restores the previous value on failure and sets `detailsError`).
  - `DetailFacts.headerLine(_ f: Flight, origin: Airport?) -> String`: `"UA 990 · FRI, 30 OCT"` (airline code, space, number; weekday, day, month in the origin's zone, uppercased).
  - `DetailFacts.countdown(_ f: Flight, destination: Airport?, now: Date) -> String`: before gate departure `"Departs in 1 day"` / `"Departs in 3 days"` (whole days from 24 h), `"Departs in 3h 20m"`, `"Departs in 12m"`; in the air `"Arrives in 2h 05m"`; landed or arrived `"Landed"`; canceled `"Canceled"`; diverted `"Diverted to OAK"` (IATA of the actual airport, else its ICAO).
  - `DetailFacts.dayMarker(departure: Date, depTz: TimeZone, arrival: Date, arrTz: TimeZone) -> String?`: `"+1"`, `"+2"`, `"-1"`, nil on the same local date. `DetailFacts.isOvernight(...)` true only when the marker is positive.
  - `DetailFacts.timeWord(scheduled: Date?, estimated: Date?, actual: Date?) -> String`: `"Actual"`, `"Estimated"` (estimate differs from schedule by a minute or more), else `"Scheduled"`.
  - `DetailHeader(flight:origin:destination:airline:onClose:)`, `DetailBottomBar(shareText:notify:onNotify:menu:)` with share, bell (hidden when not followed, toggles `setNotify`) and a menu: "Stop Tracking", "Copy Flight Number", "Report a Data Issue". Share text: `"UA 990 San Francisco to Paris, departs Fri 30 Oct 15:20 SFO"`.
  - `DepartArrive(flight:origin:destination:now:)`: airport link rows `"SFO · San Francisco Intl. >"`, big local time, time word, gate badge (yellow with an arrow glyph when assigned, grey "Gate --" otherwise), terminal; the middle line `"10h 55m · 8,965 km · Overnight"` (distance in the user's unit).
  - `DetailTiles(details:onEdit:)`: "Booking Code" and "Seat" tiles ("Tap to edit" when empty); a `PasteButton` on the booking tile accepts text that normalizes. Edit sheets: booking code field; seat field plus `SeatClass` and `TripReason` segmented pickers; notes `TextEditor` (2000 characters). Inline errors: `"Use 5 to 8 letters or digits"`, `"Use a row and a letter, like 23A"`.
  - Section 11 "Notes" card (tap to edit) at its place near the bottom of the screen.
- The v1 notify switch row is removed (the bell replaces it); `StatusNotice` stays for canceled and diverted.

- [ ] **Step 1: Write failing tests**: `headerLine`, `countdownCases` (each copy above), `dayMarkerAcrossDateLine` (SFO 15:20 to CDG gives `+1`; HND 17:00 to SFO 09:30 same UTC day gives `-1`; Review Focus 2), `overnightOnlyWhenPositive`, `timeWordCases`, `saveDetailsRollsBack` and `invalidSeatNotSent` (Review Focus 3), `clearingStoresNil`, `tilesHiddenWhenNotFollowed`.
- [ ] **Step 2:** Run. FAIL. **Step 3:** Implement. **Step 4:** Run. PASS.
- [ ] **Step 5:** Render `flight-detail-v2-top` and `flight-detail-v2-notes`; compare with refs 35 and 34 (`v2-detail-top`) and 29 (`v2-detail-notes`); fix visible differences.
- [ ] **Step 6:** Commit `feat(app): flight detail header, times, booking and seat`.

### Task 16: Flight detail, part 2 (Good to Know, timetable, airline, history, updates)

**Files:**
- Create: `UI/Detail/GoodToKnow.swift`, `UI/Detail/Timetable.swift`, `UI/Detail/AirlineCard.swift`, `UI/Detail/RouteHistory.swift`, `Tests/FlightKitTests/DetailPart2Tests.swift`
- Modify: `Stores/FlightDetailStore.swift`, `App/AppEnvironment.swift` (`makeFlightDetailStore` passes `history`), `UI/Screens/FlightDetailView.swift`, `Scripts/compare.py`

**Interfaces:**
- Produces:
  - `FlightDetailStore.init(id:flights:airports:history:cache:)`; after `load()`, `loadExtras()` fills `originStats, destinationStats: DelayStats?` (departures for the origin, arrivals for the destination), `originWeather, destinationWeather: Weather?`, `routeHistory: RouteHistory?`; each failure only hides its row.
  - Good to Know rows, per airport block headed `"SFO >"` (opens the airport sheet): a disruption row only at `moderate` or `major` severity, title `"Delays at SFO"`, text `"Departures average 32m late right now. Tap for the airport's details."` (arrivals wording at the destination); a weather row `"Departure weather"` / `"Arrival weather"` with `"18°C and scattered clouds"` from `tempC` and `Sky(metar:).description` lowercased; the time zone row from `DetailFacts.timeZoneChange(origin:destination:arrival:) -> (title: String, text: String)?`: `("+8 hours time zone change", "10:15 arrival is 02:15 San Francisco time")`, half hours as `"+5h 30m"`, negative as `"-9 hours"`, nil when the offsets are equal at arrival.
  - `Timetable.rows(_ f: Flight) -> [TimetableRow]` with `TimetableRow { section: .depart | .arrive | .totals; title: String; scheduled: String; other: String; otherLabel: String /* "Estimated" | "Actual" */; level: DelayLevel? }` for, in order: Gate Departure (out), Taxi (off minus out), Take Off (off), Land (on), Taxi (in minus on), Gate Arrival (in), Air Time (on minus off), Total Time (in minus out). Times in the airport's zone, spans like `"33m"` or `"10h 55m"`, `"--"` when unknown. Subtitle `"Scheduled, estimated and actual times"`.
  - `AirlineCard(airline:)`: logo, name, alliance title, buttons Phone (`tel:`), Website, X, Facebook (each hidden when nil), then ATC Callsign, ICAO, IATA. Hidden when the airline is unknown.
  - `struct RouteHistory: Equatable { flights: Int; distanceKm: Int; minutes: Int; recent: [PastFlight] /* newest 2 */; static func compute(_ past: [PastFlight], origin: String, destination: String) -> RouteHistory? }` counting both directions, canceled excluded, nil when zero. Card title `"Your history on this route"`, subtitle `"SFO → CDG"` in the current direction; recent rows show logo, local date, ident, block time, `"F-GZND · Boeing 777-300ER"`.
  - Updates card: `"Updates"`, `"3 updates for this flight"`, every event, never blurred.
  - Report link: `DetailFacts.reportURL(_ f: Flight) -> URL` = `mailto:support@somalabs.me?subject=<percent-encoded "Soma Flight data issue: UA990 2026-10-30">`, label `"Report a Data Issue"`.

- [ ] **Step 1: Write failing tests**: `timeZoneChangePositive`, `timeZoneChangeNegative` (Review Focus 2), `timeZoneChangeHalfHour`, `timeZoneChangeNilSameOffset`, `timetableRowsFullAndSparse` (all `"--"` for the sparse fixture), `timetableColours`, `routeHistoryBothDirections`, `routeHistoryNilWhenEmpty`, `disruptionRowOnlyWhenModerateOrMajor`, `reportURLEncodes`, `extrasFailureHidesOnlyThatRow`.
- [ ] **Step 2:** Run. FAIL. **Step 3:** Implement. **Step 4:** Run. PASS.
- [ ] **Step 5:** Render and compare with refs 33 and 34 (Good to Know), 31 and 32 (timetable), 30 (airline card, history), 29 (updates, report); fix differences.
- [ ] **Step 6:** Commit `feat(app): flight detail Good to Know, timetable, airline, history`.

### Task 17: Flight detail, part 3 (arrival forecast, where the plane is)

**Files:**
- Create: `Models/Insights.swift`, `Services/InsightsService.swift`, `UI/Detail/ForecastSection.swift`, `UI/Detail/PlaneSection.swift`, `Tests/FlightKitTests/InsightsTests.swift`
- Modify: `App/AppEnvironment.swift` (`insights`), `Services/Fakes/FakeServices.swift`, `Stores/FlightDetailStore.swift`, `UI/Screens/FlightDetailView.swift`

**Interfaces:**
- Produces:
  - `enum ForecastBucket: String, CaseIterable, Sendable { case early, onTime, late15, late30, late45, canceled, diverted; var title: String }` ("Early", "On time", "15m late", "30m late", "45m+ late", "Canceled", "Diverted"); early is arrival before schedule, on time 0 to 14 min, then 15 to 29, 30 to 44, 45 or more.
  - `struct ArrivalForecast: Sendable, Hashable { ident: String; days: Int; observed: Int; latePercent: Int; averageLateMinutes: Int; percents: [ForecastBucket: Int] /* sums to 100 */ }`, `struct InboundLeg: Sendable, Hashable, Identifiable { id: String; ident: String; originIata: String; destinationIata: String; scheduledOut: Date; scheduledIn: Date; status: FlightStatus; delayMinutes: Int }`.
  - `protocol InsightsService: Sendable { func arrivalForecast(ident: String) async throws(APIError) -> ArrivalForecast?; func inbound(_ id: Flight.ID) async throws(APIError) -> [InboundLeg] }`; `FakeInsightsService` deterministic from an FNV-1a hash of the ident (60 days, observed 20 to 40); `UnavailableInsightsService` returns nil and `[]`. `AppEnvironment.fake()` uses the fake, `live()` the unavailable one (no paid calls until the owner approves; no sample data in live builds).
  - `ForecastSection(forecast:)`: title `"Arrival forecast"`, subtitle `"UA 990 over the last 60 days"`, three figures (Late %, Average late, Observed flights) and seven bars coloured green, green, amber, amber, red, red with white hatch for canceled, purple for diverted. Hidden when nil.
  - `PlaneSection(flight:type:airline:inbound:)`: title `"Where is my plane?"`, aircraft name, `AircraftImage` (Task 12), and the inbound chain with "This flight" first, then legs newest first. Background is our own dark gradient (no stars, no illustration). Hidden when the type is unknown and the chain is empty.

- [ ] **Step 1: Write failing tests**: `fakeForecastDeterministic`, `percentsSumTo100`, `unavailableHidesSections`, `inboundOrder`.
- [ ] **Step 2:** Run. FAIL. **Step 3:** Implement. **Step 4:** Run. PASS; compare with refs 33 (forecast) and 32 and 33 (plane).
- [ ] **Step 5:** Commit `feat(app): arrival forecast and inbound plane on fakes`.

### Task 18: My Flights row, added toast, Add Flight frequently used

**Files:**
- Create: `UI/Screens/MyFlightRow.swift`, `Stores/FrequentlyUsed.swift`, `Tests/FlightKitTests/MyFlightRowTests.swift`, `Tests/FlightKitTests/FrequentlyUsedTests.swift`
- Modify: `UI/Screens/MyFlightsView.swift`, `UI/Screens/SearchView.swift`, `App/HomeModel.swift`, `Apps/iOS/RootTabView.swift`, `Apps/macOS/RootSidebarView.swift`

**Interfaces:**
- Produces:
  - `DetailFacts.countdownColumn(_ f: Flight, now: Date) -> (value: String, unit: String)`: `("1", "DAY")`, `("3", "DAYS")`, `("5", "HRS")`, `("1", "HR")`, `("40", "MIN")` before departure; `("2h", "LEFT")` in the air (remaining to arrival, minutes under an hour); `("", "LANDED")`, `("", "CANCELED")`, `("", "DIVERTED")`.
  - `MyFlightRow(flight:origin:destination:airline:now:)`: countdown column, logo, ident, date (`"Fri, Oct 30"`), route title, `"SFO 15:20"` and `"CDG 10:15"` with the `+1` marker. `MyFlightsView` lists rows instead of `FlightCard`s (delete `FlightCard` if nothing else uses it).
  - `HomeModel.toast: String?`, set to `"Added to My Flights"` after `didFollow()` and cleared after 3 s; `AddedToast(text:)` glass capsule over the tab pill.
  - `enum FrequentItem: Identifiable, Hashable { case airline(Airline, count: Int), airport(Airport, count: Int) }`, `FrequentlyUsed.compute(past: [PastFlight], followed: [Flight], reference: ReferenceData, lookup: (String) -> Airport?) -> [FrequentItem]`: top 2 airlines then top 2 airports by flights (each flight counts both its airports), ties by most recent flight then code; unknown codes skipped.
  - `SearchView` gains `frequent: [FrequentItem]`: section "Frequently used" (airline row: logo, name, `"F8 · FLE"`, tap sets the field to the IATA code plus a space and focuses it; airport row: flag, name, `"SFO · KSFO · San Francisco"`, tap runs the airport query), then section "More" with the existing "By route" row titled "Find by route". Placeholder stays `"AF84, CDG SFO, or AUS"`.

- [ ] **Step 1: Write failing tests**: `countdownColumnCases`, `frequentTopTwoEach`, `frequentTieBreak`, `frequentSkipsUnknown`, `toastClearsAfterThreeSeconds` (injected clock).
- [ ] **Step 2:** Run. FAIL. **Step 3:** Implement. **Step 4:** Run. PASS; compare with refs 36 (`v2-my-flights`) and 38 (`v2-add-flight`).
- [ ] **Step 5:** Commit `feat(app): My Flights rows, added toast, frequently used`.

### Task 19: Passport tab cards

**Files:**
- Create: `Stores/PassportDetail.swift`, `Services/AircraftFactsService.swift`, `Resources/Fakes/aircraft_facts.json`, `Tests/FlightKitTests/PassportDetailStoreTests.swift`
- Modify: `Stores/PassportStore.swift`, `UI/Screens/Passport/PassportCards.swift`, `UI/Screens/PassportView.swift`, `App/AppEnvironment.swift`, `App/HomeModel.swift`, `Services/Fakes/FakeServices.swift`

**Interfaces:**
- Consumes: Task 4 and 5 FFI (`computePassportDetail`, `computeAircraftStats`), `ReferenceData`.
- Produces:
  - `protocol AircraftFactsService: Sendable { func facts(_ registrations: [String]) async -> [AircraftFact] }`; `FakeAircraftFactsService` from `aircraft_facts.json` (registrations used by the fake history, deliveries 1994 to 2026); `SupabaseAircraftFactsService` reads table `aircraft` (empty today, so ages hide in live builds).
  - `PassportStore.init(history:cache:reference:facts:asOf:)` (`asOf` defaults to `Date.now`); `detail: PassportDetail` and `aircraft: AircraftStats` recomputed with `year`, flights mapped with `airline` normalized to ICAO through `ReferenceData.airline(_:)` (fallback the raw value) and countries from `PastFlight` (fallback the airport directory).
  - `enum FullPage: Identifiable { case passport, aircraftStats }`, `HomeModel.fullPage: FullPage?`.
  - `PassportCard` (ref 52): `"SOMA FLIGHT PASSPORT"` and our small subtitle `"TRAVEL RECORD"`, figures Flights (with `"27 long haul"`), Distance (with `"7.0x around the world"`), Flight time, Airports, Airlines, and a row button `"All flight stats >"` opening `.passport`. `DelaysCard` unchanged (no delay stats page in this release). `AircraftCard` (ref 52): `"Most flown aircraft"`, type name, `"8 flights"`, `AircraftImage` of the most flown type for the airline that flew it most for the user, and `"All aircraft stats >"` opening `.aircraftStats`.

- [ ] **Step 1: Write failing tests**: `detailMapsNamesToIcao`, `yearChangeRecomputes`, `mostFlownAirlineForLivery`, `liveFactsEmptyHidesAges`, `emptyHistoryCards`.
- [ ] **Step 2:** Run. FAIL. **Step 3:** Implement. **Step 4:** Run. PASS; compare with refs 52 and 53 (`v2-passport-tab`).
- [ ] **Step 5:** Commit `feat(app): Passport tab cards with livery`.

### Task 20: Full Passport page, part 1 (header, flights, distance, time)

**Files:**
- Create: `UI/Screens/Passport/FullPassportView.swift`, `UI/Screens/Passport/PassportMap.swift`, `Scripts/world/build_land.py`, `Resources/Reference/world_land.json`, `Stores/PassportFacts.swift`, `Tests/FlightKitTests/FullPassportTests.swift`
- Modify: `UI/Theme.swift`, `Apps/iOS/RootTabView.swift` (`fullScreenCover` for `HomeModel.fullPage`)

**Interfaces:**
- Produces:
  - Theme tokens `passportPage`, `passportBar`, `passportChip`, `passportAccent` sampled from refs 37 to 44.
  - `FullPassportView(store: PassportStore, lookup:, onClose:)`: top bar (close, title `"Soma Flight Passport"`, share), year chips, then sections in ref order.
  - `PassportMap(routes: [(Airport, Airport)], airports: [Airport], countries: [String])`: flat equirectangular map from `world_land.json` (Natural Earth 1:110m land, public domain, simplified by `build_land.py` with Douglas-Peucker at 0.15 degrees, rounded to 2 decimals, under 150 KB), great-circle arcs from `greatCircle`, airport dots, a marquee ticker of flown IATA codes separated by plane glyphs, and a row of overlapping round flags for visited countries.
  - `PassportFacts.mrz(name: String?, year: Int?, flights: Int, issued: Date) -> [String]`: two lines of exactly 44 characters from `[A-Z0-9<]`, line 1 `P<SOMAFLIGHT<<` plus the name (letters only, default `TRAVELLER`) padded with `<`, line 2 the scope (`ALLTIME` or the year), the flight count and the issue date `YYMMDD`, padded with `<`. Drawn as the strip under the passport card.
  - Sections with our copy: "Flights" (total big, `"14 domestic"`, `"43 international"`, `"27 long haul"`, segmented `Year | Month | Weekday` bar chart from `perYear`, `perMonth`, `perWeekday`); "Flight distance" (km big, mi under, `"Average distance: 4,913 km"`, three ratio bars with SF Symbols `globe.americas.fill`, `moon.fill`, `sun.max.fill` and `"7.0x around the Earth"`, `"0.7x to the Moon"`, `"0.06x around the Sun"`, shortest and longest flight rows with logo, cities, ident and date, km); "Flight time" (`"359h 8m"` big; Days, Weeks, Months (days / 30.44), Years (days / 365.25) to one or two decimals as in ref 41; Avg. flight time, In air, Taxiing; shortest and longest by time).
  - `SectionShareButton(title:content:)`: a capsule "Share" that shares the section rendered by `ImageRenderer` through `ShareLink`.

- [ ] **Step 1: Write failing tests**: `mrzLinesAre44`, `mrzOnlyAllowedCharacters` (accented and spaced names), `mrzDefaultName`, `ratioCopy` (`7.0x`, `0.7x`, `0.06x` for 280,017 km), `timeUnits` (21,548 minutes gives 15.0 days, 2.1 weeks, 0.5 months, 0.04 years), `landJsonUnder150KB`, `sparseHidesShortestLongest`.
- [ ] **Step 2:** Run. FAIL. **Step 3:** Run `python3 Scripts/world/build_land.py <ne_110m_land.geojson> Packages/FlightKit/Sources/FlightKit/Resources/Reference/world_land.json`, implement. **Step 4:** Run. PASS.
- [ ] **Step 5:** Render `passport-full-1..3` (dark) and a sparse history; compare with refs 42 and 44 (header), 37 (flights), 41 (distance), 39 and 43 (time).
- [ ] **Step 6:** Commit `feat(app): full Passport header, flights, distance and time`.

### Task 21: Full Passport page, part 2 (airports, airlines, routes, countries)

**Files:**
- Create: `UI/Screens/Passport/PassportLists.swift`, `Tests/FlightKitTests/PassportListsTests.swift`
- Modify: `UI/Screens/Passport/FullPassportView.swift`

**Interfaces:**
- Produces:
  - `RankedBars(items: [RankedBar], showMore: Binding<Bool>)` with `RankedBar { id: String; label: AnyView or code text; value: Int; caption: String }`: 8 rows, then all after "Show more".
  - "Top visited airports" (`"22 total airports"`, note `"A stop of less than 8 hours between two flights counts as one visit."`, IATA labels), "Top airlines" (`"8 total airlines"`, Flights or Distance toggle, `AirlineLogo` labels), "Top routes" (`"44 total routes"`, Flights or Distance toggle, `"CDG-SFO"` IATA labels), "Countries and territories" (`"11 total"`, flag, country name, `"37 flights"`, three then Show more), and the regions grid in `WorldRegion.gridOrder` with visited count and `visited * 100 / total` rounded half up percent.

- [ ] **Step 1: Write failing tests**: `regionPercent`, `routeLabelsUseIata` (falls back to ICAO), `showMoreRevealsAll`, `distanceToggleUsesDistanceTally`.
- [ ] **Step 2:** Run. FAIL. **Step 3:** Implement. **Step 4:** Run. PASS; compare with refs 39 (airports, airlines), 40 (routes), 38 and 37 (countries and regions grid).
- [ ] **Step 5:** Commit `feat(app): full Passport rankings, countries and regions`.

### Task 22: Aircraft Stats page

**Files:**
- Create: `UI/Screens/Aircraft/AircraftStatsView.swift`, `UI/Screens/Aircraft/AircraftPanels.swift`, `Tests/FlightKitTests/AircraftStatsViewTests.swift`
- Modify: `Apps/iOS/RootTabView.swift`

**Interfaces:**
- Produces: `AircraftStatsView(store: PassportStore, onClose:)` on the light blue page with year chips, sections in ref order:
  - Blueprint header panel: "Total aircraft" (`total_types`), "Newest aircraft" (`"7 months"`, delivery year), "Oldest aircraft" (`"29 years"`, year), chips `"56% Boeing"`, newest and oldest type; "Most flown aircraft" with type name, `"8 flights · 90 hours"` and its `AircraftImage`.
  - Frequented tail panel: `BlueprintTail`, `"Frequented tail"`, flights, registration, aircraft name from facts, type, age, country flag, airline logo.
  - Cabin panel: `CabinPlan` with class counts and `"Favourite seat 20D (2 times)"`.
  - "Aircraft types" (`"20 total aircraft"`, `"Counted by ICAO type, sub-types apart"`, Flights, Time, Distance toggle, `RankedBars`).
  - "Class and seat": donut by class (centre `"Top class"` / name), donut by seat position (`"Top seat"` / favourite seat), donut by reason (`"Top reason"` / title), each with a legend of count and percent.
  - "Most frequent tails" list, "Aircraft age" (`"10 years old"`, `"median age"`, bars by decade labelled `"1990s"`), "Newest aircraft" and "Oldest aircraft" cards with `AircraftImage`.
  - Age sections hide when there are no facts; class, seat and reason donuts hide when their counts are all zero.

- [ ] **Step 1: Write failing tests**: `ageCopy` (months under 12 as `"7 months"`, else years), `decadeLabels`, `donutHiddenWhenEmpty`, `factsMissingHidesAges` (Review Focus 4).
- [ ] **Step 2:** Run. FAIL. **Step 3:** Implement. **Step 4:** Run. PASS.
- [ ] **Step 5:** Render `aircraft-stats-1..4` and a sparse case; compare with refs 51 (header), 50 (cabin), 47 and 48 (tails, donuts), 49 (types), 45 and 46 (age, newest, oldest).
- [ ] **Step 6:** Commit `feat(app): Aircraft Stats page`.

### Task 23: macOS adaptations

**Files:**
- Modify: `Apps/macOS/RootSidebarView.swift`, `Apps/macOS/SomaFlightMacApp.swift`, `UI/Screens/FlightDetailView.swift`, `UI/Detail/DetailHeader.swift`, `UI/Detail/DetailTiles.swift`, `Scripts/compare.py`

**Interfaces:**
- Produces: in the 360 pt panel the detail's bottom bar becomes three buttons in the panel header; edit sheets present as popovers anchored on their tile; the full Passport and Aircraft Stats open as sheets over the main window sized 720 x 820, with the same content at `metricsScale` 1.0; `PasteButton` and `mailto:` work unchanged. No new Mac-only views.

- [ ] **Step 1:** Implement. **Step 2:** `xcodebuild -scheme SomaFlight-macOS -destination 'platform=macOS' build` succeeds with no warnings. **Step 3:** Run with `-useFakes`, capture detail, full Passport and Aircraft Stats into `docs/screens/mac/`, compare against the Mac references 25 to 27 for chrome (no Mac versions of refs 29 to 53 exist) and against our iOS renders for content.
- [ ] **Step 4:** Commit `feat(macos): v1.1 screens in the sidebar and sheets`.

### Task 24: Final compare pass

**Files:**
- Modify: `Scripts/compare.py`, `Packages/FlightKit/Tests/FlightKitTests/FinalSnapshotTests.swift`, `docs/screens/**`, `docs/app-store-checklist.md`

- [ ] **Step 1:** `SNAPSHOTS=1 swift test --package-path Packages/FlightKit --filter "ComponentSnapshotTests|FinalSnapshotTests"`, then `python3 Scripts/compare.py` for every `v2-*` entry (one per reference 29 to 53), dark and light, plus sparse, canceled and diverted detail states.
- [ ] **Step 2:** Run the iOS app on the iPhone 17 Pro simulator with `-useFakes`, capture each new screen into `docs/screens/ios/` and compare as `ios-*` entries.
- [ ] **Step 3:** Fix the visible differences found (layout, spacing, type, colour). Grep the package and docs for the reference app's name and for the em dash character; both must return nothing.
- [ ] **Step 4:** Add to `docs/app-store-checklist.md` the owner actions from this plan's header: logo licence signed and `LOGO_PROVIDER`, `AIRHEX_KEY` set; side view provider chosen, licensed, its adapter written and `SIDE_VIEW_PROVIDER` set; owner or counsel confirms showing airline names, logos and liveries (spec 4.3 legal note); AeroAPI cost approved before the paid sections are wired; acknowledgements present.
- [ ] **Step 5:** Full suites: `swift test --package-path Packages/FlightKit`, `cargo test --manifest-path core/Cargo.toml`, `deno test -A supabase/functions supabase/scripts`, `supabase test db`, both app builds. All PASS.
- [ ] **Step 6:** Commit `chore(app): v1.1 compare pass`.
