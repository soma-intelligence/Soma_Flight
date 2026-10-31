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

    /// Followed flights: one arc each, coloured by delay, planes for the ones with a position. A flight the
    /// app cannot hear about (offline, or in the air with no update for a while) has its plane where the
    /// estimate puts it on the arc instead (`FlightEstimate`), drawn as an estimate.
    public static func followed(_ flights: [Flight], lookup: (String) -> Airport?, online: Bool = true,
                                now: Date = .now) -> GlobeContent {
        let routes = flights.compactMap { route(for: $0, lookup: lookup) }
        let planes = flights.compactMap { plane(for: $0, lookup: lookup, online: online, now: now) }
        let codes = flights.flatMap { [$0.originIcao, $0.destinationIcao] }
        return GlobeContent(routes: routes, planes: planes, airports: endpoints(codes, lookup: lookup))
    }

    /// Friends' flights (the Friends tab): one dashed arc each and their planes, in the friends colour.
    public static func friends(_ flights: [FriendFlight], lookup: (String) -> Airport?) -> GlobeContent {
        var seen: Set<Flight.ID> = []
        let unique = flights.map(\.flight).filter { seen.insert($0.id).inserted }
        let routes = unique.compactMap { f in
            route(for: f, lookup: lookup).map {
                Route(id: "friend-\($0.id)", from: $0.from, to: $0.to, level: $0.level, isPast: false, isFriend: true)
            }
        }
        let planes = unique.compactMap { FlightAnnotationModel(flight: $0, isFriend: true) }
        let codes = unique.flatMap { [$0.originIcao, $0.destinationIcao] }
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

    /// A followed flight's plane: at the estimate when there is one with a place, else at its last position.
    public static func plane(for flight: Flight, lookup: (String) -> Airport?, online: Bool, now: Date)
        -> FlightAnnotationModel? {
        if let e = flight.estimate(online: online, now: now, lookup: lookup), let c = e.coordinate {
            return FlightAnnotationModel(id: flight.id, ident: flight.ident, coordinate: c, heading: e.heading ?? 0,
                                         level: flight.level, isEstimated: true)
        }
        return FlightAnnotationModel(flight: flight)
    }

    /// The arc of one flight, keyed by the flight id; nil when an end is unknown.
    public static func route(for flight: Flight, lookup: (String) -> Airport?) -> Route? {
        guard let o = lookup(flight.originIcao), let d = lookup(flight.destinationIcao) else { return nil }
        return Route(id: flight.id.uuidString, from: o.coordinate, to: d.coordinate, level: flight.level, isPast: false)
    }

    /// Each airport once, the busiest first (most flights touching it here; ties keep first-seen order),
    /// so `labelHidden` keeps the bigger one's label when two sit close together.
    private static func endpoints(_ codes: [String], lookup: (String) -> Airport?) -> [Airport] {
        var seen: Set<String> = []
        let found = codes.compactMap { lookup($0) }
        var count: [String: Int] = [:]
        for a in found { count[a.id, default: 0] += 1 }
        let unique = found.filter { seen.insert($0.id).inserted }
        return unique.enumerated().sorted {
            (count[$0.element.id] ?? 0, -$0.offset) > (count[$1.element.id] ?? 0, -$1.offset)
        }.map(\.element)
    }

    /// Closer than this, two airport labels pile up on the globe (SFO and OAK are 18 km apart).
    public static let labelSpacingKm: Double = 100

    /// The airports whose label the globe hides: walking the list in order (busiest first), an airport
    /// within `labelSpacingKm` of one already labelled keeps its dot but loses its label.
    public static func labelHidden(_ airports: [Airport], within km: Double = labelSpacingKm) -> Set<String> {
        var shown: [Airport] = []
        var hidden: Set<String> = []
        for a in airports {
            if shown.contains(where: { distanceKm($0.coordinate, a.coordinate) < km }) {
                hidden.insert(a.id)
            } else {
                shown.append(a)
            }
        }
        return hidden
    }
}

public extension Airport {
    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat, longitude: lon) }
}
