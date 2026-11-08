import CoreLocation
import Foundation

/// What the flight sheet keeps on the device before departure, so the flight still reads in the air with
/// no connection: the flight as last heard, both airports (with their coordinates and time zones), the
/// aircraft type and the route's points. The region names and the sun come from bundled tables, so
/// nothing else is needed. Saved in the account's cache (`CacheStore`), wiped with it at sign-out.
public struct OfflineFlightPack: Codable, Sendable, Equatable {
    public struct RoutePoint: Codable, Sendable, Equatable {
        public var lat: Double
        public var lon: Double
    }

    public var flight: Flight
    public var origin: Airport
    public var destination: Airport
    public var aircraft: AircraftType?
    /// The great circle from `origin` to `destination`, `routeSegments + 1` points.
    public var route: [RoutePoint]
    public var savedAt: Date

    /// Points kept along the route (about 70 km apart on a long haul).
    public static let routeSegments = 128
    /// How long before departure the sheet starts keeping a pack.
    public static let window: TimeInterval = 24 * 3600
    /// Packs kept at most, newest first.
    public static let limit = 20

    public init(flight: Flight, origin: Airport, destination: Airport, aircraft: AircraftType?, savedAt: Date) {
        self.flight = flight; self.origin = origin; self.destination = destination; self.aircraft = aircraft
        self.savedAt = savedAt
        let n = Self.routeSegments
        route = (0...n).map {
            let c = RouteEstimator.point(from: origin.coordinate, to: destination.coordinate, fraction: Double($0) / Double(n))
            return RoutePoint(lat: c.latitude, lon: c.longitude)
        }
    }

    /// The position engine for the kept flight.
    public var estimator: RouteEstimator? {
        RouteEstimator(flight: flight, origin: origin.coordinate, destination: destination.coordinate, aircraft: aircraft)
    }

    /// The route as coordinates.
    public var routeCoordinates: [CLLocationCoordinate2D] {
        route.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
    }

    /// Worth keeping from `window` before the departure until the flight is over: still to fly or flying.
    public static func isWorthSaving(_ f: Flight, now: Date) -> Bool {
        switch f.status {
        case .landed, .arrived, .canceled, .diverted: return false
        case .scheduled, .departed, .enRoute, .unknown: break
        }
        guard let out = f.actualOut ?? f.estimatedOut ?? f.scheduledOut, now >= out.addingTimeInterval(-window) else {
            return false
        }
        let inn = f.actualIn ?? f.estimatedIn ?? f.scheduledIn ?? out.addingTimeInterval(window)
        return now < inn.addingTimeInterval(3 * 3600)
    }

    /// Drops packs a day past their arrival and keeps the newest `limit`.
    public static func pruned(_ packs: [OfflineFlightPack], now: Date) -> [OfflineFlightPack] {
        packs.filter { p in
            let end = p.flight.actualIn ?? p.flight.estimatedIn ?? p.flight.scheduledIn ?? p.flight.scheduledOut ?? p.savedAt
            return end.addingTimeInterval(window) > now
        }
        .sorted { $0.savedAt > $1.savedAt }
        .prefix(limit)
        .map { $0 }
    }
}

/// Where the offline packs live (the account's cache).
public protocol OfflinePackCache: Sendable {
    func save(pack: OfflineFlightPack) async
    func pack(for id: Flight.ID) async -> OfflineFlightPack?
}
