# iPhone Duo Layout Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Soma Flight picks its home layout from the window's shape, so the iPhone Duo gets the sheet folded, one floating panel when unfolded sideways, and a globe over a fixed pane when unfolded upright.

**Architecture:** A pure `HomeLayout.resolve` in FlightKit decides the layout from idiom and window size. `RootTabView` measures its window and switches on it: `.sheet` keeps `compactHome`, `.panels` and `.duoSideways` use `RegularHomeView` (the Duo with the tab pill instead of the system tab bar), `.duoUpright` uses a new `DuoSplitHomeView`. `ShellModel` raises a collapsed sheet to medium when the Duo folds with a card open.

**Tech Stack:** Swift 6, SwiftUI (iOS 26 SDK, Liquid Glass), MapKit, Swift Testing, xcodebuild, iPhone Duo simulator.

**Spec:** [docs/superpowers/specs/2026-11-08-iphone-duo-layout-design.md](../specs/2026-11-08-iphone-duo-layout-design.md)

## Global Constraints

- Any iPhone screen whose shorter side is under 600 pt keeps today's sheet layout, pixel for pixel. An iPhone 17 Pro Max sideways (956 x 440) is `.sheet`.
- The iPad layouts (`.panels` and compact `.sheet`), the Mac, Watch and widgets do not change.
- A shorter side of exactly 600 pt is a Duo layout.
- Upright pane height: 55% of the height between the safe areas. Fixed, no drag, no detents.
- Shared screens keep `RegularHomeView.panelWidth` (402 pt) in the sideways panel.
- No device model checks (`utsname`, model strings). Only idiom and size.
- Stage explicit paths only; other sessions edit this checkout.
- No em dash in code, comments or commits. No attribution lines in commits.

## Before starting

`Apps/iOS/RootTabView.swift` had uncommitted edits from another session on 2026-11-08. Run `git status --short Apps/iOS/RootTabView.swift`. If it still shows ` M`, stop and ask the owner before Task 5. Tasks 1 to 4 do not touch it.

## Review Focus

1. **Folding with a search query typed.** The traveller types "UA15" in Search, folds the phone: Search is still open with "UA15" in the field. (Task 6, check 6.)
2. **Largest Dynamic Type in the sideways panel.** At Accessibility XL, the 626 pt tall panel still shows the tab title and the pill, and the list scrolls. (Task 6, check 4.)
3. **Turning the open Duo with a card open.** Sideways to upright and back with a flight open: the same flight stays open, no blank pane, no second card. (Task 6, check 5.)
4. **VoiceOver in the pane and panel.** No "Expand" or "Collapse" rotor actions where there is no sheet. (Task 4, step 2; Task 6, check 7.)
5. **The toast with the pill.** A follow's toast shows above the pill in the upright pane and the sideways panel, not hidden under it. (Task 6, check 8.)

---

### Task 1: `HomeLayout`, the layout rule

**Files:**
- Create: `Packages/FlightKit/Sources/FlightKit/App/HomeLayout.swift`
- Test: `Packages/FlightKit/Tests/FlightKitTests/HomeLayoutTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public enum HomeLayout: Equatable, Sendable {
      case sheet, panels, duoSideways, duoUpright
      /// The shorter window side from which an iPhone screen gets the Duo layouts.
      public static let duoMinimumSide: CGFloat = 600
      public static func resolve(isPad: Bool, regularWidth: Bool, size: CGSize) -> HomeLayout
      /// `.duoSideways` or `.duoUpright`.
      public var isDuo: Bool { get }
  }
  ```

- [ ] **Step 1: Write the failing tests** (Swift Testing, `@Suite struct HomeLayoutTests`)

```swift
@Test func duoInnerScreen() {
    #expect(HomeLayout.resolve(isPad: false, regularWidth: true, size: .init(width: 626, height: 890)) == .duoUpright)
    #expect(HomeLayout.resolve(isPad: false, regularWidth: true, size: .init(width: 890, height: 626)) == .duoSideways)
}
@Test func phonesKeepTheSheet() {
    #expect(HomeLayout.resolve(isPad: false, regularWidth: false, size: .init(width: 466, height: 678)) == .sheet) // Duo cover
    #expect(HomeLayout.resolve(isPad: false, regularWidth: false, size: .init(width: 402, height: 874)) == .sheet) // 17 Pro
    #expect(HomeLayout.resolve(isPad: false, regularWidth: false, size: .init(width: 874, height: 402)) == .sheet)
    #expect(HomeLayout.resolve(isPad: false, regularWidth: true, size: .init(width: 956, height: 440)) == .sheet) // Pro Max sideways
}
@Test func iPadIsUnchanged() {
    #expect(HomeLayout.resolve(isPad: true, regularWidth: true, size: .init(width: 1376, height: 1032)) == .panels)
    #expect(HomeLayout.resolve(isPad: true, regularWidth: false, size: .init(width: 320, height: 1032)) == .sheet)
}
@Test func sixHundredIsADuo() {
    #expect(HomeLayout.resolve(isPad: false, regularWidth: false, size: .init(width: 600, height: 800)) == .duoUpright)
    #expect(HomeLayout.resolve(isPad: false, regularWidth: false, size: .init(width: 599, height: 800)) == .sheet)
}
@Test func squareIsUpright() {
    #expect(HomeLayout.resolve(isPad: false, regularWidth: true, size: .init(width: 700, height: 700)) == .duoUpright)
}
@Test func isDuo() {
    #expect(HomeLayout.duoUpright.isDuo && HomeLayout.duoSideways.isDuo)
    #expect(!HomeLayout.sheet.isDuo && !HomeLayout.panels.isDuo)
}
```

