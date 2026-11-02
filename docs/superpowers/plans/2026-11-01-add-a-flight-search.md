# Add a Flight Search Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One search field that reads a flight number, airline, places, date and time of day in any order, finds the flight the traveller is taking (also weeks ahead) and adds it to My Flights in one tap.

**Architecture:** A pure Swift parser (`SearchIntent`) turns text into pieces and chips. `SearchStore` routes an intent to today's lookups when the date is within two days, else to a new `ScheduleService` backed by a new Edge Function `flight-schedules` over AeroAPI `/schedules`. A far flight is added to the existing `FollowLaterQueue` and shows in My Flights as a Planned row.

**Tech Stack:** Swift 6 / SwiftUI / Swift Testing (FlightKit), Deno + Supabase Edge Functions, Postgres migrations.

**Spec:** `docs/superpowers/specs/2026-11-01-add-a-flight-search-design.md`

## Global Constraints

- Work in the main checkout on `main`. No worktrees. Stage explicit paths, never `git add -A` (other sessions may have files open).
- No Claude attribution and no em dash (`—`) anywhere: code, comments, commits.
- Copy in English, Add / Added wording (109e858). App strings stay English; the parser reads English and French.
- No deploy, no `supabase db push`, no paid call. `flight-schedules` is built and tested locally only.
- `BOARD_PROVIDER` stays `none`. Debug builds run on fakes.
- Comments read like the surrounding code: a `///` doc line on each type and non-obvious func, no narration.
- FlightKit tests: `cd Packages/FlightKit && swift test` (about 3 min, 1060 tests today). Deno: `cd supabase/functions && deno test -A <dir>`.
- Mirror the `alternate-flights` pattern at every layer (handler + index + contract JSON written by the Deno tests and decoded by a Swift test, `alternates_cache` style table, `AlternateFlightsService` style protocol with Unavailable, Fake and Supabase implementations).

## Rulings on the spec

- "The traveller's upcoming flights not yet added" (spec, ready-made rows): there is no source for them until calendar sync (out of scope). Ready-made rows are frequent routes, Today, Tomorrow and recents.
- City airports: a city gives every bundled airport whose folded `city` equals the folded word(s) and whose `AirportSizes.bundled.size` is not `.small`; when that leaves none, the largest one. Paris gives CDG and ORY.
- "Within two days" means the origin-local day is today, tomorrow or the day after (the reach of `flight-lookup`).

## Review Focus

1. A place word that is also an airline or code ("Delta" the airline, "DEL" Delhi, "AA"): an airline name wins over a city only when typed in full; two-letter codes are airlines, three-letter codes airports, unless followed by digits (then an ident). Test in Task 2.
2. A date typed before a place ("demain Paris Londres"): order must not matter. Test in Task 2.
3. A far search when the backend is unavailable (Release without the function deployed): a clear note, never an empty silent list. Test in Task 4.
4. Adding the same planned flight twice: the queue id `"\(ident) \(day)"` dedupes; the row reads Added. Test in Task 6.
5. Deleting a Planned row while offline: queue-only, works offline. Test in Task 6.

---

### Task 1: Date and time words

**Files:**
- Create: `Packages/FlightKit/Sources/FlightKit/Search/DateWords.swift`
- Test: `Packages/FlightKit/Tests/FlightKitTests/DateWordsTests.swift`

**Interfaces:**
- Produces: `enum DateWords { static func day(_ words: [Substring], now: Date, tz: TimeZone, monthFirst: Bool) -> (day: LocalDay, used: Range<Int>)?` and `static func timeOfDay(_ words: [Substring]) -> (minutes: Int, used: Range<Int>)?`. Input words are `SearchText.fold`ed. `used` is the index range of words consumed. Also `static let maxDaysAhead = 330`.

