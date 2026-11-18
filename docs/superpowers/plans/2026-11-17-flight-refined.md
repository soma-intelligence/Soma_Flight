# Flight refined: SwiftUI implementation plan (2026-11-17)

Quentin validated the Penpot proposal on 2026-11-17. This plan builds it in the app.

## Sources of truth

- The spec: `Soma_Tools/penpot-lab/docs/flight-proposal.md` (audit A1-A10, rulings R1-R9).
- The boards: `Soma_Tools/penpot-lab/out/flight-prop/*.png` (light theme, 440 x 956 pt at @3x) and the contact sheet `out/flight-prop-sheet.png`.
- The exact metrics: `Soma_Tools/penpot-lab/screens/flight-prop-kit.mjs` (shared parts) and `flight-prop-home.mjs`, `flight-prop-detail.mjs`, `flight-prop-tabs.mjs`, `flight-prop-ds.mjs`.
- The parity captures of today's app: `Soma_Tools/penpot-lab/captures/flight/*.png`.
- The decisions ledger: `Soma_Tools/design-bridge/decisions/flight.yaml`.

## Rules for every lot

- Keep Flight's art direction. Use the `Theme` tokens. Add no raw colour literal in a screen.
- The Mac panel shares these views through `metricsScale`. Use `scaledPadding`, `themeFont` and `Theme.metric` the way the files already do.
- Never commit. Another session edits this checkout: never run `git add -A`, `git checkout` or `git stash`.
- Build with your own derived data folder: `-derivedDataPath <scratchpad>/dd-<lot>`.
- Words with every colour (R9). Tap targets of 44 pt or more. No text under 11 pt.

## Lot 0. Shared kit (lands first)

New folder `Packages/FlightKit/Sources/FlightKit/UI/Refined/`:

- `Theme` gains `gateBadge`, `gateInk`, `sheetGrabber` and `glassControl` (values in `penpot-lab/screens/flight-tokens.js`).
- `FlightStatus`: a pure function from a `Flight` (and the clock) to a status line (`text`, `tone`, `progress`). Examples: "Departed 16m late · lands 05:28", "On time · gate B22", "Canceled", "Diverted to OAK", "Landed 11m late". Unit tests in `Tests/FlightKitTests`.
- `StatusLine`, `FlightProgressBar` (3 pt, filled part in the delay colour, a head dot with a card-coloured ring), `RefinedCard` (flat, 14 pt radius, optional 4 pt left severity bar), `SectionLabel` (small caps, secondary, optional trailing action), `SeverityDot`.
- `SheetHeader` in three kinds: `.root`, `.detail` and `.modal` (R5). `CloseButton` becomes the one 44 pt glass `xmark`.
- `GlassActionBar` (R4) and a `refinedActionBarInset()` modifier that pads the scroll content by the bar height plus 16 pt.
- `MapControlCapsule`: one vertical glass capsule of 44 pt buttons (R2).
- `StatusPill`: the small "Offline · positions estimated" capsule.

## Lot A. Home and search (R1, R2, R8, A10)

Files: `Screens/MyFlightRow.swift`, `Screens/MyFlightsView.swift`, `Screens/PlannedFlightRow.swift`, `Screens/SearchView.swift`, `Screens/SearchSuggestionRows.swift`, `OfflineBanner.swift`, `Apps/iOS/RootTabView.swift`, `Apps/iOS/RegularHomeView.swift`, `Apps/iOS/DuoSplitHomeView.swift`.

- Each home row gets the status line, and an in-air row gets the progress bar.
- The map controls become one capsule. The two broadcast buttons merge into one "Live" control.
- Home empty: a message and an "Add a flight" button. Home offline: the status pill under the header.
- Search before typing: recent searches and examples.

## Lot B. Flight and airport sheets (R3, R4, R7, R8)

Files: `Screens/FlightDetailView.swift`, `Detail/DetailHeader.swift`, `Detail/DetailTiles.swift`, `Detail/DepartArrive.swift`, `ErrorBanner.swift`, `Screens/AirportView.swift`, `Screens/Airport/*`, `Shell/ShellChrome.swift` (pushed screens only).

- One hero status card replaces the red banner and the "Landing late" card.
- More, Alerts and Share move into the glass action bar, and the content ends above it.
- Error state: a "Couldn't refresh · Retry" card that keeps the last known data.
- Airport: a severity card in place of the pink block. The bar never covers "Departure delay trend".

## Lot C. Tabs and modals (R5, R6, R8)

Files: `Screens/SettingsView.swift`, `Screens/Profile/*`, `Screens/TravelDocumentsView.swift`, `Screens/Friends/*`, `Screens/PassportView.swift` (header only).

- Modal header on Settings, Travel documents and Profile. Root header on Friends and Passport.
- Profile cards lose their coloured top strokes.
- Friends empty: an invite card showing your code.

## Lot D. Verification

- `swift test --package-path Packages/FlightKit`, and an iOS build of the app.
- Screenshots on the simulator "Flight Parity" (`-useFakes YES`) of each proposal board, compared with the Penpot PNGs.