- [ ] **Step 2: Run, expect FAIL** (`cannot find 'HomeLayout' in scope`)

Run: `swift test --package-path Packages/FlightKit --filter HomeLayoutTests`

- [ ] **Step 3: Implement `HomeLayout`** with the spec's four rules in order. `regularWidth` is ignored on the iPhone (the Duo's size class is not trusted). Doc comment on the type names the Duo screens and the Pro Max case.

- [ ] **Step 4: Run, expect PASS**

Run: `swift test --package-path Packages/FlightKit --filter HomeLayoutTests`

- [ ] **Step 5: Commit**

```bash
git add Packages/FlightKit/Sources/FlightKit/App/HomeLayout.swift Packages/FlightKit/Tests/FlightKitTests/HomeLayoutTests.swift
git commit -m "Pick the home layout from the window's shape, with Duo layouts from a 600 pt shorter side"
```

### Task 2: Folding with a card open

**Files:**
- Modify: `Packages/FlightKit/Sources/FlightKit/App/ShellModel.swift` (next to `detent`, line 23)
- Test: `Packages/FlightKit/Tests/FlightKitTests/HomeLayoutTests.swift` (new `@Suite struct ShellLayoutChangeTests` in the same file)

**Interfaces:**
- Consumes: `HomeLayout` (Task 1).
- Produces: `public func didChangeLayout(to layout: HomeLayout)` on `ShellModel`.

- [ ] **Step 1: Write the failing tests**

```swift
@Test @MainActor func foldingWithACardOpenRaisesACollapsedSheet() {
    let shell = ShellModel()
    shell.open(airport: "SFO")
    shell.detent = .collapsed
    shell.didChangeLayout(to: .sheet)
    #expect(shell.detent == .medium)
}
@Test @MainActor func foldingWithNoCardKeepsTheDetent() {
    let shell = ShellModel(); shell.detent = .collapsed
    shell.didChangeLayout(to: .sheet)
    #expect(shell.detent == .collapsed)
}
@Test @MainActor func expandedStaysExpanded() {
    let shell = ShellModel(); shell.open(airport: "SFO"); shell.detent = .expanded
    shell.didChangeLayout(to: .sheet)
    #expect(shell.detent == .expanded)
}
@Test @MainActor func unfoldingLeavesTheDetentAlone() {
    let shell = ShellModel(); shell.open(airport: "SFO"); shell.detent = .collapsed
    shell.didChangeLayout(to: .duoUpright)
    #expect(shell.detent == .collapsed)
    #expect(!shell.path.isEmpty)
}
```

Adjust the `ShellModel()` initializer and `open(airport:)` call to the real ones if they take arguments; the assertions stay.

- [ ] **Step 2: Run, expect FAIL** (`has no member 'didChangeLayout'`)

Run: `swift test --package-path Packages/FlightKit --filter ShellLayoutChangeTests`

- [ ] **Step 3: Implement `didChangeLayout(to:)`**: only when `layout == .sheet`, `!path.isEmpty` and `detent == .collapsed`, set `detent = .medium`. Nothing else changes (`path`, `tabDetents`, focus).

- [ ] **Step 4: Run, expect PASS.** Then the whole suite: `swift test --package-path Packages/FlightKit`. Expected: PASS, same failures as before this plan if any (note them, do not fix them here).

- [ ] **Step 5: Commit**

```bash
git add Packages/FlightKit/Sources/FlightKit/App/ShellModel.swift Packages/FlightKit/Tests/FlightKitTests/HomeLayoutTests.swift
git commit -m "Raise a collapsed sheet to medium when the Duo folds with a card open"
```

### Task 3: The tab pill in `RegularHomeView`

