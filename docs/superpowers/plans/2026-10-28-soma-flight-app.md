# Soma Flight App Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the Soma Flight app for iOS and macOS: globe home, My Flights, flight detail, search, airport sheet, Passport, settings, notifications, and Live Activity, on a shared `FlightKit` package.

**Architecture:** All logic lives in the `FlightKit` Swift package (models, service protocols with Supabase and fake implementations, `@Observable` stores, SwiftData cache, shared views, map layer). The iOS and macOS app targets are thin shells. Stores depend only on service protocols, so every task before Task 9 runs on fakes and does not need the backend.

**Tech Stack:** Rust core `flightcore` via `Packages/FlightCoreFFI` (see `docs/superpowers/plans/2026-10-28-soma-flight-core.md`), Swift 6 (strict concurrency), SwiftUI, iOS 26 and macOS 26, XcodeGen, `supabase-swift` 2.x, MapKit, Swift Charts, SwiftData, ActivityKit, WidgetKit, UserNotifications, AuthenticationServices, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-10-28-soma-flight-v1-design.md`
**Backend contract:** `docs/superpowers/plans/2026-10-28-soma-flight-backend.md` (function names, request and response shapes, error codes)

## Global Constraints

- Deployment targets: iOS 26.0, macOS 26.0. Swift 6 language mode, strict concurrency complete.
- Views talk only to stores. Stores talk only to service protocols.
- The app never calls AeroAPI or aviationweather.gov; only Supabase (PostgREST, Realtime, edge functions).
- Error codes from the backend, exactly: `provider_unavailable`, `not_found`, `rate_limited`, `plan_limit`, `unauthorized`.
- Data older than its TTL (boards and stats 5 min, weather 15 min, live flight 10 min) is shown dimmed with its age, never as current.
- Design match (owner request 2026-10-28): every screen matches the reference screenshots in `~/Desktop/Screenshot FLight app` closely: layout, hierarchy, spacing, type scale, colours, component shapes, sheet and tab bar behaviour. Excluded: the reference app's name, logo, icon, custom illustrations, and copy text. Each screen task ends with a side-by-side screenshot (reference left, ours right) saved under `docs/screens/compare/`, checked by the task reviewer.
- Dark first, light supported. Delay colours: on time green, 15 to 44 min late amber, 45 min or more and canceled red, diverted purple. Small caps section labels.
- Name and icon: Soma Flight only. No other product's name, marks, or copy.
- Location is not requested in v1.
- No em dashes in code, comments, or user-facing copy.
- Bundle ids: `me.somalabs.flight` (iOS and macOS app), `me.somalabs.flight.widgets` (Live Activity and widget extension).

## Review Focus

1. **User in a different time zone than the airports**: every time shows in the airport's local time with its zone abbreviation, and "in 2h 10m" countdowns use absolute instants. Test in Task 1 and Task 4.
2. **Network drops while a flight is live**: My Flights and flight detail keep the last state, show an offline banner and the data age, and recover when Realtime reconnects. Test in Task 5.
3. **Flight with missing fields** (no gate, no aircraft, no estimated times, no position): every screen renders with placeholders, no crash or empty card. Test in Task 1 (decoding) and Task 12 (snapshots).
4. **Followed flight later canceled or diverted**: card, detail, Live Activity, and Passport show the canceled or diverted state, and a diverted flight's map arc ends at the actual airport. Test in Task 4 and Task 11.
5. **Free user hits the 3-flight limit or the search rate limit**: a clear message naming the limit, the search field keeps its text, nothing is half-followed. Test in Task 4.

---

## File Structure

```
project.yml                                   XcodeGen definition
Packages/FlightKit/Package.swift
Packages/FlightKit/Sources/FlightKit/
  Models/        Flight.swift, FlightEvent.swift, Airport.swift, AirportBoard.swift, DelayStats.swift,
                 Weather.swift, PastFlight.swift, FlightStatus.swift, APIError.swift, LocalTime.swift
  Services/      FlightService.swift, AirportService.swift, AuthService.swift, HistoryService.swift,
                 PushService.swift, Supabase/SupabaseFlightService.swift, SupabaseAirportService.swift,
                 SupabaseAuthService.swift, SupabaseHistoryService.swift, SupabasePushService.swift,
                 Fakes/FakeServices.swift
  Stores/        SessionStore.swift, MyFlightsStore.swift, FlightDetailStore.swift, SearchStore.swift,
                 AirportStore.swift, PassportStore.swift, PassportStats.swift
  Cache/         CacheStore.swift
  Map/           GreatCircle.swift, GlobeMap.swift, FlightAnnotation.swift
  UI/            Theme.swift, DelayColor.swift, FlightCard.swift, FlightTimeline.swift, BoardRow.swift,
                 DelayChart.swift, PerformanceSplit.swift, WeatherBlock.swift, StaleBadge.swift, ErrorBanner.swift,
                 Screens/MyFlightsView.swift, FlightDetailView.swift, SearchView.swift, AirportView.swift,
                 PassportView.swift, SettingsView.swift, SignInView.swift
  LiveActivity/  FlightActivityAttributes.swift
