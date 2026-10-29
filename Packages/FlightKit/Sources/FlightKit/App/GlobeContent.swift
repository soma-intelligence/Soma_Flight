import CoreLocation
import Foundation

/// What the shell draws on the globe for a tab: arcs, planes and the airports at their ends.
public struct GlobeContent: Sendable, Equatable {
    public var routes: [Route]
    public var planes: [FlightAnnotationModel]
    public var airports: [Airport]

    public init(routes: [Route] = [], planes: [FlightAnnotationModel] = [], airports: [Airport] = []) {
        self.routes = routes; self.planes = planes; self.airports = airports
    }

    /// Followed flights: one arc each, coloured by delay, planes for the ones with a position.
    public static func followed(_ flights: [Flight], lookup: (String) -> Airport?) -> GlobeContent {
        let routes = flights.compactMap { route(for: $0, lookup: lookup) }
        let planes = flights.compactMap(FlightAnnotationModel.init(flight:))
        let codes = flights.flatMap { [$0.originIcao, $0.destinationIcao] }
        return GlobeContent(routes: routes, planes: planes, airports: endpoints(codes, lookup: lookup))
    }

    /// Past flights: one faint arc per airport pair, whichever way it was flown.
    public static func past(_ flights: [PastFlight], lookup: (String) -> Airport?) -> GlobeContent {
        var seen: Set<String> = []
        var routes: [Route] = []
        for p in flights {
            let pair = [p.originIcao, p.destinationIcao].sorted().joined(separator: "-")
            guard !seen.contains(pair), let o = lookup(p.originIcao), let d = lookup(p.destinationIcao) else { continue }
            seen.insert(pair)
            routes.append(Route(id: "past-\(pair)", from: o.coordinate, to: d.coordinate, level: .onTime, isPast: true))
        }
        let codes = flights.flatMap { [$0.originIcao, $0.destinationIcao] }
        return GlobeContent(routes: routes, airports: endpoints(codes, lookup: lookup))
    }

    /// The arc of one flight, keyed by the flight id; nil when an end is unknown.
    public static func route(for flight: Flight, lookup: (String) -> Airport?) -> Route? {
        guard let o = lookup(flight.originIcao), let d = lookup(flight.destinationIcao) else { return nil }
        return Route(id: flight.id.uuidString, from: o.coordinate, to: d.coordinate, level: flight.level, isPast: false)
    }

    private static func endpoints(_ codes: [String], lookup: (String) -> Airport?) -> [Airport] {
        var seen: Set<String> = []
        return codes.compactMap { lookup($0) }.filter { seen.insert($0.id).inserted }
    }
}

public extension Airport {
    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat, longitude: lon) }
}
