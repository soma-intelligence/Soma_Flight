# Prism and Soma Flight: one body clock for every flight

Date: 2026-11-08. Owner settled the five open questions in chat the same day. Touches two repos: Soma_Flight (this one) and Soma_iOS (Prism).

## Why

Prism already knows how a body re-entrains after a flight: `SomaTools.JetLagModel`, `TripPlanner`,
`TravelActionPlanner` and the Travel page in `Soma_iOS/Prism`. But Prism only learns about a trip when
the user types it (one `TripPrefs`: a place, a zone, a departure date) or when the phone's UTC offset
changes, and then only after one night in the new zone.

Soma Flight knows every flight weeks ahead, with real airports, real time zones and live times that
move with delays. It has no body clock and no HealthKit yet.

GOAL.md items 4 (jet lag plan), 6 (recovery after the flight) and 7 (long-haul care) ask Flight to do
what Prism already does. This spec connects the two apps instead of writing the engine twice.

Priority: this is GOAL.md line 6 (owner additions). It never blocks a release blocker (line 1) and
needs no paid call, deploy or cloud change.

## What the traveller sees

**In Soma Flight**

1. **A "Body clock" card on the flight sheet**, for any flight that crosses 2 time zones or more:
   "9 zones east. About 5 days to settle. Start shifting your sleep tonight."
2. **With Prism installed and sharing on**, the card shows Prism's own plan for the day (tonight's bed
   time, the light window, the caffeine cutoff) and a "Open in Prism" button.