Packages/FlightKit/Tests/FlightKitTests/      Swift Testing suites + Fixtures/*.json
Apps/iOS/        SomaFlightApp.swift, RootTabView.swift, AppDelegate.swift, Info.plist, PrivacyInfo.xcprivacy
Apps/macOS/      SomaFlightMacApp.swift, RootSidebarView.swift, Info.plist
Apps/Widgets/    FlightLiveActivity.swift, WidgetsBundle.swift
```

---

### Task 1: Project scaffold and models

**Files:**
- Create: `project.yml`, `Packages/FlightKit/Package.swift`, all files under `Models/`, `Tests/FlightKitTests/ModelDecodingTests.swift`, `Tests/FlightKitTests/Fixtures/flight_full.json`, `flight_sparse.json`, `board_kaus.json`, `stats_kaus.json`, `weather_kaus.json`, `Apps/iOS/SomaFlightApp.swift`, `Apps/macOS/SomaFlightMacApp.swift` (each shows a placeholder `Text("Soma Flight")`)

**Interfaces:**
- Produces (all `Codable, Sendable, Hashable`, decoded from the backend's snake_case JSON with `.convertFromSnakeCase` and ISO 8601 dates with fractional seconds):
  - `enum FlightStatus: String { case scheduled, departed, enRoute = "en_route", landed, arrived, canceled, diverted, unknown }` with unknown values decoding to `.unknown`
  - `struct Position { lat, lon: Double; altitudeFt: Int?; groundSpeedKt: Int?; heading: Double?; at: Date }`
  - `struct Flight: Identifiable { id: UUID; providerId: String; ident: String; operator: String?; originIcao, destinationIcao: String; originIata, destinationIata: String?; scheduledOut, scheduledIn: Date?; estimatedOut, estimatedIn, actualOut, actualOff, actualOn, actualIn: Date?; gateOrigin, gateDestination, terminalOrigin, terminalDestination, baggageBelt: String?; aircraftType, registration: String?; status: FlightStatus; position: Position?; updatedAt: Date }` plus computed `departureDelay: Duration?`, `arrivalDelay: Duration?`, `progress: Double` (0...1 from times, clamped)
  - `struct Airport: Identifiable { id: String /* icao */; iata: String?; name, city, country: String; lat, lon: Double; tz: String }` with `var timeZone: TimeZone`
  - `struct AirportBoard { icao: String; kind: BoardKind; fetchedAt: Date; stale: Bool; flights: [Flight] }`, `enum BoardKind: String { case departures, arrivals, stats, weather }`
  - `struct DelayStats` mirroring the backend `computeStats` output, `enum Severity: String { case normal, moderate, major }`
  - `struct Weather { metarRaw: String; tafRaw: String?; tempC: Double?; windDirDeg: Int?; windKt: Int?; gustKt: Int?; visibilitySm: Double?; ceilingFt: Int?; category: FlightCategory; observedAt: Date; forecast: [ForecastPeriod] }`, `enum FlightCategory: String { case VFR, MVFR, IFR, LIFR }`
  - `struct PastFlight: Identifiable { id: UUID; date: Date; ident: String; originIcao, destinationIcao: String; airline, aircraftType, registration, seat: String?; distanceKm: Int; blockMinutes: Int?; delayMinutes: Int; status: PastFlightStatus }`, `enum PastFlightStatus: String { case completed, canceled, diverted }`
  - `enum APIError: Error, Equatable { case providerUnavailable, notFound, rateLimited, planLimit, unauthorized, offline, decoding(String) }` with `init(code: String)`
  - `func localTime(_ date: Date, in tz: TimeZone, style: TimeStyle) -> String` returning for example `18:25 CDT` in 24 h style

- [ ] **Step 1:** Write `project.yml` (targets `SomaFlight-iOS`, `SomaFlight-macOS`, `SomaFlightWidgets` (empty for now), shared scheme per app, `FlightKit` local package) and `Package.swift` (platforms iOS 26, macOS 26; dependency `https://github.com/supabase/supabase-swift` from `2.0.0`). Run `xcodegen generate`. Expected: `SomaFlight.xcodeproj` created.
- [ ] **Step 2: Write failing tests** `ModelDecodingTests`:
  - `decodesFullFlight`: `flight_full.json` decodes, `status == .enRoute`, `gateOrigin == "B22"`, `position?.altitudeFt == 37000`.
  - `decodesSparseFlight`: `flight_sparse.json` (only id, provider_id, ident, origin_icao, destination_icao, status, updated_at) decodes with every optional nil (Review Focus 3).
  - `unknownStatusIsUnknown`: `"status":"holding"` decodes to `.unknown`.
  - `apiErrorFromCode`: `APIError(code: "plan_limit") == .planLimit`, unknown code becomes `.providerUnavailable`.
  - `localTimeUsesAirportZone`: 2026-10-23T23:25:00Z in `America/Chicago` gives `18:25 CDT` (Review Focus 1).
  - `progressClamps`: before departure 0, after arrival 1, midway about 0.5.
