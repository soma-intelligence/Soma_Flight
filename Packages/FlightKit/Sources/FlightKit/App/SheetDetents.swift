import SwiftUI

/// The three resting heights of the iOS home sheet, lowest first.
public enum SheetDetent: Int, CaseIterable, Comparable, Hashable, Sendable {
    /// The header and a short peek of the list above the tab pill; the globe takes most of the screen.
    case collapsed
    /// The sheet top a little under the screen's middle, the globe above it.
    case medium
    /// The sheet top just under the status bar, a thin strip of map above it. The map controls hide.
    case expanded

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    /// One step up (VoiceOver's "Expand"), nil at the top.
    public var raised: SheetDetent? { SheetDetent(rawValue: rawValue + 1) }
    /// One step down (VoiceOver's "Collapse"), nil at the bottom.
    public var lowered: SheetDetent? { SheetDetent(rawValue: rawValue - 1) }
}

/// Where the sheet's top rests in each detent on a given screen, and which detent a drag lands on.
///
/// Positions are y values from the top of the screen. The medium and collapsed tops are fractions of the
/// height between the two safe areas, counted from the top one, so they keep the same look on every
/// iPhone: on a 874 pt screen with 62 pt and 34 pt insets they land at about 43% and 67% of the screen.
/// Expanded sits on the top safe area (the system's large detent).
public struct SheetGeometry: Equatable, Sendable {
    /// The full screen height, safe areas included.
    public var screenHeight: CGFloat
    /// Status bar and Dynamic Island.
    public var safeTop: CGFloat
    /// Home indicator.
    public var safeBottom: CGFloat

    /// Medium's top as a fraction of the height between the safe areas.
    public static let mediumFraction: CGFloat = 0.40
    /// Collapsed's top as a fraction of the height between the safe areas.
    public static let collapsedFraction: CGFloat = 0.67
    /// The pinned header at the sheet's top: its 22 pt top padding, the large title, 12 pt under it.
    public static let headerHeight: CGFloat = 74
    /// One peek row of content under the header, the most a collapsed sheet promises to show.
    public static let peekRowHeight: CGFloat = 64
    /// The floating tab pill and search button above the bottom safe area: 8 pt over the 59 pt pill, which
    /// reaches 14 pt down into the home indicator inset.
    public static let tabBarHeight: CGFloat = 53
    /// The least a collapsed sheet keeps above the home indicator: the header, one peek row and the tab
    /// pill. Keeps small screens usable.
    public static var minimumCollapsedContent: CGFloat { headerHeight + peekRowHeight + tabBarHeight }
    /// The least room medium leaves above a collapsed sheet, so the two never meet on a short screen.
    public static let minimumStep: CGFloat = 80
    /// How far a release's speed carries the sheet before it is matched to a detent: the distance a
    /// fling would travel at UIScrollView's normal deceleration, in seconds of the release speed.
    public static let projection: CGFloat = 0.2

    public init(screenHeight: CGFloat, safeTop: CGFloat, safeBottom: CGFloat) {
        self.screenHeight = screenHeight; self.safeTop = safeTop; self.safeBottom = safeBottom
    }

    /// A 6.3 inch iPhone (iPhone 17 Pro), until the real screen is measured.
    public static let standard = SheetGeometry(screenHeight: 874, safeTop: 62, safeBottom: 34)

    private var usable: CGFloat { max(0, screenHeight - safeTop - safeBottom) }

    /// The y of the sheet's top edge resting in `detent`.
    public func top(of detent: SheetDetent) -> CGFloat {
        switch detent {
        case .expanded:
            return safeTop
        case .medium:
            let top = (safeTop + usable * Self.mediumFraction).rounded()
            return min(top, self.top(of: .collapsed) - Self.minimumStep)
        case .collapsed:
            let top = (safeTop + usable * Self.collapsedFraction).rounded()
            return min(top, screenHeight - safeBottom - Self.minimumCollapsedContent)
        }
    }

    /// How much of the screen the sheet covers in `detent`, from its top to the screen's bottom edge.
    public func height(of detent: SheetDetent) -> CGFloat {
        screenHeight - top(of: detent)
    }

    /// The room left for content between the pinned header and the tab pill in `detent`: what shows
    /// of the list. Everything below it is masked off, so nothing draws under the pill.
    public func contentRoom(in detent: SheetDetent) -> CGFloat {
        height(of: detent) - safeBottom - Self.tabBarHeight - Self.headerHeight
    }

    /// The detent whose top is closest to `top`.
    public func nearest(toTop top: CGFloat) -> SheetDetent {
        SheetDetent.allCases.min { abs(self.top(of: $0) - top) < abs(self.top(of: $1) - top) }!
    }

    /// Where a drag released with its top at `top` and moving at `velocity` (points per second, positive
    /// downward) comes to rest: the detent nearest to where the speed would carry it.
    public func snap(top: CGFloat, velocity: CGFloat) -> SheetDetent {
        nearest(toTop: top + velocity * Self.projection)
    }

    /// The system detent that rests the sheet's top at `detent`'s top.
    public func presentationDetent(for detent: SheetDetent) -> PresentationDetent {
        detent == .expanded ? .large : .height(height(of: detent))
    }

    /// The three system detents, for `presentationDetents`.
    public var presentationDetents: Set<PresentationDetent> {
        Set(SheetDetent.allCases.map(presentationDetent(for:)))
    }

    /// Ours for a system detent the sheet settled on; one from a former screen size maps to medium.
    public func detent(for presentation: PresentationDetent) -> SheetDetent {
        SheetDetent.allCases.first { presentationDetent(for: $0) == presentation } ?? .medium
    }
}

/// Moves the home sheet one detent up or down: VoiceOver's "Expand" and "Collapse" on the sheet's title.
public struct SheetDetentActions {
    public var expand: (() -> Void)?
    public var collapse: (() -> Void)?

    public init(expand: (() -> Void)?, collapse: (() -> Void)?) {
        self.expand = expand; self.collapse = collapse
    }
}

public extension EnvironmentValues {
    /// Set by the iOS home on its sheet; nil elsewhere (modal sheets, the Mac).
    @Entry var sheetDetentActions: SheetDetentActions? = nil
    /// The detent the iOS home sheet rests in, for a tab screen that shows more as the sheet rises (the
    /// Friends code row hides at collapsed). Nil elsewhere (modal sheets, the Mac): everything shows.
    @Entry var sheetDetent: SheetDetent? = nil
}
