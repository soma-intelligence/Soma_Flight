import Foundation
import Supabase

/// Flights in the air around a place from `nearby-flights`, which reads AeroAPI's flight search under the
/// backend's daily spend cap and caches each rounded area for 60 seconds. The function is off until the owner
/// sets `RADAR_ENABLED=true` and `AEROAPI_KEY`; until then it answers 503 `provider_unavailable`. `decode` is
/// the exact path the answers take, and the contract tests run an example answer through it.
public final class SupabaseNearbyFlightsService: NearbyFlightsService {
    private let backend: SupabaseBackend

    public init(backend: SupabaseBackend) { self.backend = backend }

    public var isAvailable: Bool { true }

    /// Reads `RadarEnabled` from Info.plist (`RADAR_ENABLED` in the xcconfigs: NO everywhere until the owner
    /// approves the cost). Anything but a yes, a missing key included, is off.
    public static func isEnabled(in bundle: Bundle = .main) -> Bool {
        isEnabled(raw: bundle.object(forInfoDictionaryKey: "RadarEnabled"))
    }

    /// The same reading as `InsightsEnabled`: YES, true or 1 is on; everything else is off.
    static func isEnabled(raw: Any?) -> Bool { SupabaseInsightsService.isEnabled(raw: raw) }

    /// The function's answer as it travels.
    public struct Answer: Decodable, Sendable {
        public var fetchedAt: Date
        public var stale: Bool
        public var truncated: Bool
        public var flights: [Row]

        public struct Row: Decodable, Sendable {
            var id: String
            var ident: String
            var `operator`: String?
            var type: String?
            var lat: Double
            var lon: Double
            var altitude: Int?
            var groundspeed: Int?
            var heading: Double?
            var origin: String?
            var destination: String?
        }
    }

    public static func decodeAnswer(_ data: Data) throws -> Answer {
        try FlightJSON.decoder.decode(Answer.self, from: data)
    }

    public static func decode(_ data: Data) throws -> NearbyFlightsResult {
        let a = try decodeAnswer(data)
        return NearbyFlightsResult(
            flights: a.flights.map {
                NearbyFlight(id: $0.id, ident: $0.ident, operator: $0.operator, type: $0.type, latitude: $0.lat,
                             longitude: $0.lon, altitudeFeet: $0.altitude, groundspeedKnots: $0.groundspeed,
                             heading: $0.heading, origin: $0.origin, destination: $0.destination)
            },
            fetchedAt: a.fetchedAt, stale: a.stale, truncated: a.truncated)
    }

    /// The place goes out rounded to two decimals (about a kilometre): the backend snaps it to a quarter degree anyway.
    public func nearby(latitude: Double, longitude: Double, radiusKm: Double) async throws(APIError) -> NearbyFlightsResult {
        try await backend.call("nearby-flights", method: .get,
                               query: [URLQueryItem(name: "lat", value: String(format: "%.2f", latitude)),
                                       URLQueryItem(name: "lon", value: String(format: "%.2f", longitude)),
                                       URLQueryItem(name: "radius_km", value: String(Int(radiusKm.rounded())))],
                               decode: Self.decode)
    }
}