- [ ] **Step 3:** `swift test --package-path Packages/FlightKit`. Expected: FAIL.
- [ ] **Step 4:** Implement models. Fixtures copy the backend's response shapes.
- [ ] **Step 5:** Run tests. Expected: PASS. `xcodebuild -scheme SomaFlight-iOS -destination 'generic/platform=iOS Simulator' build` and the macOS scheme both succeed.
- [ ] **Step 6:** Commit `feat(app): project scaffold and models`.

### Task 2: Service protocols and fakes

**Files:**
- Create: `Services/FlightService.swift`, `AirportService.swift`, `AuthService.swift`, `HistoryService.swift`, `PushService.swift`, `Services/Fakes/FakeServices.swift`
- Test: `Tests/FlightKitTests/FakeServicesTests.swift`

**Interfaces:**
- Produces:
  - `protocol FlightService: Sendable { func lookup(_ query: FlightQuery) async throws(APIError) -> [Flight]; func followed() async throws(APIError) -> [Flight]; func follow(_ id: Flight.ID, notify: Bool) async throws(APIError); func unfollow(_ id: Flight.ID) async throws(APIError); func flight(_ id: Flight.ID) async throws(APIError) -> Flight; func events(_ id: Flight.ID) async throws(APIError) -> [FlightEvent]; func updates(for ids: [Flight.ID]) -> AsyncStream<Flight> }`
  - `enum FlightQuery: Sendable { case ident(String, date: Date), route(origin: String, destination: String, date: Date), airport(String) }` with `static func parse(_ text: String, date: Date) -> FlightQuery?` (`AF84`, `AF 84` give `.ident`; `CDG SFO`, `CDG-SFO` give `.route`; a lone 3 or 4 letter code gives `.airport`)
  - `protocol AirportService: Sendable { func airport(_ code: String) async throws(APIError) -> Airport; func board(_ code: String, _ kind: BoardKind) async throws(APIError) -> AirportBoard; func stats(_ code: String) async throws(APIError) -> (fetchedAt: Date, stale: Bool, departures: DelayStats, arrivals: DelayStats); func weather(_ code: String) async throws(APIError) -> (fetchedAt: Date, stale: Bool, weather: Weather) }`
  - `protocol AuthService: Sendable { var session: AsyncStream<UserSession?> { get }; func signInWithApple(idToken: String, nonce: String) async throws(APIError); func signInWithEmail(_ email: String) async throws(APIError); func signOut() async; func deleteAccount() async throws(APIError) }`, `struct UserSession: Sendable, Equatable { userId: UUID; email: String?; plan: Plan }`, `enum Plan: String { case free, pro }`
  - `protocol HistoryService: Sendable { func pastFlights() async throws(APIError) -> [PastFlight]; func export(_ format: ExportFormat) async throws(APIError) -> Data }`, `enum ExportFormat { case json, csv }`
  - `protocol PushService: Sendable { func register(deviceToken: Data, kind: PushTokenKind, flightId: Flight.ID?) async throws(APIError) }`, `enum PushTokenKind: String { case alert, liveActivity = "live_activity" }`
  - `FakeFlightService`, `FakeAirportService`, `FakeAuthService`, `FakeHistoryService`, `FakePushService`: `actor`s seeded from the Task 1 fixtures, with `var nextError: APIError?` to inject failures and `func push(_ flight: Flight)` to emit on `updates`.

