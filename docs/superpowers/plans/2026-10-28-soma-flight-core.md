# Soma Flight Core (Rust) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One Rust crate, `flightcore`, holding the pure logic that server and app must agree on (geo, delay stats, flight category, Passport stats), shipped as WASM for the Supabase edge functions and as an xcframework with Swift bindings for the Apple apps.

**Architecture:** `core/flightcore` is a plain Rust library with no I/O. Two thin binding crates wrap it: `core/flightcore-wasm` (wasm-bindgen, JSON in and out through serde) for Deno, and `core/flightcore-ffi` (UniFFI proc macros) for Swift. A build script turns the FFI crate into `FlightCoreFFI.xcframework` plus generated Swift, consumed by the `FlightKit` package as a binary target.

**Tech Stack:** Rust 1.99 (edition 2024), serde, serde_json, chrono, chrono-tz, wasm-bindgen + wasm-pack (`--target deno`), UniFFI 0.29+, xcodebuild `-create-xcframework`, Swift 6.

**Spec:** `docs/superpowers/specs/2026-10-28-soma-flight-v1-design.md` (owner decision 2026-10-28: Rust shared core + Swift app)

## Global Constraints

- `flightcore` has no I/O, no network, no clock reads: time comes in as arguments.
- Results must be byte-identical between the WASM and Swift bindings for the same input (one shared JSON fixture set under `core/fixtures/`).
- Delay rules, exactly: on time = delay under 15 minutes; `severity` is `major` when average delay is 45 minutes or more or cancellations are 10% or more, `moderate` when average delay is 15 minutes or more, else `normal`.
- Flight category, FAA thresholds exactly: LIFR ceiling under 500 ft or visibility under 1 sm; IFR under 1000 ft or under 3 sm; MVFR 1000 to 3000 ft or 3 to 5 sm; else VFR. Missing ceiling counts as unlimited.
- Long haul = distance 4000 km or more. Canceled past flights are excluded from flights, distance, and time.
- Distance: haversine on a sphere of radius 6371.0088 km, rounded to the nearest km where an integer is stored.
- Apple targets: `aarch64-apple-ios`, `aarch64-apple-ios-sim`, `aarch64-apple-darwin`, `x86_64-apple-darwin`. watchOS and visionOS targets are added with their shells later.
- No em dashes in code, comments, or docs.

## Review Focus

1. **NaN or negative values** (empty board, arrival before departure from bad provider data): never NaN in JSON, delays below zero count as on time. Test in Task 2.
2. **Antimeridian routes** (Tokyo to San Francisco): arc longitudes stay continuous. Test in Task 1.
3. **Same input, two bindings**: WASM and Swift outputs equal on every shared fixture. Test in Tasks 4 and 5.
4. **Year filter at a time zone boundary**: a flight departing 23:30 local on 31 December counts in that year, not the next. Test in Task 3.
5. **Unknown enum strings from the provider** (a new status): decode to `unknown`, never a panic across FFI. Test in Task 2.

---

## File Structure

```
core/
  Cargo.toml                         workspace
  fixtures/*.json                    shared inputs and expected outputs
  flightcore/src/lib.rs              re-exports
  flightcore/src/geo.rs              distance_km, great_circle
  flightcore/src/delay.rs            BoardFlight, DelayStats, compute_stats
  flightcore/src/weather.rs          FlightCategory, flight_category
  flightcore/src/passport.rs         PastFlight, PassportStats, compute_passport
  flightcore/tests/fixtures.rs       runs core/fixtures
  flightcore-wasm/src/lib.rs         #[wasm_bindgen] JSON wrappers
  flightcore-ffi/src/lib.rs          #[uniffi::export] wrappers
  scripts/build-wasm.sh              wasm-pack to supabase/functions/_shared/flightcore/
  scripts/build-xcframework.sh       to Packages/FlightCoreFFI/
Packages/FlightCoreFFI/              Package.swift, FlightCoreFFI.xcframework, generated Swift
```

---

### Task 1: Workspace and geo

**Files:** Create `core/Cargo.toml`, `core/flightcore/Cargo.toml`, `src/lib.rs`, `src/geo.rs`, `core/fixtures/geo.json`, `core/flightcore/tests/fixtures.rs`

**Interfaces:**
- Produces: `#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)] pub struct Coord { pub lat: f64, pub lon: f64 }`; `pub fn distance_km(a: Coord, b: Coord) -> f64`; `pub fn great_circle(a: Coord, b: Coord, segments: u32) -> Vec<Coord>` (segments + 1 points, longitudes unwrapped so neighbours differ by less than 180 degrees).