**Files:**
- Modify: `Apps/iOS/RegularHomeView.swift` (`body`, `listRoot`)

**Interfaces:**
- Produces:
  ```swift
  enum HomeTabsStyle { case system, pill }
  // new init parameter, after mapScope, default .system:
  tabs: HomeTabsStyle = .system
  ```
  `RootTabView` passes `.pill` for `.duoSideways` (Task 5).

- [ ] **Step 1: Implement.**
  - `.system`: today's `TabView` with `.tabViewStyle(.sidebarAdaptable)`, unchanged.
  - `.pill`: no `TabView`; `canvas` drawn directly (the one tab on show). `listRoot`'s bottom inset becomes `VStack(spacing: 12) { ToastSlot(text: home.toast); HomeTabPill(tab: $home.tab, bottom: 14, onSearch: onSearch) }`, as `RootSidebarView` does (`Apps/macOS/RootSidebarView.swift:173`), instead of `SearchFieldButton`.
- [ ] **Step 2: Build.** Run: `xcodebuild -scheme SomaFlight-iOS -destination 'generic/platform=iOS Simulator' build`. Expected: `** BUILD SUCCEEDED **`, no new warnings.
- [ ] **Step 3: Commit**

```bash
git add Apps/iOS/RegularHomeView.swift
git commit -m "Let the panel home show the tab pill instead of the system tab bar"
```

### Task 4: `DuoSplitHomeView`, the upright layout

**Files:**
- Create: `Apps/iOS/DuoSplitHomeView.swift` (add to the iOS target in `project.yml` if sources are listed by file; run `xcodegen` only if the repo uses it, check `project.yml` first)

**Interfaces:**
- Consumes: `HomeModel`, `GlobeMap`, `CardStack`, `HomeDestination`, `HomeTabPill`, `ToastSlot`, `ProfileButton`, `Theme` (all existing).
- Produces:
  ```swift
  struct DuoSplitHomeView<TabScreen: View, MapControls: View>: View {
      init(home: HomeModel, selection: Binding<GlobeSelection?>, labels: Bool, threeD: Bool, mapScope: Namespace.ID,
           onSearch: @escaping () -> Void, onSettings: @escaping () -> Void,
           @ViewBuilder tabScreen: () -> TabScreen, @ViewBuilder mapControls: () -> MapControls)
      /// The pane's share of the height between the safe areas.
      static var paneFraction: CGFloat { 0.55 }
  }
  ```
  Same parameters as `RegularHomeView` minus `tabs`, so Task 5 builds both the same way.

- [ ] **Step 1: Implement.**
  - `GlobeMap` full screen, `.safeAreaPadding(.bottom, paneHeight)`, `.ignoresSafeArea()`, black background, `.mapScope(mapScope)`. `paneHeight = paneFraction * (height - safeTop - safeBottom) + safeBottom`, measured with `onGeometryChange` like `compactHome`.
  - Map controls overlay at top trailing, over the globe.
  - Pane at the bottom: `CardStack(path: home.shell.path, onPop: home.shell.close, zoomID: \.zoomID) { root } card: { HomeDestination(home: home, route: $0) }`, `Theme.background`, top corners `Theme.sheetRadius` (`UnevenRoundedRectangle`), `.frame(height: paneHeight)`.
  - `root`: `tabScreen`, `ProfileButton` top trailing (top 19, trailing 16), bottom `safeAreaInset` with `ToastSlot` over `HomeTabPill(tab: $home.tab, bottom: 14, onSearch: onSearch)`.
- [ ] **Step 2: Do not set** `\.sheetDetentActions`, `\.sheetDetent` or `\.sheetContentRoom` in the pane (Review Focus 4: no Expand/Collapse without a sheet). Grep the file: `grep -n "sheetDetent" Apps/iOS/DuoSplitHomeView.swift`. Expected: no output.
- [ ] **Step 3: Add a `#Preview`** at 626 x 890 with the fake `HomeModel` the other iOS previews use (find it with `grep -rn "#Preview" Apps/iOS | head`).
- [ ] **Step 4: Build.** Same command as Task 3. Expected: `** BUILD SUCCEEDED **`.
- [ ] **Step 5: Commit**

```bash
git add Apps/iOS/DuoSplitHomeView.swift   # plus project.yml / project file if Step 1 changed them
git commit -m "Add the upright Duo home: the globe over a fixed pane"
```

### Task 5: Wire the layouts into `RootTabView`

Precondition: "Before starting" check passed.

**Files:**
- Modify: `Apps/iOS/RootTabView.swift` (`isRegular` at line 41, `body`, `regularHome`)