- [ ] **Step 1: Write failing tests:** `FlightQuery.parse` cases above plus `"hello world"` returns nil; `fakeErrorInjection` (set `nextError = .rateLimited`, `lookup` throws `.rateLimited`, next call succeeds); `fakeUpdatesStream` emits a pushed flight.
- [ ] **Step 2:** Run. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run. Expected: PASS.
- [ ] **Step 5:** Commit `feat(app): service protocols and fakes`.

### Task 3: Theme, map layer, shared components

**Files:**
- Create: `UI/Theme.swift`, `UI/DelayColor.swift`, `UI/StaleBadge.swift`, `UI/ErrorBanner.swift`, `UI/FlightCard.swift`, `UI/FlightTimeline.swift`, `UI/BoardRow.swift`, `UI/DelayChart.swift`, `UI/PerformanceSplit.swift`, `UI/WeatherBlock.swift`, `Map/GreatCircle.swift`, `Map/GlobeMap.swift`, `Map/FlightAnnotation.swift`
- Test: `Tests/FlightKitTests/GreatCircleTests.swift`, `Tests/FlightKitTests/DelayColorTests.swift`

**Interfaces:**
- Produces:
  - `func greatCircle(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D, segments: Int = 64) -> [CLLocationCoordinate2D]`, `func distanceKm(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double`
  - `enum DelayLevel { case onTime, late, veryLate, canceled, diverted }`, `static func DelayLevel.for(delay: Duration?, status: FlightStatus) -> DelayLevel`, `extension DelayLevel { var color: Color }`
  - `struct GlobeMap: View { init(routes: [Route], planes: [FlightAnnotationModel], airports: [Airport], selection: Binding<MapSelection?>) }` using `Map` with `.mapStyle(.imagery(elevation: .realistic))`, `struct Route { from, to: CLLocationCoordinate2D; level: DelayLevel; isPast: Bool }`
  - Views: `FlightCard(flight:origin:destination:)`, `FlightTimeline(flight:origin:destination:)`, `BoardRow(flight:kind:airport:)`, `DelayChart(perHour:)`, `PerformanceSplit(stats:)`, `WeatherBlock(weather:)`, `StaleBadge(fetchedAt:ttl:)`, `ErrorBanner(error:retry:)`
  - `ErrorBanner` copy, exactly: `providerUnavailable` "Flight data is temporarily unavailable. Showing the last update."; `notFound` "No flight found. Check the number and date."; `rateLimited` "Too many searches. Try again in a few minutes."; `planLimit` "Free accounts follow up to 3 flights at a time."; `unauthorized` "Please sign in again."; `offline` "You're offline. Showing the last update."

