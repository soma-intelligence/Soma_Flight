import Foundation

/// What the globe draws and how strongly, once an isolated flight is taken into account. With no
/// isolation everything shows at full strength. With one, the flight's arc, its two airports (labelled)
/// and its plane stay at full strength, and the rest shows at `fade` (unlabelled), then not at all at 0,
/// so nothing invisible can still be tapped.
struct GlobeLayers {
    struct RouteLayer: Identifiable {
        var route: Route
        var opacity: Double
        var id: String { route.id }
    }

    struct AirportLayer: Identifiable {
        var airport: Airport
        var opacity: Double
        var titled: Bool
        var id: String { airport.id }
    }

    struct PlaneLayer: Identifiable {
        var plane: FlightAnnotationModel
        var opacity: Double
        var id: Flight.ID { plane.id }
    }

    var routes: [RouteLayer]
    var airports: [AirportLayer]
    var planes: [PlaneLayer]

    init(routes: [Route], planes: [FlightAnnotationModel], airports: [Airport], isolation: GlobeIsolation?, fade: Double) {
        guard let iso = isolation else {
            let hidden = GlobeContent.labelHidden(airports)
            self.routes = routes.map { RouteLayer(route: $0, opacity: 1) }
            self.airports = airports.map { AirportLayer(airport: $0, opacity: 1, titled: !hidden.contains($0.id)) }
            self.planes = planes.map { PlaneLayer(plane: $0, opacity: 1) }
            return
        }
        let fade = min(1, max(0, fade))
        let keep = Set(iso.airports.map(\.id))
        let others = fade > 0 ? routes.filter { !iso.isSameArc($0) } : []
        self.routes = others.map { RouteLayer(route: $0, opacity: fade) } + [RouteLayer(route: iso.route, opacity: 1)]
        let otherAirports = fade > 0 ? airports.filter { !keep.contains($0.id) } : []
        var ends: [Airport] = []
        for a in iso.airports where !ends.contains(where: { $0.id == a.id }) { ends.append(a) }
        let hidden = GlobeContent.labelHidden(ends)
        self.airports = otherAirports.map { AirportLayer(airport: $0, opacity: fade, titled: false) }
            + ends.map { AirportLayer(airport: $0, opacity: 1, titled: !hidden.contains($0.id)) }
        let otherPlanes = fade > 0 ? planes.filter { $0.id != iso.plane?.id } : []
        self.planes = otherPlanes.map { PlaneLayer(plane: $0, opacity: fade) }
            + (iso.plane.map { [PlaneLayer(plane: $0, opacity: 1)] } ?? [])
    }

    /// The point `t` (0 to 1) of the way from `start` to `end` along a smooth step, so a fade eases in and out.
    static func eased(from start: Double, to end: Double, at t: Double) -> Double {
        let t = min(1, max(0, t))
        return start + (end - start) * t * t * (3 - 2 * t)
    }
}
