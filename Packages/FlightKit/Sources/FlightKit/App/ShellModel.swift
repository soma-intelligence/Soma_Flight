import Observation
import SwiftUI

/// A screen pushed inside the home sheet.
public enum SheetRoute: Hashable, Sendable {
    case flight(Flight.ID)
    /// A flight from the Passport history, shown with the same sheet as a followed flight.
    case pastFlight(PastFlight)
    case airport(String)
    /// A friend's page: their flights, the switches about them, their Passport totals.
    case friend(UUID)
    /// One of a friend's flights in the flight sheet, read only.
    case friendFlight(FriendFlight)
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

    /// Opens a past flight as the only screen, its arc held for the camera.
    public func open(past flight: PastFlight, route: Route?) {
        if path == [.pastFlight(flight)] { recenter += 1 } else { path = [.pastFlight(flight)] }
        if let route { lastRoute = (flight.id, route) }
        raiseIfCollapsed()
    }

    /// Opens a friend's page as the only screen.
    public func open(friend id: UUID) {
        if path == [.friend(id)] { recenter += 1 } else { path = [.friend(id)] }
        raiseIfCollapsed()
    }

    /// Opens a friend's flight: over their page when it is on top, else as the only screen.
    public func open(friendFlight ff: FriendFlight, route: Route?) {
        if path.last == .friendFlight(ff) {
            recenter += 1
        } else if path.last == .friend(ff.friendId) {
            path.append(.friendFlight(ff))
        } else {
            path = [.friendFlight(ff)]
        }
        if let route { lastRoute = (ff.flight.id, route) }
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
        case .pastFlight(let f):
            (lastRoute?.id == f.id ? lastRoute?.route : nil).map(GlobeFocus.route)
        case .airport(let code):
            airport(code).map(GlobeFocus.airport)
        case .friendFlight(let ff):
            (route(ff.flight.id) ?? (lastRoute?.id == ff.flight.id ? lastRoute?.route : nil)).map(GlobeFocus.route)
        case .friend, nil:
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