- [ ] **Step 1: Write failing tests:**
  - `distanceCdgSfo`: between 8900 and 9000 km.
  - `greatCircleEndpoints`: first and last points equal the inputs; 65 points for 64 segments.
  - `greatCircleCrossesAntimeridian`: Tokyo to San Francisco longitudes stay continuous (no jump over 180 degrees between neighbours after normalisation used by `MapPolyline`).
  - `delayLevels`: nil and 10 min give `.onTime`, 20 min `.late`, 50 min `.veryLate`, status `.canceled` gives `.canceled`, `.diverted` gives `.diverted`.
- [ ] **Step 2:** Run. Expected: FAIL.
- [ ] **Step 3:** Implement. Views get `#Preview`s fed by the Task 1 fixtures, including the sparse flight.
- [ ] **Step 4:** Run tests. Expected: PASS. Build both app schemes.
- [ ] **Step 5:** Commit `feat(app): theme, globe map, shared components`.

### Task 4: Stores

**Files:**
- Create: `Stores/SessionStore.swift`, `MyFlightsStore.swift`, `FlightDetailStore.swift`, `SearchStore.swift`, `AirportStore.swift`, `PassportStore.swift`, `PassportStats.swift`
- Test: `Tests/FlightKitTests/StoresTests.swift`, `Tests/FlightKitTests/PassportStatsTests.swift`

**Interfaces:**
- Consumes: Task 2 protocols and fakes.
- Produces (all `@MainActor @Observable final class`):
  - `SessionStore(auth:)`: `session: UserSession?`, `start()`, `signOut()`, `deleteAccount() async`
  - `MyFlightsStore(flights:cache:)`: `live: [Flight]`, `upcoming: [Flight]`, `error: APIError?`, `lastUpdated: Date?`, `isOffline: Bool`, `load() async`, `startUpdates()`, `unfollow(_:) async`. Live = departed or en route; upcoming sorted by scheduled out.
  - `FlightDetailStore(id:flights:airports:)`: `flight: Flight?`, `events: [FlightEvent]`, `origin, destination: Airport?` (destination is the actual arrival airport when diverted), `load() async`
  - `SearchStore(flights:)`: `text: String`, `date: Date`, `results: [Flight]`, `error: APIError?`, `isSearching: Bool`, `search() async`, `follow(_:) async -> Bool`. On `planLimit` or `rateLimited`, `text` is kept and nothing is added to My Flights.
  - `AirportStore(code:airports:)`: `airport: Airport?`, `departures, arrivals: AirportBoard?`, `stats: (departures: DelayStats, arrivals: DelayStats)?`, `weather: Weather?`, `fetchedAt: [BoardKind: Date]`, `load() async`
  - `PassportStore(history:)`: `year: Int?` (nil = all time), `flights: [PastFlight]`, `stats: PassportStats`, `years: [Int]`, `load() async`
  - `struct PassportStats: Equatable { flights: Int; longHaul: Int; distanceKm: Int; flightTime: Duration; airports: Int; airlines: Int; delayLost: Duration; avgDelayMinutes: Int; mostFlownAircraft: (type: String, count: Int)?; routes: [(String, String)] }`, `static func compute(_ flights: [PastFlight], year: Int?, calendar: Calendar) -> PassportStats`. Long haul = distance 4000 km or more. Canceled flights count only toward `delayLost` zero and are excluded from flights, distance, and time.

