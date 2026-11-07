import CoreLocation
import Foundation

/// One plane in the air, as the radar draws it.
public struct NearbyFlight: Identifiable, Hashable, Sendable {
    /// The provider's flight id.
    public var id: String
    /// The flight number as people say it ("UA1527").
    public var ident: String
    public var `operator`: String?
    /// ICAO aircraft type ("B789").
    public var type: String?
    public var latitude: Double
    public var longitude: Double
    public var altitudeFeet: Int?
    public var groundspeedKnots: Int?
    /// Degrees clockwise from north; nil when the provider sent none.
    public var heading: Double?
    public var origin: String?
    public var destination: String?

    public init(id: String, ident: String, operator: String? = nil, type: String? = nil, latitude: Double,
                longitude: Double, altitudeFeet: Int? = nil, groundspeedKnots: Int? = nil, heading: Double? = nil,
                origin: String? = nil, destination: String? = nil) {
        self.id = id; self.ident = ident; self.operator = `operator`; self.type = type
        self.latitude = latitude; self.longitude = longitude; self.altitudeFeet = altitudeFeet
        self.groundspeedKnots = groundspeedKnots; self.heading = heading; self.origin = origin
        self.destination = destination
    }

    public var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
}

/// What one radar read answers.
public struct NearbyFlightsResult: Sendable, Equatable {
    public var flights: [NearbyFlight]
    public var fetchedAt: Date
    /// The backend could not refresh and sent what it had cached.
    public var stale: Bool
    /// More flights are in the area than the answer holds.
    public var truncated: Bool

    public init(flights: [NearbyFlight], fetchedAt: Date, stale: Bool = false, truncated: Bool = false) {
        self.flights = flights; self.fetchedAt = fetchedAt; self.stale = stale; self.truncated = truncated
    }
}

/// Flights in the air around a place, for the radar. They come from AeroAPI's search, which costs money per
/// call: live builds use `SupabaseNearbyFlightsService` (edge function `nearby-flights`, cached 60 seconds per
/// area and under the backend's daily spend cap) only when Info.plist turns the radar on (`RADAR_ENABLED`),
/// and the backend is off until the owner sets `RADAR_ENABLED=true` and `AEROAPI_KEY`. Otherwise
/// `UnavailableNearbyFlightsService` (no calls, no button); screenshot runs (`-useFakes`) use
/// `FakeNearbyFlightsService`.
public protocol NearbyFlightsService: Sendable {
    /// False hides the radar's entry point.
    var isAvailable: Bool { get }
    /// Flights in the air within about `radiusKm` of the point.
    func nearby(latitude: Double, longitude: Double, radiusKm: Double) async throws(APIError) -> NearbyFlightsResult
}

/// Live builds with the radar off: nothing, and no network call.
public struct UnavailableNearbyFlightsService: NearbyFlightsService {
    public init() {}
    public var isAvailable: Bool { false }
    public func nearby(latitude: Double, longitude: Double, radiusKm: Double) async throws(APIError) -> NearbyFlightsResult {
        throw .providerUnavailable
    }
}

/// Believable traffic for screenshot runs and tests: a dozen planes crossing the area on straight lines at
/// airliner speeds, placed from the clock, so each read finds them a little further on. The same area at the
/// same time always shows the same planes.
public struct FakeNearbyFlightsService: NearbyFlightsService {
    public var nextError: APIError?
    private let now: @Sendable () -> Date

    public init(now: @escaping @Sendable () -> Date = { .now }, nextError: APIError? = nil) {
        self.now = now; self.nextError = nextError
    }

    public var isAvailable: Bool { true }

    public func nearby(latitude: Double, longitude: Double, radiusKm: Double) async throws(APIError) -> NearbyFlightsResult {
        if let nextError { throw nextError }
        let t = now()
        return NearbyFlightsResult(flights: Self.traffic(latitude: latitude, longitude: longitude, radiusKm: radiusKm, at: t),
                                   fetchedAt: t)
    }

    private static let airlines: [(code: String, operatorCode: String, type: String)] = [
        ("UA", "UAL", "B789"), ("DL", "DAL", "A321"), ("AA", "AAL", "B738"), ("AF", "AFR", "A359"),
        ("BA", "BAW", "A35K"), ("LH", "DLH", "A320"), ("WN", "SWA", "B38M"), ("AS", "ASA", "E75L"),
    ]
    private static let places = ["KSFO", "KJFK", "KLAX", "EGLL", "LFPG", "EDDF", "KSEA", "KORD", "KDEN", "KBOS"]

    /// The planes inside `radiusKm` of the point at time `t`.
    static func traffic(latitude: Double, longitude: Double, radiusKm: Double, at t: Date, count: Int = 12) -> [NearbyFlight] {
        let radius = max(10, min(radiusKm, 150))
        let kmPerDegree = 111.2
        let cosLat = max(0.2, cos(latitude * .pi / 180))
        // The same area (to a quarter degree) and the same plane number give the same plane.
        let cell = (Int((latitude * 4).rounded(.down)) &* 73_856_093) ^ (Int((longitude * 4).rounded(.down)) &* 19_349_663)
        var out: [NearbyFlight] = []
        for i in 0..<count {
            var h = UInt64(bitPattern: Int64(cell &+ i &* 2_654_435_761)) &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            func next() -> Double {
                h = h &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                return Double(h >> 11) / Double(1 << 53)
            }
            let heading = (next() * 360).rounded()
            let knots = 280 + (next() * 200).rounded()
            let across = (next() * 1.2 - 0.6) * radius
            let phase = next()
            let airline = airlines[Int(next() * Double(airlines.count)) % airlines.count]
            let number = 100 + Int(next() * 8_800)
            let from = places[Int(next() * Double(places.count)) % places.count]
            var to = places[Int(next() * Double(places.count)) % places.count]
            if to == from { to = places[(places.firstIndex(of: from)! + 1) % places.count] }
            let altitude = (180 + Int(next() * 200)) * 100
            // One crossing of the area takes 2R / speed; the plane is at fraction p of it.
            let kmPerSecond = knots * 1.852 / 3_600
            let crossing = 2 * radius / kmPerSecond
            let p = (t.timeIntervalSinceReferenceDate / crossing + phase).truncatingRemainder(dividingBy: 1)
            let along = -radius + 2 * radius * p
            let rad = heading * .pi / 180
            // Unit vectors north-east: along the heading, and across it.
            let dirN = cos(rad), dirE = sin(rad)
            let northKm = along * dirN + across * -dirE
            let eastKm = along * dirE + across * dirN
            out.append(NearbyFlight(
                id: "FAKE\(i)-\(cell)", ident: "\(airline.code)\(number)", operator: airline.operatorCode,
                type: airline.type, latitude: latitude + northKm / kmPerDegree,
                longitude: longitude + eastKm / (kmPerDegree * cosLat), altitudeFeet: altitude,
                groundspeedKnots: Int(knots), heading: heading, origin: String(from.dropFirst()),
                destination: String(to.dropFirst())))
        }
        return out
    }
}