- [ ] **Step 1:** Install targets: `rustup target add wasm32-unknown-unknown aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-darwin`; `cargo install wasm-pack`.
- [ ] **Step 2: Failing tests:** `distance_cdg_sfo` between 8900 and 9000; `distance_same_point_zero`; `great_circle_endpoints` (65 points for 64, ends equal inputs); `great_circle_antimeridian` HND to SFO, every neighbour pair differs by under 180 degrees of longitude (Review Focus 2); `geo.json` fixture cases pass.
- [ ] **Step 3:** `cargo test --manifest-path core/Cargo.toml`. Expected FAIL.
- [ ] **Step 4:** Implement (spherical interpolation, slerp).
- [ ] **Step 5:** Expected PASS. Commit `feat(core): workspace and geo`.

### Task 2: Delay stats and flight category

**Files:** Create `src/delay.rs`, `src/weather.rs`, `core/fixtures/delay_*.json`, `core/fixtures/category.json`

**Interfaces:**
- Produces:
  - `pub enum FlightStatus { Scheduled, Departed, EnRoute, Landed, Arrived, Canceled, Diverted, Unknown }` serde `snake_case`, unknown strings deserialize to `Unknown` (`#[serde(other)]`).
  - `pub struct BoardFlight { pub ident: String, pub operator: Option<String>, pub other_icao: String, pub status: FlightStatus, pub scheduled: Option<i64>, pub estimated: Option<i64>, pub actual: Option<i64> }` (epoch seconds; `other_icao` = destination for departures, origin for arrivals).
  - `pub struct HourBucket { pub hour: i64 /* epoch of hour start */, pub on_time: u32, pub late15: u32, pub late45: u32, pub canceled: u32, pub diverted: u32 }`, `pub struct RouteStat { pub icao: String, pub delayed: u32, pub canceled: u32 }`, `pub struct AirlineStat { pub operator: String, pub delayed: u32, pub canceled: u32 }`, `pub enum Severity { Normal, Moderate, Major }`.
  - `pub struct DelayStats { pub total: u32, pub on_time: u32, pub delayed15: u32, pub canceled: u32, pub avg_delay_minutes: f64, pub per_hour: Vec<HourBucket>, pub worst_routes: Vec<RouteStat>, pub worst_airlines: Vec<AirlineStat>, pub severity: Severity }` serialized camelCase.
  - `pub fn compute_stats(rows: &[BoardFlight]) -> DelayStats` (delay = (actual or estimated) minus scheduled, floored at 0; rows without scheduled are counted in `total` only; worst lists top 5 by delayed + canceled).
  - `pub enum FlightCategory { Vfr, Mvfr, Ifr, Lifr }` serialized `"VFR"` etc.; `pub fn flight_category(ceiling_ft: Option<i32>, visibility_sm: f64) -> FlightCategory`.
- [ ] **Step 1: Failing tests:** the 10-departure case (5 on time, 3 late 20, 1 late 50, 1 canceled): `on_time 5, delayed15 4, canceled 1, severity Moderate`, per-hour sums to 10; empty input gives zeros and `avg_delay_minutes == 0.0` (no NaN, Review Focus 1); actual before scheduled counts on time; `"holding"` status deserializes to `Unknown` (Review Focus 5); category cases `(None,10)=VFR, (800,10)=IFR, (2500,10)=MVFR, (300,0.5)=LIFR, (1000,3)=MVFR`.
- [ ] **Step 2:** Run. FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** PASS. Commit `feat(core): delay stats and flight category`.

### Task 3: Passport stats

**Files:** Create `src/passport.rs`, `core/fixtures/passport.json`