- [ ] **Step 1: Write failing tests:**
  - `myFlightsSplitsLiveAndUpcoming`.
  - `myFlightsAppliesRealtimeUpdate`: fake pushes a gate change, `live[0].gateOrigin` updates.
  - `myFlightsCanceledShownAsCanceled` (Review Focus 4): pushed `.canceled` flight stays in the list with status canceled until archived.
  - `searchPlanLimitKeepsText` and `searchRateLimitKeepsText` (Review Focus 5): `text` unchanged, `error == .planLimit` / `.rateLimited`, followed list unchanged.
  - `detailDivertedUsesActualAirport`: diverted fixture to KOAK gives `destination?.id == "KOAK"`.
  - `passportStatsAllTime` on 4 fixture flights (one canceled): `flights 3`, distance sum, `airports` unique count, most flown aircraft.
  - `passportStatsYearFilter`: year 2025 includes only 2025 flights by local departure date.
  - `passportStatsEmpty`: all zeros, `mostFlownAircraft == nil`.
- [ ] **Step 2:** Run. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run. Expected: PASS.
- [ ] **Step 5:** Commit `feat(app): stores and Passport stats`.

### Task 5: Offline cache

**Files:**
- Create: `Cache/CacheStore.swift`
- Modify: `Stores/MyFlightsStore.swift`, `FlightDetailStore.swift`, `PassportStore.swift` (read cache first, write after success)
- Test: `Tests/FlightKitTests/CacheTests.swift`

**Interfaces:**
- Produces: `@ModelActor actor CacheStore { func save(flights: [Flight]) ; func flights() -> [Flight]; func save(past: [PastFlight]); func past() -> [PastFlight]; func savedAt(_ key: CacheKey) -> Date? }` storing encoded JSON blobs in a SwiftData `@Model CachedBlob { key: String @Attribute(.unique); data: Data; savedAt: Date }`. In-memory `ModelConfiguration` for tests.

- [ ] **Step 1: Write failing tests:**
  - `roundTripFlights` and `roundTripPast`.
  - `myFlightsOfflineShowsCache` (Review Focus 2): cache has 2 flights, fake throws `.offline`, store shows 2 flights, `isOffline == true`, `lastUpdated == savedAt`.
  - `myFlightsRecoversAfterOffline`: next `load()` succeeds, `isOffline == false`.
- [ ] **Step 2:** Run. Expected: FAIL.
- [ ] **Step 3:** Implement. `URLError` network codes map to `APIError.offline` in the Supabase services (Task 9); fakes throw it directly.
- [ ] **Step 4:** Run. Expected: PASS.
- [ ] **Step 5:** Commit `feat(app): offline cache`.

### Task 6: Screens

**Files:**
- Create: `UI/Screens/MyFlightsView.swift`, `FlightDetailView.swift`, `SearchView.swift`, `AirportView.swift`, `PassportView.swift`, `SettingsView.swift`, `SignInView.swift`

**Interfaces:**
- Consumes: Task 3 components, Task 4 stores.
- Produces: one view per screen, each taking its store: `MyFlightsView(store:onSelect:)`, `FlightDetailView(store:onAirport:)`, `SearchView(store:onFollowed:)`, `AirportView(store:)` with segmented Departures, Arrivals, Stats and filters for day, airline, and direction, `PassportView(store:)` with year chips, `SettingsView(session:units:)`, `SignInView(session:)`. Content per spec section 6 "Screens".

- [ ] **Step 1:** Build each view with `#Preview`s on fake stores: full data, sparse flight, error, stale data, empty state ("Add a flight to start tracking" with a search button), dark and light.
- [ ] **Step 2:** Run the previews through `xcodebuild build` for both schemes. Expected: success, no warnings under strict concurrency.
- [ ] **Step 3:** Commit `feat(app): screens`.

### Task 7: iOS shell

**Files:**
- Create: `Apps/iOS/RootTabView.swift`
- Modify: `Apps/iOS/SomaFlightApp.swift`

