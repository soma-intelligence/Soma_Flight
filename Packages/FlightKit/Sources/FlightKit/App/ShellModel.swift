import Observation
import SwiftUI

/// A screen pushed inside the home sheet.
public enum SheetRoute: Hashable, Sendable {
    case flight(Flight.ID)
    case airport(String)
}

/// Navigation state of the iOS home: what the sheet shows, its detent, and where the globe looks.
@MainActor @Observable
public final class ShellModel {
    public var path: [SheetRoute] = []
    public var detent: PresentationDetent = .medium
    /// Bumped when the screen on top is opened again, so the globe comes back onto it.
    public private(set) var recenter = 0
    /// The arc of the open flight, kept so the camera holds it if the flight drops out of the list.
    @ObservationIgnored private var lastRoute: (id: Flight.ID, route: Route)?

    public static let detents: Set<PresentationDetent> = [collapsed, .medium, .large]
    public static let collapsed = PresentationDetent.height(120)

    public init() {}

    /// Opens a flight as the only screen. Opening the one already shown recentres the globe on it.
    public func open(flight id: Flight.ID, route: Route?) {
        if path == [.flight(id)] { recenter += 1 } else { path = [.flight(id)] }
        if let route { lastRoute = (id, route) }
        raiseIfCollapsed()
    }

    /// Pushes an airport. One already in the stack is returned to rather than pushed again, so tapping
    /// pins back and forth never grows the stack; the one on top recentres the globe.
    public func open(airport code: String) {
        if let i = path.firstIndex(of: .airport(code)) {
            if i == path.count - 1 { recenter += 1 } else { path.removeSubrange((i + 1)...) }
        } else {
            path.append(.airport(code))
        }
        raiseIfCollapsed()
    }

    public func close() {
        if !path.isEmpty { path.removeLast() }
    }

    /// Back to the tab root, forgetting the open flight (account change).
    public func reset() {
        path = []
        lastRoute = nil
    }

    /// The camera follows the screen on top of the sheet. A flight's live arc wins; when the flight is no
    /// longer in the list, the arc it was opened with holds the camera while its detail stays up.
    public func focus(route: (Flight.ID) -> Route?, airport: (String) -> Airport?) -> GlobeFocus? {
        switch path.last {
        case .flight(let id):
            (route(id) ?? (lastRoute?.id == id ? lastRoute?.route : nil)).map(GlobeFocus.route)
        case .airport(let code):
            airport(code).map(GlobeFocus.airport)
        case nil:
            nil
        }
    }

    /// How far the map reaches under the sheet's top edge, so the rounded corners show globe, not black.
    public static let sheetOverlap: CGFloat = 44

    /// Where the map stops above the screen's bottom edge, from the settled detent rather than the live
    /// sheet height, so a drag does not relayout the map every frame. `.large` keeps the medium inset:
    /// the globe is hidden then, and the map keeps a sane content area.
    public static func mapInset(for detent: PresentationDetent, screenHeight: CGFloat) -> CGFloat {
        detent == collapsed ? 120 : (screenHeight / 2).rounded()
    }

    private func raiseIfCollapsed() {
        if detent == Self.collapsed { detent = .medium }
    }
}