**Interfaces:**
- Consumes: `HomeLayout.resolve` (Task 1), `ShellModel.didChangeLayout(to:)` (Task 2), `RegularHomeView(tabs:)` (Task 3), `DuoSplitHomeView` (Task 4).

- [ ] **Step 0: Take the "before" screenshots** for Task 6 Step 9 (iPhone 17 Pro portrait and landscape, iPhone 17 Pro Max landscape, iPad Pro 13-inch (M5) landscape and Split View) from the current build, before any edit here. Save them in `docs/screens/duo/before/`. Never check out another commit for this: other sessions share the checkout.
- [ ] **Step 1: Implement.**
  - `@State private var windowSize: CGSize = .zero`, measured with `onGeometryChange(for: CGSize.self)` on the root `Group`'s background, `.ignoresSafeArea()` (full window).
  - `private var layout: HomeLayout { HomeLayout.resolve(isPad: UIDevice.current.userInterfaceIdiom == .pad, regularWidth: sizeClass == .regular, size: windowSize) }`. Remove `isRegular`; move its comment to `HomeLayout`.
  - `body` switches: `.sheet` → `compactHome`; `.panels` → `regularHome(tabs: .system)`; `.duoSideways` → `regularHome(tabs: .pill)`; `.duoUpright` → `modals(DuoSplitHomeView(...) { tabScreen } mapControls: { same controls as regularHome }.environment(\.fullPageZoom, pageZoom))`.
  - `.onChange(of: layout) { _, new in home.shell.didChangeLayout(to: new) }`.
  - While `windowSize == .zero` (first frame), `layout` resolves to `.sheet` on the iPhone; that is the intended first frame.
- [ ] **Step 2: Build** (Task 3 command). Expected: `** BUILD SUCCEEDED **`.
- [ ] **Step 3: Run the FlightKit suite** (`swift test --package-path Packages/FlightKit`). Expected: same result as Task 2 Step 4.
- [ ] **Step 4: Commit**

```bash
git add Apps/iOS/RootTabView.swift
git commit -m "Switch the iOS home on HomeLayout: Duo sideways panel and upright split"
```

### Task 6: Screenshot and behaviour checks

No code unless a check fails; a fix goes in the task that owns the file, as a new commit.

**Files:**
- Create: `docs/screens/duo/` (screenshots, PNG, named `<device>-<state>-<tab>.png`)

- [ ] **Step 1: Boot the Duo simulator** (`xcrun simctl create "Duo" com.apple.CoreSimulator.SimDeviceType.iPhone-Duo`, boot, install the Debug build). Find how the simulator folds (Device menu or `simctl` command) and write it in one line at the top of the commit message for this task.
- [ ] **Step 2: Confirm the point sizes.** Log or read `windowSize` in each posture. Expected: cover about 466 x 678, inner 626 x 890 / 890 x 626. If they differ, update the spec's table and the Task 1 tests' sizes, keep the 600 pt rule unless a real Duo size falls on the wrong side of it (then stop and ask).
- [ ] **Step 3: Screenshots**, each tab plus an open flight, in three postures: folded, sideways, upright. Expected: folded matches today's iPhone layout; sideways shows one 402 pt panel with the pill at its foot and globe beside it; upright shows globe over pane.
  - Content width decision: if rows look stretched in the 626 pt pane, add `.frame(maxWidth: 560)` centered to the pane content in `DuoSplitHomeView` (commit "Cap the upright pane's content at 560 pt").
- [ ] **Step 4: Dynamic Type** at Accessibility XL (`xcrun simctl ui <udid> content_size accessibility-extra-large`), sideways: tab title and pill visible, list scrolls.
- [ ] **Step 5: Turn sideways to upright and back** with a flight open: same flight open, one card, no blank pane.
- [ ] **Step 6: Fold with Search open** and "UA15" typed (`-sheet search -searchText UA15` launch arguments): Search still open with "UA15" after the fold, and after unfolding.
- [ ] **Step 7: VoiceOver** (Accessibility Inspector): in the pane and panel, no Expand or Collapse action on the tab title. Folded, both are there.
- [ ] **Step 8: Toast:** follow a flight from Search in the upright and sideways layouts: the toast shows above the pill.
- [ ] **Step 9: Regression screenshots:** iPhone 17 Pro portrait and landscape, iPhone 17 Pro Max landscape, iPad Pro 13-inch (M5) landscape and in Split View. Expected: identical to the `docs/screens/duo/before/` set from Task 5 Step 0.
- [ ] **Step 10: Commit the screenshots**

```bash
git add docs/screens/duo
git commit -m "Duo layout screenshots: folded, sideways, upright, and regressions"
```

- [ ] **Step 11: Owner device check** (not for the agent): fold and unfold on a real Duo with a card open and with Search open. Report in chat.