**Interfaces:**
- Produces: `RootTabView(env: AppEnvironment)` with the full-screen `GlobeMap` behind a resizable bottom sheet (`presentationDetents([.height(120), .medium, .large])`, background interaction enabled), floating tab bar for My Flights and Passport, a search button, and a gear in the sheet header. `struct AppEnvironment { flights: FlightService; airports: AirportService; auth: AuthService; history: HistoryService; push: PushService; cache: CacheStore; static func fake() -> AppEnvironment }`. A launch argument `-useFakes` selects `.fake()`.
- [ ] **Step 1:** Implement. Selecting a flight centres the globe on its arc and pushes `FlightDetailView` in the sheet; tapping an airport pin opens `AirportView`.
- [ ] **Step 2:** Run on the simulator with `-useFakes`, take screenshots of home, detail, airport, Passport. Save side-by-side comparisons with the matching reference screenshots to `docs/screens/compare/ios-*.png` and fix visible differences in layout, spacing, type, and colour before committing.
- [ ] **Step 3:** Commit `feat(ios): tab shell over the globe`.

### Task 8: macOS shell

**Files:**
- Create: `Apps/macOS/RootSidebarView.swift`
- Modify: `Apps/macOS/SomaFlightMacApp.swift`

**Interfaces:**
- Produces: `RootSidebarView(env:)` with the full-window `GlobeMap` and a floating glass panel (width 360) on the left holding the same sections, a toolbar search field, and `Settings` scene for `SettingsView`. Minimum window 900 x 600.
- [ ] **Step 1:** Implement.
- [ ] **Step 2:** Run with `-useFakes`, screenshot home, detail, airport, Passport, and save side-by-side comparisons with the Mac reference screenshots to `docs/screens/compare/mac-*.png`; fix visible differences before committing.
- [ ] **Step 3:** Commit `feat(macos): sidebar shell over the globe`.

### Task 9: Supabase services and sign in

**Files:**
- Create: `Services/Supabase/SupabaseFlightService.swift`, `SupabaseAirportService.swift`, `SupabaseAuthService.swift`, `SupabaseHistoryService.swift`, `SupabasePushService.swift`, `Apps/iOS/Config.xcconfig`, `Apps/macOS/Config.xcconfig` (`SUPABASE_URL`, `SUPABASE_ANON_KEY`; anon key only, never the service key)
- Test: `Tests/FlightKitTests/SupabaseMappingTests.swift`

**Interfaces:**
- Consumes: backend Plan endpoints: `flight-lookup`, `follow-flight` (POST and DELETE), `airport-board`, `delete-account`; tables `flights`, `flight_events`, `user_flights`, `past_flights`, `push_tokens`; Realtime on `flights`.
- Produces: the five protocol implementations. Edge function error JSON `{ "error": { "code": "..." } }` maps through `APIError(code:)`; `URLError` network codes map to `.offline`. `updates(for:)` subscribes to `postgres_changes` on `flights` filtered by `id=in.(...)` and resubscribes on reconnect.
- [ ] **Step 1: Write failing tests** (pure mapping, no network): `mapsFunctionErrorBody` (each of the 5 codes), `mapsURLErrorToOffline`, `buildsLookupBodyForRoute` (`{"origin":"CDG","destination":"SFO","date":"2026-10-28"}`).
- [ ] **Step 2:** Run. Expected: FAIL.
- [ ] **Step 3:** Implement. Sign in with Apple through `ASAuthorizationAppleIDProvider` with a SHA256 nonce passed to `signInWithIdToken`; email through magic link.
- [ ] **Step 4:** Run tests. Expected: PASS.
- [ ] **Step 5:** When the backend Task 10 is deployed: run the iOS app against it, sign in, search and follow a real flight, open an airport. Record results in the commit message.
- [ ] **Step 6:** Commit `feat(app): Supabase services and sign in`.

### Task 10: Notifications

**Files:**
- Create: `Apps/iOS/AppDelegate.swift`
- Modify: `Apps/iOS/SomaFlightApp.swift`, `Apps/macOS/SomaFlightMacApp.swift`, `project.yml` (Push Notifications capability, `aps-environment`)

