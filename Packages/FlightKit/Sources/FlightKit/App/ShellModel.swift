import Observation
import SwiftUI

/// A card stacked inside the home sheet, sliding up over the one below.
public enum SheetRoute: Hashable, Sendable {
    case flight(Flight.ID)
    /// A flight from the Passport history, shown with the same sheet as a followed flight.
    case pastFlight(PastFlight)
    case airport(String)
    /// A friend's page: their flights, the switches about them, their Passport totals.
    case friend(UUID)
    /// One of a friend's flights in the flight sheet, read only.
    case friendFlight(FriendFlight)
    /// The Airports list (the map's control tower button); airports open over it.
    case airports
}

/// Navigation state of the iOS home: what the sheet shows, its detent, and where the globe looks.
@MainActor @Observable
public final class ShellModel {
    public var path: [SheetRoute] = []
    /// The sheet's resting height. Each tab keeps its own for the session (`showTab(_:from:)`).
    public var detent: SheetDetent = .medium
    /// The detent each tab was left in, this session. A tab not seen yet opens at medium.
    @ObservationIgnored private var tabDetents: [HomeTab: SheetDetent] = [:]
    /// Bumped when the screen on top is opened again, so the globe comes back onto it.
    public private(set) var recenter = 0
    /// The arc of the open flight, kept so the camera holds it if the flight drops out of the list.
    @ObservationIgnored private var lastRoute: (id: Flight.ID, route: Route)?

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

    /// Opens the Airports list as the only screen; opening it again recentres the globe.
    public func openAirports() {
        if path == [.airports] { recenter += 1 } else { path = [.airports] }
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
        case .friend, .airports, nil:
            nil
        }
    }

    /// Leaving `old` for `new`: remembers the detent `old` was in and puts back the one `new` was left in
    /// (medium the first time).
    public func showTab(_ new: HomeTab, from old: HomeTab) {
        guard new != old else { return }
        tabDetents[old] = detent
        detent = tabDetents[new] ?? .medium
    }

    /// The full-screen map's bottom safe area: the medium sheet's height, whatever the detent. The globe
    /// (and an open flight's arc) is framed above the medium sheet's top, which is clear of the sheet in
    /// collapsed too, and hidden behind it in expanded. It used to follow the settled detent, gliding the
    /// map's safe area under the moving sheet, and MapKit re-framed the globe with a visible jump when the
    /// sheet went down, up and down again. Now a detent change gives the map nothing new: the globe holds
    /// still and the sheet slides over it. The cost: a collapsed sheet no longer frames the globe lower and
    /// larger in the extra room.
    public static func mapInset(in geometry: SheetGeometry) -> CGFloat {
        geometry.height(of: .medium)
    }

    /// How far MapKit's Apple Maps logo and Legal link reach under the sheet's top edge: the safe area's
    /// bottom sits this far below it, and the logo, drawn a few points above the safe area's bottom,
    /// keeps a sliver above the sheet. An estimate, not measured on a device: raise it to hide more.
    public static let legalPeek: CGFloat = 12

    /// The full-screen map's safe area on the iPhone in `detent`. The camera keeps framing the area
    /// above the medium sheet (`mapInset(in:)`), but MapKit draws its logo and Legal link at the bottom
    /// of the safe area, so that bottom follows the sheet's top (`legalPeek` under it) while the top
    /// moves by the same amount the other way: the safe area keeps the framed area's centre, where
    /// MapKit draws the camera's centre, so the globe holds still. A collapsed sheet would push the top
    /// above the screen, so the map is lifted that far (`GlobeInsets.lift`) and ends that far above the
    /// screen's bottom, which the sheet always covers. Expanded, the logo stays where medium framing
    /// puts it, under the sheet, which covers the map there anyway.
    ///
    /// Apple's MapKit terms want the logo and the Legal link shown, never hidden: in collapsed and medium a
    /// few points of the logo stay above the sheet and the Legal link can still be tapped.
    public static func globeInsets(in geometry: SheetGeometry, detent: SheetDetent) -> GlobeInsets {
        let screenTop = geometry.safeTop, framedBottom = geometry.top(of: .medium)
        let lift = max(0, geometry.top(of: .collapsed) + legalPeek - (screenTop + framedBottom))
        // Where the safe area ends on screen: the legal line.
        let line = detent == .expanded ? framedBottom : geometry.top(of: detent) + legalPeek
        let height = geometry.screenHeight
        return GlobeInsets(lift: lift,
                           framedTop: screenTop + lift,
                           framedBottom: height - lift - framedBottom,
                           safeTop: screenTop + framedBottom - line + lift,
                           safeBottom: height - lift - line)
    }

    private func raiseIfCollapsed() {
        if detent == .collapsed { detent = .medium }
    }
}