**Interfaces:**
- Produces: `pub enum PastFlightStatus { Completed, Canceled, Diverted }`; `pub struct PastFlight { pub departed_at: i64, pub tz: String, pub ident: String, pub origin_icao: String, pub destination_icao: String, pub airline: Option<String>, pub aircraft_type: Option<String>, pub distance_km: u32, pub block_minutes: Option<u32>, pub delay_minutes: u32, pub status: PastFlightStatus }`; `pub struct AircraftCount { pub aircraft_type: String, pub count: u32 }`; `pub struct PassportStats { pub flights: u32, pub long_haul: u32, pub distance_km: u64, pub flight_minutes: u64, pub airports: u32, pub airlines: u32, pub delay_lost_minutes: u64, pub avg_delay_minutes: u32, pub most_flown_aircraft: Option<AircraftCount>, pub routes: Vec<(String, String)> }`; `pub fn compute_passport(flights: &[PastFlight], year: Option<i32>) -> PassportStats` (year taken from `departed_at` in the flight's own `tz` via chrono-tz; ties for most flown broken alphabetically).
- [ ] **Step 1: Failing tests:** four flights, one canceled: `flights 3`, distance sum, unique airports, most flown; year filter; flight at 2025-12-31 23:30 America/Los_Angeles counts in 2025 (Review Focus 4); empty input all zeros and `None`.
- [ ] **Step 2:** FAIL. **Step 3:** Implement. **Step 4:** PASS. Commit `feat(core): Passport stats`.

### Task 4: WASM binding for Deno

**Files:** Create `core/flightcore-wasm/Cargo.toml`, `src/lib.rs`, `core/scripts/build-wasm.sh`, `supabase/functions/_shared/flightcore/` (generated, committed), `supabase/functions/_shared/flightcore_test.ts`

**Interfaces:**
- Produces JS exports (all JSON strings in, JSON strings out, errors as `{"error":"..."}` never a thrown panic): `distanceKm(aJson, bJson): number`, `greatCircle(aJson, bJson, segments): string`, `computeStats(rowsJson): string`, `flightCategory(ceilingFt: number | undefined, visibilitySm: number): string`, `computePassport(flightsJson, year?: number): string`. A typed TS wrapper `supabase/functions/_shared/flightcore.ts` exposes `computeStats(rows: BoardFlight[]): DelayStats` etc.
- [ ] **Step 1: Failing Deno test:** loads every `core/fixtures/*.json` case and asserts the wrapper output equals the expected JSON (Review Focus 3); malformed JSON returns an error object.
- [ ] **Step 2:** `deno test -A supabase/functions/_shared/flightcore_test.ts`. FAIL.
- [ ] **Step 3:** Implement binding and `build-wasm.sh` (`wasm-pack build core/flightcore-wasm --target deno --release --out-dir ../../supabase/functions/_shared/flightcore/pkg`). Build with `opt-level = "s"`; record the .wasm size in the commit message.
- [ ] **Step 4:** PASS. Commit `feat(core): WASM binding for edge functions`.

### Task 5: Swift binding (UniFFI xcframework)

**Files:** Create `core/flightcore-ffi/Cargo.toml`, `src/lib.rs`, `core/scripts/build-xcframework.sh`, `Packages/FlightCoreFFI/Package.swift`, `Packages/FlightCoreFFI/Sources/FlightCore/` (generated Swift), `Packages/FlightCoreFFI/Tests/FlightCoreTests/FixtureTests.swift`

**Interfaces:**
- Produces Swift (UniFFI records and enums, Swift naming): `distanceKm(a:b:) -> Double`, `greatCircle(a:b:segments:) -> [Coord]`, `computeStats(rows:) -> DelayStats`, `flightCategory(ceilingFt:visibilitySm:) -> FlightCategory`, `computePassport(flights:year:) -> PassportStats`. SwiftPM: library product `FlightCore` (Swift wrapper target) depending on binary target `FlightCoreFFI` at `FlightCoreFFI.xcframework`. Platforms iOS 26, macOS 26.
- [ ] **Step 1: Failing Swift test:** `FixtureTests` reads the same `core/fixtures/*.json` (copied as test resources by the build script) and asserts equality with expected outputs (Review Focus 3).
- [ ] **Step 2:** `swift test --package-path Packages/FlightCoreFFI`. FAIL.
- [ ] **Step 3:** Implement FFI crate and `build-xcframework.sh`: `cargo build --release` for the four Apple targets, `lipo` the two macOS slices, `uniffi-bindgen generate --language swift`, `xcodebuild -create-xcframework` with device, simulator, and macOS libraries plus headers and modulemap.
- [ ] **Step 4:** Run script, then tests. PASS. Commit `feat(core): Swift binding via UniFFI xcframework`.

## Changes to the other two plans (apply when this plan lands)

- Backend Task 7: `_shared/delay_stats.ts` and `flightCategory` in `_shared/weather.ts` become thin wrappers over `_shared/flightcore.ts`. The Task 7 stats and category tests stay as written and must pass through the wrapper.
- Backend Task 9: keep the SQL haversine in `archive_landed_flights()` (it runs inside Postgres) but add a pgTAP case that matches `core/fixtures/geo.json` within 1 km.
- App Task 1: `FlightKit` depends on `Packages/FlightCoreFFI` (`FlightCore` product).
- App Task 3: `greatCircle` and `distanceKm` call `FlightCore`; the Task 3 tests stay.
- App Task 4: `PassportStats.compute` maps `PastFlight` to the core record and calls `computePassport`; the Task 4 tests stay.
