# Soma Flight on the iPhone Duo: folded, sideways and upright

Date: 2026-11-08. Owner picked the layouts in chat the same day: the panel layout when the open Duo is
sideways, a globe-over-pane split when it is upright, today's sheet when it is folded.

## Why

The iPhone Duo (iPhone19,4, announced 2026-09-09) is Apple's first foldable iPhone. It has two screens:

| Screen | Size | Pixels | Points (assumed @3x) |
|---|---|---|---|
| Cover (folded) | 5.4 in | 1398 x 2034 | about 466 x 678 |
| Inner (unfolded) | 7.6 in | 1878 x 2670 | about 626 x 890, near square (1:1.42) |

Soma Flight picks its home layout in `RootTabView.isRegular`
(`Apps/iOS/RootTabView.swift`): the panel layout (`RegularHomeView`) only when
`userInterfaceIdiom == .pad`. The Duo is an iPhone, so the unfolded inner screen gets the iPhone
sheet stretched across a near square screen. The globe hides under a 626 pt wide sheet, and the shared
screens, drawn for 402 pt (`RegularHomeView.panelWidth`), stretch with it.

The Duo is never wide enough for two panels (`RegularHomeView.twoPanelWidth` is 1100 pt), so it gets one
panel at most.

Priority: this is not a GOAL.md release blocker (line 1) and not on any line above 6. It is an owner
addition (2026-11-08) and waits behind lines 1 to 4. It touches line 4 (store presence) only if App
Store Connect asks for Duo screenshots. It needs no paid call, deploy or cloud change.

## What the traveller sees

1. **Folded (cover screen).** The iPhone home as it is today: the globe under the resizable sheet,
   the tab pill and search at the bottom.
2. **Unfolded, held sideways (890 x 626 pt).** The globe across the screen, the tab's screen in one
   floating panel on the left (402 pt), about 456 pt of globe beside it. An open flight, airport or friend
   slides up as a card inside the panel, as in the iPad's one-panel window. The tab pill and the search
   button sit at the panel's foot, where the iPhone has them.
3. **Unfolded, held upright (626 x 890 pt).** The globe fills the top 45% of the screen. A fixed pane
   fills the rest, full width: the tab's screen, cards sliding up over it, the tab pill and search at its
   foot. The pane does not drag and has no detents.
4. **Folding or unfolding** keeps everything: the tab, the open card, the globe's focus, an open
   Search or Settings.

## Design

### 1. The layout rule: `HomeLayout`

A new enum in FlightKit (`Packages/FlightKit/Sources/FlightKit/App/HomeLayout.swift`), a pure
function of the idiom and the window size, so it is unit tested without a device:

```swift
public enum HomeLayout: Equatable, Sendable {
    case sheet         // any iPhone screen but the Duo's inner one, and an iPad in a compact width
    case panels        // an iPad in a regular width (today's RegularHomeView)
    case duoSideways   // the Duo's inner screen, wider than tall
    case duoUpright    // the Duo's inner screen, taller than wide

    public static func resolve(isPad: Bool, regularWidth: Bool, size: CGSize) -> HomeLayout
}
```

Rules, in order:

1. `isPad` and `regularWidth`: `.panels`.
2. `isPad` and not `regularWidth`: `.sheet`.
3. iPhone with `min(size.width, size.height) >= 600`: `.duoSideways` when `size.width > size.height`,
   `.duoUpright` otherwise.
4. Every other iPhone: `.sheet`.

The 600 pt test on the shorter side is what keeps an iPhone 17 Pro Max on its side (956 x 440 pt) on
the sheet, as `RootTabView`'s comment requires ("the phone layout never changes"). No device model is
checked: any future iPhone screen with a shorter side of 600 pt or more gets the Duo layouts.

`RootTabView` measures its window with `onGeometryChange` (the same way `compactHome` already
measures `SheetGeometry`) and switches on `HomeLayout` instead of `isRegular`.

### 2. Sideways: `RegularHomeView` in one-panel mode

`RegularHomeView` already lays out one panel when the window is under `twoPanelWidth`: the list panel
on the left, cards stacked inside it, the globe framed in the rest with `safeAreaPadding(.leading,
panelSide)`. The Duo reuses it with one change:

- `RegularHomeView` takes a `tabs` parameter: `.system` (today: `TabView` with
  `.tabViewStyle(.sidebarAdaptable)`) or `.pill`. On the iPhone idiom `sidebarAdaptable` puts the tab
  bar at the bottom, over the panel and the globe. With `.pill`, the system tab bar is hidden and the
  panel's foot shows `HomeTabPill` beside the round search button, as `RootSidebarView` does on the Mac.
  `.duoSideways` passes `.pill`; `.panels` keeps `.system`.

At 626 pt tall the panel is short. The tab screens already handle a short panel on the iPad in Split
View; the screenshot check below confirms it on the Duo.

### 3. Upright: `DuoSplitHomeView`

A new view in `Apps/iOS/DuoSplitHomeView.swift`:

- `GlobeMap` across the whole screen, with `safeAreaPadding(.bottom, paneHeight)` so the camera
  frames arcs and airports in the visible top part.
- The pane: `CardStack(path: home.shell.path, ...)` over the tab root, the same card stack
  `RegularHomeView.listPanel` uses, with `Theme.background`, `Theme.sheetRadius` top corners, and
  `HomeTabPill` plus the search button in a bottom `safeAreaInset`.
- `paneHeight` is 55% of the height between the safe areas. Fixed: no drag, no detents.
- Map controls (3D, place names, Airports, Radar) at the globe's top trailing corner, as on the
  sheet layout's medium detent.
- The `ProfileButton` at the pane's top trailing corner, as on the iPhone sheet.

Content width: the shared screens were drawn for 402 pt. The pane is 626 pt wide. If the screenshots
show stretched rows (a flight row with its times flung to the edges), the pane's content gets
`frame(maxWidth: 560)`, centered. Decided from the screenshots, not in advance.

The modal sheets (Search, Settings, Passport pages, invitations, imports) hang from it through
`RootTabView.modals`, as for the other two layouts.

### 4. Folding and unfolding

- `HomeModel` and its `ShellModel` live above the layouts, so the tab, `shell.path` (the open card) and
  `home.focus` survive a layout switch unchanged.
- Folding with a card open: if `shell.detent` is `.collapsed`, it moves to `.medium`, so the card is in
  view on the cover screen.
- `showSearch` and `showSettings` are `RootTabView` state, so the sheets present again over the new
  layout. A switch tears down the old view tree; the device check below confirms the sheets come back
  without a flash or a lost search query.
- `GlobeMap` is rebuilt on a switch. It starts from `home.focus`, so the camera lands where it was.

### 5. Folded

No new layout. `SheetGeometry` already sets `minimumCollapsedContent` and `minimumStep` for short
screens. Only the screenshot check: on 678 pt the medium detent must leave a useful stretch of globe,
and the collapsed sheet must show its header, one peek row and the pill.

## Not in this spec

- Half-folded (tabletop) use. iOS gives no posture API that this spec knows of.
- Two panels on the Duo. It is never 1100 pt wide.
- Any change to the iPad, Mac, Watch or widget layouts.
- A draggable split in the upright layout.

## Testing

- **Unit tests** (`FlightKitTests/HomeLayoutTests.swift`) for `HomeLayout.resolve`:
  Duo inner upright (626 x 890) and sideways (890 x 626), Duo cover (466 x 678),
  iPhone 17 Pro (402 x 874) both ways, iPhone 17 Pro Max sideways (956 x 440), iPad regular and
  compact. Edge: a shorter side of exactly 600 pt is a Duo layout.
- **Simulator screenshots**, Duo simulator, each tab plus an open flight: folded, sideways, upright.
  Confirm the @3x assumption and the point sizes above from the simulator.
- **Regression screenshots:** iPhone 17 Pro portrait and landscape, iPhone 17 Pro Max landscape,
  iPad 13 inch landscape and Split View. Each must match today's layout.
- **Device check (owner):** fold and unfold with a card open and with Search open.

## Working note

On 2026-11-08 `Apps/iOS/RootTabView.swift` had uncommitted edits from another session in this
checkout. The implementation starts after those land, and stages explicit paths only.

## Sources

- The Apple Wiki, iPhone19,4: https://theapplewiki.com/wiki/IPhone19,4
- TidBITS, "Apple unfolds the iPhone Duo": https://tidbits.com/2026/09/11/apple-unfolds-the-iphone-duo/
- Gigazine: https://gigazine.net/gsc_news/en/20260910-apple-iphone-duo/