**Interfaces:**
- Consumes: `PushService.register(deviceToken:kind:flightId:)`.
- Produces: permission request after the first follow (not at launch), token registration as kind `alert`, tap on a notification opens that flight's detail (payload key `flight_id`).
- [ ] **Step 1:** Implement for iOS and macOS.
- [ ] **Step 2:** Send a test push with `xcrun simctl push` and a payload containing `flight_id`; confirm the detail opens.
- [ ] **Step 3:** Commit `feat(app): push notifications`.

### Task 11: Live Activity

**Files:**
- Create: `LiveActivity/FlightActivityAttributes.swift`, `Apps/Widgets/FlightLiveActivity.swift`, `Apps/Widgets/WidgetsBundle.swift`
- Modify: `project.yml` (widget extension target, `NSSupportsLiveActivities`), `Stores/MyFlightsStore.swift` (start activity for the next flight)
- Test: `Tests/FlightKitTests/LiveActivityStateTests.swift`

**Interfaces:**
- Produces: `struct FlightActivityAttributes: ActivityAttributes { ident: String; originIata: String; destinationIata: String; struct ContentState: Codable, Hashable { status: FlightStatus; gateOrigin: String?; gateDestination: String?; estimatedOut: Date?; estimatedIn: Date?; progress: Double } }`, field names matching the backend `content-state` exactly. `static func ContentState.from(_ flight: Flight) -> ContentState`. Lock screen view, Dynamic Island compact, minimal, and expanded. Started with `pushType: .token` within 4 hours of departure; its push token is registered as `live_activity` with the flight id.
- [ ] **Step 1: Write failing tests:** `contentStateFromFlight` copies gate and times; `contentStateJSONKeys` encodes to the keys `status, gateOrigin, gateDestination, estimatedOut, estimatedIn, progress`; `canceledState` keeps status canceled (Review Focus 4).
- [ ] **Step 2:** Run. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run tests. Expected: PASS. Start an activity on the simulator with fakes and update it with `xcrun simctl push` using `push-type liveactivity`.
- [ ] **Step 5:** Commit `feat(ios): flight Live Activity`.

### Task 12: Settings, export, deletion, App Store readiness, snapshots

**Files:**
- Modify: `UI/Screens/SettingsView.swift`
- Create: `Apps/iOS/PrivacyInfo.xcprivacy`, `Tests/FlightKitTests/ExportTests.swift`, `docs/app-store-checklist.md`

**Interfaces:**
- Produces: units setting stored in `@AppStorage` (`distanceUnit` km or mi, `clock` 24 h or 12 h); export through `ShareLink` of JSON and CSV from `HistoryService.export`; delete account with a confirmation dialog whose copy is "Delete your account? Your followed flights and flight history will be removed. This can't be undone." then `SessionStore.deleteAccount()` and return to `SignInView`.
Alert settings in v1 are a per-flight notify switch in `FlightDetailView` (calls `follow(_:notify:)`) plus a link to system notification settings; per-type alert filtering is not in v1.

- [ ] **Step 1: Write failing tests:** `csvHasHeaderAndRows` (header `date,flight,from,to,airline,aircraft,registration,seat,distance_km,block_minutes,delay_minutes,status`), `csvEscapesCommas`.
- [ ] **Step 2:** Run. Expected: FAIL.
- [ ] **Step 3:** Implement. The CSV is built on device from `PastFlight` values (`HistoryService.export(.csv)` uses `PastFlight.csv(_:)`).
- [ ] **Step 4:** Run tests. Expected: PASS.
- [ ] **Step 5:** Snapshot pass: run iOS (iPhone 17 Pro) and macOS with `-useFakes`, dark and light, for every screen including sparse flight, canceled flight, offline, and plan limit states (Review Focus 3, 4, 5). Save to `docs/screens/`.
- [ ] **Step 6:** Write `docs/app-store-checklist.md`: privacy manifest, notification and Live Activity usage text, privacy policy URL, account deletion path, data use disclosure, screenshots.
- [ ] **Step 7:** Commit `feat(app): settings, export, deletion, store readiness`.