- [ ] **Step 1: Write the failing tests** with `now` = 2026-11-01 12:00 in `Europe/Paris` (a Sunday):
  - "today"/"aujourd hui" give 2026-11-01; "tomorrow"/"demain" 11-02; "day after tomorrow"/"apres demain" 11-03.
  - "friday"/"vendredi" 11-06; "next friday"/"vendredi prochain" 11-13; "sunday" gives 11-08 (today's weekday means next week).
  - "12 dec", "dec 12", "12 decembre", "12 december" give 2026-12-12; "12 12" with `monthFirst: false` 2026-12-12; "3 4" day-first 2027-04-03, month-first 2027-03-04 (past rolls to next year); "2026 12 12" (folded from 2026-12-12) gives 2026-12-12.
  - "15 sep" gives 2027-09-15; "15 oct" (348 days ahead, over the 330-day limit) returns nil.
  - `used` covers only the date words in "paris 12 dec london" (indices 1..<3).
  - timeOfDay: "morning"/"matin" 480, "midday"/"midi" 720, "afternoon"/"apres midi" 900, "evening"/"soir" 1140, "night"/"nuit" 1320, "18h" 1080, "18h30" 1110, "6pm" 1080, "6 30 pm" 1110.
- [ ] **Step 2: Run** `swift test --filter DateWordsTests`. Expected: FAIL, `DateWords` not found.
- [ ] **Step 3: Implement** with plain word tables for months and weekdays in both languages (folded, accept 3-letter prefixes). Use `Calendar(identifier: .gregorian)` with `tz`.
- [ ] **Step 4: Run** the filter. Expected: PASS.
- [ ] **Step 5: Commit** `git add` the two files, message "Read dates and times of day in English and French".

### Task 2: SearchIntent

**Files:**
- Create: `Packages/FlightKit/Sources/FlightKit/Search/SearchIntent.swift`
- Modify: `Packages/FlightKit/Sources/FlightKit/Search/SearchSuggester.swift` (expose read-only `airport(named:)`, `airline(named:)` lookups over its existing entries, typo limits from `SearchText.allowedTypos`)
- Test: `Packages/FlightKit/Tests/FlightKitTests/SearchIntentTests.swift`

**Interfaces:**
- Consumes: `DateWords` (Task 1), `SearchSuggester`, `AirportSizes.bundled`.
- Produces:
  ```swift
  public struct SearchIntent: Sendable, Equatable {
      public enum Chip: Sendable, Hashable { case ident(String), airline(Airline), place([Airport]), day(LocalDay), time(Int) }
      public var ident: String?          // "AF84"
      public var airline: Airline?
      public var origins: [String]       // ICAO
      public var destinations: [String]  // ICAO
      public var day: LocalDay?
      public var timeOfDay: Int?         // minutes after midnight
      public var chips: [Chip]           // in text order
      public var leftover: [String]      // words nobody read
      public static func parse(_ text: String, now: Date, tz: TimeZone, monthFirst: Bool, suggester: SearchSuggester) -> SearchIntent
      public var isSearchable: Bool      // ident, airline or a place
      public func removing(_ chip: Chip, from text: String) -> String
  }
  ```

- [ ] **Step 1: Write the failing tests:**
  - "AF 84 demain": ident "AF84", day 11-02, chips `[.ident, .day]`.
  - "Paris New York 12 dec": origins `["LFPG","LFPO"]`, destinations contain `"KJFK"`, day 2026-12-12.
  - "demain paris londres": same places as "paris londres demain".
  - "Air France CDG vendredi": airline id "AFR", origins `["LFPG"]`, no destination, day 11-06.
  - "SFO 15/11" day-first: origins `["KSFO"]`, day 2026-11-15.
  - "Lufthansa Munich": airline "DLH", origins `["EDDM"]`, day nil.
  - "paris to london", "paris vers londres", "paris - london": one origin set, one destination set.
  - "zurih geneve": typo still reads LSZH and LSGG.
  - "Delta Atlanta" airline DAL; "DEL" alone is Delhi (VIDP); "AA 100" ident "AA100".
  - "paris blah london": leftover `["blah"]`, both places read.
  - "18h" alone: `isSearchable == false`, timeOfDay 1080.
  - `removing(.day(...), from: "AF 84 demain")` gives "AF 84".
- [ ] **Step 2: Run** `swift test --filter SearchIntentTests`. Expected: FAIL.
- [ ] **Step 3: Implement.** Fold and split the text; take the date and time spans first (Task 1); then an ident regex on what is left (same rule as `FlightQuery.parse`); then greedy longest match of up to four words against airline names and airport names and cities; then 2-letter words as airline codes and 3-4 letter words as airport codes. First place is the origin, second the destination.
- [ ] **Step 4: Run** the filter. Expected: PASS.
- [ ] **Step 5: Commit** "Parse a search into flight number, airline, places, date and time".

### Task 3: flight-schedules Edge Function

**Files:**
- Create: `supabase/migrations/<next free 20261101 number>_schedules_cache.sql` (check `ls supabase/migrations` and the other sessions' numbers first)
- Create: `supabase/functions/flight-schedules/handler.ts`, `index.ts`, `index_test.ts`, `contract/schedules.json`
- Modify: `supabase/config.toml` (block like `[functions.alternate-flights]`), `docs/api-contract.md` (Endpoints row + a `## flight-schedules` section)

**Interfaces:**
- Consumes: `AeroApi.schedules` in `_shared/aeroapi.ts`. Extend it with optional `airline` and `flightNumber` query params; `origin` and `destination` become optional (keep the existing call sites working).
- Produces: `POST /flight-schedules { origin?, destination?, airline?, ident?, date: "YYYY-MM-DD" }` answering `{ date, fetched_at, stale, flights: [{ ident, airline, origin, destination, scheduled_out, scheduled_in, aircraft_type }] }`, ICAO codes, ISO times, sorted by `scheduled_out`.

- [ ] **Step 1: Write the failing Deno tests** (copy the structure of `alternate-flights/index_test.ts`): 400 without origin, destination and ident; 400 on a bad date; 400 on a date over 330 days ahead; the origin-local day becomes `start`/`end` for AeroAPI; a second call within 6 hours reads `schedules_cache` and makes no provider call; a provider refusal with a cached row answers `stale: true`; with nothing cached it answers `provider_unavailable`; the 31st call in an hour answers `rate_limited`; the test writes `contract/schedules.json`.
- [ ] **Step 2: Run** `deno test -A flight-schedules`. Expected: FAIL.
- [ ] **Step 3: Implement** the migration (table `schedules_cache(key text primary key, flights jsonb not null, fetched_at timestamptz not null)`, RLS on, no policies: service role only, like `alternates_cache`), then the handler (`CACHE_TTL_MS = 6 * 3600_000`, `SCHEDULES_MAX_PER_HOUR = 30`, key `"<origin|*>-<destination|*>-<airline|*>-<ident|*>-<date>"`).
- [ ] **Step 4: Run** `deno test -A flight-schedules alternate-flights _shared`. Expected: PASS.
- [ ] **Step 5: Commit** "Add flight-schedules: airline schedules for a day, cached and capped (not deployed)".

### Task 4: ScheduleService in FlightKit

**Files:**
- Create: `Packages/FlightKit/Sources/FlightKit/Services/ScheduleService.swift` (protocol, `ScheduledFlight`, `ScheduleQuery`, `UnavailableScheduleService`)
- Create: `Packages/FlightKit/Sources/FlightKit/Services/Supabase/SupabaseScheduleService.swift`
- Modify: `Services/Fakes/FakeServices.swift` (add `FakeScheduleService` answering from the seed flights shifted to the asked day), `App/AppEnvironment.swift` (`schedules` property, `withSchedules`, wired like `alternates`)
- Test: `Packages/FlightKit/Tests/FlightKitTests/ScheduleServiceTests.swift`

**Interfaces:**
- Consumes: the contract JSON from Task 3.
- Produces:
  ```swift
  public struct ScheduleQuery: Sendable, Hashable { var origin: String?; var destination: String?; var airline: String?; var ident: String?; var day: LocalDay }
  public struct ScheduledFlight: Sendable, Hashable, Identifiable { var ident: String; var airline: String?; var origin: String; var destination: String; var scheduledOut: Date; var scheduledIn: Date?; var aircraftType: String?; var id: String { "\(ident) \(scheduledOut.timeIntervalSince1970)" } }
  public protocol ScheduleService: Sendable { func schedules(_ q: ScheduleQuery) async throws(APIError) -> [ScheduledFlight] }
  ```
  `UnavailableScheduleService` throws `.providerUnavailable`.

- [ ] **Step 1: Write the failing tests:** the Supabase service decodes `supabase/functions/flight-schedules/contract/schedules.json` (same loader as the alternates contract test); the fake answers rows on the asked day for a seed route; the unavailable one throws `.providerUnavailable`.
- [ ] **Step 2: Run** `swift test --filter ScheduleServiceTests`. Expected: FAIL.
- [ ] **Step 3: Implement.** One `origin` or `destination` per call: the store fans out over a city's airports (Task 5).
- [ ] **Step 4: Run** the filter. Expected: PASS.
- [ ] **Step 5: Commit** "Add ScheduleService for flights days or weeks ahead".

### Task 5: SearchStore routes an intent

**Files:**
- Modify: `Packages/FlightKit/Sources/FlightKit/Stores/SearchStore.swift`
- Test: `Packages/FlightKit/Tests/FlightKitTests/SearchRoutingTests.swift`

**Interfaces:**
- Consumes: Tasks 2 and 4. `SearchStore.init` gains `schedules: any ScheduleService = UnavailableScheduleService()`.
- Produces:
  ```swift
  public enum SearchResult: Sendable, Hashable, Identifiable { case live(Flight), planned(ScheduledFlight) }
  public private(set) var intent: SearchIntent      // updated on textChanged
  public private(set) var items: [SearchResult]     // replaces `results` for the view; keep `results` as the live subset
  public private(set) var note: String?             // "Future dates need the live service", "Airline schedules only go 330 days ahead"
  ```

- [ ] **Step 1: Write the failing tests** with fake flight and schedule services counting calls:
  - ident + today: one `lookup(.ident)` call, no schedule call.
  - two places + day after tomorrow: `lookup(.route)` for each origin-destination pair, merged, sorted by out time.
  - two places + 3 weeks out: one `schedules` call per origin airport, rows `.planned`.
  - airline + place + today: live rows filtered to that airline.
  - one place + day: rows grouped by destination, the destinations in `known` first.
  - time of day 1140: rows sorted by distance of local out time to 19:00.
  - far day with `UnavailableScheduleService`: `items` empty, `note == "Future dates need the live service"`.
  - text "18h" only: no call at all.
- [ ] **Step 2: Run** `swift test --filter SearchRoutingTests`. Expected: FAIL.
- [ ] **Step 3: Implement.** Keep `LiveLookupGate`, the debounce and the answer cache keyed by the intent; `FlightQuery.parse` callers keep working.
- [ ] **Step 4: Run** the filter, then the full suite. Expected: PASS, nothing else broken.
- [ ] **Step 5: Commit** "Route a search by what it holds, live near and from schedules far".

### Task 6: Search screen chips, templates and planned rows

**Files:**
- Modify: `Packages/FlightKit/Sources/FlightKit/UI/Screens/SearchView.swift`, `SearchSuggestionRows.swift`
- Create: `Packages/FlightKit/Sources/FlightKit/UI/Screens/SearchChips.swift`
- Modify: `Apps/iOS/RootTabView.swift`, `Apps/macOS/RootSidebarView.swift` (pass `onPlan`)
- Test: `Packages/FlightKit/Tests/FlightKitTests/SearchViewModelTests.swift` (logic only; snapshot tests keep running)

**Interfaces:**
- Consumes: Task 5. `SearchView` gains `onPlan: (UpcomingFlight) -> Void` and `planned: Set<UpcomingFlight.ID>`.
- Produces: `extension UpcomingFlight { init(_ f: ScheduledFlight, tz: TimeZone) }` (ident, origin-local day, origin, destination, departure).

- [ ] **Step 1: Write the failing tests:** `UpcomingFlight(ScheduledFlight)` keeps ident, origin-local day (a 23:30 UTC departure from SFO stays the SFO day), airports and departure; a planned row whose id is in `planned` reads Added; the empty field offers Today and Tomorrow chips and the frequent routes.
- [ ] **Step 2: Run** the filter. Expected: FAIL.
- [ ] **Step 3: Implement.** Chips row under the field (capsules in `Theme.pill`, an x to remove via `SearchIntent.removing`), the note under the chips in `Theme.secondary`, planned rows with the same `ResultRow` look and "Planned" under the times, Add calling `onPlan`. The shells pass `home.followLater.add([u])`.
- [ ] **Step 4: Run** the full suite. Expected: PASS.
- [ ] **Step 5: Commit** "Show what search understood as chips, and add flights weeks ahead".

### Task 7: Planned rows in My Flights

**Files:**
- Modify: `Packages/FlightKit/Sources/FlightKit/UI/Screens/MyFlightsView.swift`
- Create: `Packages/FlightKit/Sources/FlightKit/UI/Screens/PlannedFlightRow.swift`
- Modify: `Apps/iOS/RootTabView.swift`, `Apps/macOS/RootSidebarView.swift` (pass the queue)
- Test: `Packages/FlightKit/Tests/FlightKitTests/PlannedFlightsTests.swift`

**Interfaces:**
- Consumes: `FollowLaterQueue.items`, `remove(_:)`, `SwipeToDelete` (109e858).
- Produces: `MyFlightsView` gains `planned: [UpcomingFlight]` and `onRemovePlanned: (UpcomingFlight.ID) -> Void`; the Upcoming group lists followed and planned rows by departure.

- [ ] **Step 1: Write the failing tests:** a planned item shows in Upcoming in departure order among followed flights; the countdown column reads days for it; removing it empties the queue entry with no network call; the empty state does not show while only planned rows exist; adding the same `UpcomingFlight` twice keeps one item.
- [ ] **Step 2: Run** the filter. Expected: FAIL.
- [ ] **Step 3: Implement.** `PlannedFlightRow` reuses `MyFlightRow`'s layout with "PLANNED" under the countdown; swipe and the long-press menu both call `onRemovePlanned`.
- [ ] **Step 4: Run** the full suite. Expected: PASS.
- [ ] **Step 5: Commit** "Show planned flights in My Flights until they are followed".

### Task 8: Device check

- [ ] Build and install on the owner's iPhone (device id `00008150-000C6C5A3E52401C`, team `M968YV4J8W`, Debug, fakes).
- [ ] Type "Paris New York 12 dec", "AF 84 demain", "Lufthansa Munich vendredi": chips appear, rows appear, Add works, a far one shows as Planned in My Flights, swipe deletes it.
- [ ] Push `main`.