3. **Without Prism**, Flight runs the same engine itself. With Apple Health on (Settings, "Use Apple
   Health", off by default), it reads the traveller's habitual sleep window and daylight; with it off,
   it uses default hours (wake 07:00, sleep 23:00).
4. **In Passport, after the trip**, a "Recovery" line per trip, computed by Flight from Apple Health (or
   taken from Prism when Flight's Apple Health switch is off): "Sleep back to normal on day 3. HRV 12 %
   under your baseline the first night."

**In Prism**

5. **An "Add this trip from Soma Flight" sheet** when Flight hands a trip over. One tap adds it; nothing
   is written without that tap.
6. **The Travel page runs on the real flight**: the real departure airport's zone (not the phone's), the
   real arrival time (not the departure date), the red-eye night, and a plan that moves when the flight
   is delayed.

## The calculation

Today's model (`ToolsJetLagModel.swift`), unchanged by this spec:

- zones = |shift| rounded; east = shift > 0.
- rate = 1.0 zone/day east, 1.5 west; daylight multiplies it by up to 2 (full boost at 120 min).
- days = ceil(zones / rate), capped east from 8 zones by the antidromic path ceil((24 - zones) / 1.5).
- Melatonin note from 5 zones; light timing caveat east from 8 zones.

Worked example, SFO to CDG in November: UTC-8 to UTC+1, shift +9 h.

| Case | Formula | Days |
|---|---|---|
| East, no daylight | ceil(9 / 1.0) = 9, cap ceil(15 / 1.5) = 10 | 9 |
| East, 60 min daylight | ceil(9 / 1.5) | 6 |
| East, 120 min daylight | ceil(9 / 2.0) | 5 |
| Back west, no daylight | ceil(9 / 1.5) | 6 |
| Back west, 120 min daylight | ceil(9 / 3.0) | 3 |

**What Flight's data changes in Prism's numbers**

Prism's Travel page already moves sleep 0.5 h a night for the 3 nights before departure
(`TravelPage.stepHours`, `stepNights`), but it does not credit that shift in the recovery days. With a
known flight, the plan credits it (owner's call, 2026-11-08):

    residualShift = shift - sign(shift) * min(achievedShift, |shift|)

SFO to CDG after 3 nights: 9 - 1.5 = 7.5 h, rounded to 8 zones. With 120 min of daylight: ceil(8 / 2) =
4 days instead of 5. Without daylight: 8 instead of 9.

`achievedShift` is what the body really moved, never what the plan asked for:

- **With Apple Health** (Flight's switch, or Prism): the move of the sleep midpoint over the nights
  before departure against the 14-night baseline, in the direction of travel, clamped to
  `stepHours * nights` (0.5 h a night, 3 nights at most). A night with no sleep record adds nothing.
- **Without Apple Health**: no credit. The card shows both numbers: "About 5 days. 4 if you shift your
  sleep 1.5 h before you leave."
- The credit is computed once, at the outbound leg's departure, and stored on the trip, so a later
  night does not change a recovery already under way.

This changes Prism's numbers for every trip with Health data, Travel page included, so its tests and
copy move in the same commit as the shared package's.

Three errors in today's `TravelPlan` that real flight data removes:

1. Arrival is taken as the departure date (`legs: [TripLeg(arriveAt: prefs.departs, ...)]`), so a
   night flight that lands the next day counts its first recovery day one day early.
2. The origin zone is the phone's current zone, not the departure airport's, so a plan made at home
   for a connection leg, or made abroad, is wrong.
3. `flightHours` is stored but not used in the timing.

## Trips in Soma Flight

Flight has flights, not trips. Prism's `SomaTools.Trip` needs an outbound and a return. A pure rule,
written in `flightcore` (Rust, per GOAL.md "one codebase") and exposed through FlightCoreFFI:

1. **Journey**: consecutive flights of one traveller where each next flight leaves the airport the last
   one landed at within 24 h. Connections are legs of one journey.
2. **Trip**: a journey, plus the next journey that ends at the first journey's origin within 60 days
   (the return). A journey with no return is a one-way trip.
3. **Destination**: where the outbound journey ends. Its zone is the airport's `tz`.
4. **Red-eye**: a leg whose time in the air covers 02:00 to 05:00 in its departure zone.
5. Times: `actual ?? estimated ?? scheduled`, gate times (`out`, `in`).

The same trips feed later work: the per-trip expense PDF (GOAL item 27) and the year in review (item 18).
They are computed, never stored on the server.

## The contract between the two apps

One JSON shape, versioned, owned by the shared package (below). It maps 1:1 onto `SomaTools.Trip`.

    {
      "version": 1,
      "source": "me.somalabs.flight",
      "trip": {
        "id": "UUID, stable: derived from the first leg's flight id",
        "updatedAt": "ISO 8601",
        "deletedAt": null,
        "destinationName": "Paris",
        "destinationTimeZoneID": "Europe/Paris",
        "startDate": "...", "endDate": "...",
        "legs": [{
          "id": "the Flight id",
          "departAt": "...", "arriveAt": "...",
          "fromTimeZoneID": "America/Los_Angeles", "toTimeZoneID": "Europe/Paris",
          "isRedEye": true,
          "label": "AF 83 SFO to CDG"
        }]
      }
    }

Rules:

- No gate, seat, booking reference, name or position. `label` is for display only.
- Prism refuses a payload over 8 KB, an unknown `version`, a leg without both zones, a leg longer than
  24 h, or more than 12 legs.
- Prism never trusts `source` as proof of origin (any app can open a URL). The tap in step 5 is the trust.

The return path, Prism to Flight, is a summary, never samples:

    {
      "version": 1,
      "trips": [{
        "id": "trip id",
        "updatedAt": "...",
        "jetLag": { "zones": 9, "direction": "advance", "recoveryDays": 5, "dayNumber": 2, "recoveryPct": 20 },
        "today": [{ "kind": "morningLight", "startHour": 7.5, "endHour": 9.5, "title": "Get morning light" }],
        "recovery": { "baselineDays": 14, "nights": [
          { "date": "2026-12-13", "sleepDeltaPct": -18, "hrvDeltaPct": -12, "restingHRDeltaBpm": 4 }
        ] }
      }]
    }

## Transport

**Stage 1: a link (works for every build, no entitlement).**

- Flight opens `soma://trip/import?d=<base64url JSON>`. Prism adds `case tripImport(Data)` to
  `SomaDeepLink` and shows the sheet from step 5.
- Prism's "Open in Soma Flight" opens `somaflight://flight/<id>`.
- Flight declares `soma` in `LSApplicationQueriesSchemes` to know if Prism is installed. When it is not,
  the button is hidden (Prism is not on the App Store yet).
- Stage 1 is one-shot: a delay after the import does not reach Prism.

**Stage 2: a shared App Group (live, both apps signed by the Soma Labs team).**

- New group `group.me.somalabs.travel`, added to Flight's iOS app and to Prism's iOS app. Neither app's
  existing group changes.
- Flight writes `trips.json` (all trips within 7 days ahead and 3 days back, with tombstones) when a
  flight changes. Prism writes `body.json`.
- Writes go through `NSFileCoordinator`; each writer then posts the Darwin notification
  `me.somalabs.travel.changed`, and the other app reloads when it is in front or when its widget
  timeline runs.
- **Off by default on both sides.** Flight: Settings, "Share trips with Prism". Prism: Settings,
  "Read trips from Soma Flight". Each switch turns its own direction on.
- The public `Soma.Prism` build has a different bundle and may not be on the team, so it stays on Stage 1.

**Never through a server.** Flight and Prism have separate Supabase projects. Neither the trip nor the
body summary is uploaded by this feature. A test in FlightKit fails if the body summary type is used by
any Supabase model or request.

## The shared package

Move the pure engines out of Prism into a new target of WellnessKit, `Circadian` (owner's call,
2026-11-08), with its own library product. Both apps link that product only.

- **Package changes.** WellnessKit gains `.library(name: "Circadian", targets: ["Circadian"])`, a
  `Circadian` target with no dependencies, a `CircadianTests` test target, and `.watchOS(.v26)` in
  `platforms` (FlightKit builds for watchOS; today WellnessKit lists iOS, visionOS and macOS only).
- **Only `Circadian` is compiled in Flight.** SwiftPM builds the targets a product needs, so Flight never
  compiles HealthKit, SQLite sync or the Supabase adapter. It still resolves WellnessKit's
  dependencies: supabase-swift `upToNextMajor(from: "2.55.3")` is compatible with FlightKit's
  `exact: "2.55.5"`, so the graph resolves to 2.55.5. A WellnessKit bump of that floor above 2.55.5 must
  wait for Flight's pin to move first.
- **How Flight gets it.** WellnessKit's repo is private, and Soma Flight is public, so Flight cannot
  depend on its URL: an outside clone would not build. The code is already public under AGPL-3.0 as the
  copy in `soma-intelligence/prism` (`Packages/WellnessKit`). Flight takes the same copy into
  `Packages/WellnessKit` (a path dependency, like FlightCoreFFI), refreshed by a script
  `Scripts/sync_wellnesskit.sh` that copies from the Prism export. Only that copy is committed, never
  the private repo's history. The copy is the Prism export's, so it already passed the export's scrub
  gate; the script copies it as is and never from the private checkout.
- Contents: `JetLagModel`, `TripPlanner`, `TravelActionPlanner`, `Trip`/`TripLeg`, the circadian math
  they need, the habitual sleep and wake estimator (`ChronotypeEstimator.Night`,
  `habitualWakeHour`, `habitualSleepHour` from `ToolsCircadianInputs.swift`), the recovery deltas, the
  two contract types and their validation. Foundation only, no SwiftUI, no HealthKit: each app reads
  HealthKit itself and hands plain values to the engine.
- They are already `nonisolated` pure functions inside `extension SomaTools`, so the move is mechanical.
  Prism keeps a `typealias` per moved type so its call sites and tests stay as they are in the first commit.
- Prism's tests for these engines (`ToolsTravelShiftTests`, `ToolsCircadianTests` and the jet lag ones)
  move with them.
- A golden file `trip-handoff-v1.json` lives in the package; both apps test against it.
- Licence AGPL-3.0, same as both apps.

## Health data rules

Owner's call, 2026-11-08: Flight reads Apple Health itself.

- **Read only, off by default.** Flight asks for HealthKit only when the traveller turns on "Use Apple
  Health" (Settings, or the Body clock card's "Tune with your sleep"). It never writes to Health.
- **Types read:** `sleepAnalysis`, `heartRateVariabilitySDNN`, `restingHeartRate`, `timeInDaylight`.
  Nothing else. `NSHealthShareUsageDescription`: "Soma Flight reads your sleep, heart rate variability,
  resting heart rate and time in daylight to time your jet lag plan and show how each trip affected
  you. It stays on this iPhone."
- **Entitlement:** `com.apple.developer.healthkit` on the iOS app only. The Watch app comes later
  (long-haul reminders), with its own request.
- **Never leaves the phone.** No sample, delta or plan derived from Health goes to Supabase, to iCloud
  backups of Flight's cache, to the share link or to friends. The no-upload test covers every Health
  type and every type derived from it, not only the body summary. App Review guideline 5.1.3 applies:
  no Health data for ads or analytics, and the privacy policy names it.
- **Who wins when both apps know.** One engine, so both give the same days for the same inputs. When
  Prism's `body.json` for the trip is under 24 h old, Flight shows Prism's actions (Prism has more
  inputs: chronotype, caffeine log); otherwise Flight's own. Recovery in Passport always comes from
  Flight's own read when its switch is on.
- Flight never uploads `body.json`.
- `body.json` holds deltas against the traveller's own baseline, rounded (whole percent, whole bpm).
- Prism computes the recovery nights: arrival night to day +3, against the 14 nights before departure.
- Flight's App Store privacy label does not gain a "Health and Fitness" line, because data that never
  leaves the phone is not "collected". The privacy policy page (landing PR #151) and the App Store
  review notes do gain a Health paragraph, and `PrivacyInfo.xcprivacy` is checked against it.

## Phases

1. **P1, link handoff.** Shared package (Prism behaviour unchanged). Trip grouping in `flightcore`.
   Flight's Body clock card, with default hours or Apple Health (read only, off by default), and the
   Recovery line in Passport from Flight's own read. `soma://trip/import` and Prism's import sheet. Prism's
   `TravelPlan` built from a real `Trip` (fixes the three errors above). Prism stores imported trips
   next to today's single `TripPrefs`; the nearest one inside the 7-day horizon wins.
2. **P2, live sync.** App Group, both switches, re-plan on delay, `body.json`, Prism's plan on Flight's
   card, Prism's recovery in Passport when Flight's Apple Health switch is off.
3. **Later, not in this spec's plan.** Watch heart rate and SpO2 kept for the time in the air, a Prism
   journal entry per flight, long-haul water and walk reminders on the Watch.

## Tests

- `flightcore`: journeys and trips from fixtures (connection under and over 24 h, open jaw, one way,
  return after 60 days, red-eye, a leg that crosses the date line).
- Shared package: the SFO to CDG table above as a test; the pre-shift credit (midpoint move from fixture nights, clamp at 1.5 h, missing nights, wrong
  direction gives 0, no Health gives 0); DST at
  the arrival date (already covered by `arrivalShiftHours`); contract round trip on the golden file;
  every refusal rule.
- Prism: the deep link parses and opens the sheet; a hostile payload never writes; `TravelPlan` from a
  real trip matches the hand-computed days.
- Flight: card shows for 2 zones or more only; button hidden without Prism; no HealthKit request before
  the switch is turned on; habitual hours from fixture nights; recovery deltas against a 14-night
  baseline; the no-upload guard over every Health-derived type.

## Out of scope

Android, the web flight page, a Soma account link between the two apps, sending trips to the companion
(Hermes), any change to Prism's notifications beyond the existing Travel ones.

## Open questions for the owner

1. **Decided 2026-11-08: a `Circadian` target in WellnessKit, vendored into Flight.** WellnessKit stays
   private. Its history and branches hold what the Prism export strips on purpose (HealthUpload, the
   ingest host, capture and old Temple names, a second author email), so it is not made public.
2. **Decided 2026-11-08: same signing team.** Prism (`me.somalabs.health`) and Flight
   (`me.somalabs.flight`) are both signed by the Soma Labs team, so Stage 2 is in scope. Until the Apple
   agreement is accepted, demo builds on the free personal team cannot share the group: Stage 2 is tested
   on signed builds only.
3. **Decided 2026-11-08: HealthKit in Flight**, read only, off by default (see Health data rules).
4. **Decided 2026-11-08: credit the pre-flight shift** in the recovery days, in both apps (see The
   calculation).
5. **Decided 2026-11-08: GOAL.md items 4, 6 and 7 point to this spec.**
