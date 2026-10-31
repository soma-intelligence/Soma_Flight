import Foundation
import Supabase

/// The arrival forecast and the inbound chain from `flight-insights`, which pays AeroAPI under the
/// backend's daily spend cap and caches each answer (12 hours per flight number, 10 minutes per flight).
/// The `decode…` functions are the exact path the answers take, and the contract tests run the backend's
/// example files through them.
public final class SupabaseInsightsService: InsightsService {
    private let backend: SupabaseBackend

    public init(backend: SupabaseBackend) { self.backend = backend }

    /// Reads `InsightsEnabled` from Info.plist (`INSIGHTS_ENABLED` in the xcconfigs: YES in Debug, NO in
    /// Release until the owner approves the cost). Anything but a yes, a missing key included, is off.
    public static func isEnabled(in bundle: Bundle = .main) -> Bool {
        isEnabled(raw: bundle.object(forInfoDictionaryKey: "InsightsEnabled"))
    }

    /// YES, true or 1 (any case, as a string, a boolean or a number) is on; everything else, an
    /// unexpanded `$(INSIGHTS_ENABLED)` included, is off.
    static func isEnabled(raw: Any?) -> Bool {
        switch raw {
        case let b as Bool: b
        case let s as String: ["yes", "true", "1"].contains(s.trimmingCharacters(in: .whitespaces).lowercased())
        case let n as NSNumber: n.boolValue
        default: false
        }
    }

    // MARK: Decoding (shared with the contract tests)

    /// `mode=arrival_forecast`: `forecast` is null when no flight of the number finished lately.
    public struct ForecastAnswer: Decodable, Sendable {
        public var ident: String
        public var fetchedAt: Date
        public var stale: Bool
        public var forecast: Body?

        public struct Body: Decodable, Sendable {
            var ident: String
            var days: Int
            var observed: Int
            var latePercent: Int
            var averageLateMinutes: Int
            var percents: Percents
        }

        /// One field per bucket, so a missing bucket fails the decode instead of reading as 0.
        struct Percents: Decodable, Sendable {
            var early, onTime, late15, late30, late45, canceled, diverted: Int

            var byBucket: [ForecastBucket: Int] {
                [.early: early, .onTime: onTime, .late15: late15, .late30: late30, .late45: late45,
                 .canceled: canceled, .diverted: diverted]
            }
        }
    }

    /// `mode=inbound`: the aircraft's earlier legs, newest first.
    public struct InboundAnswer: Decodable, Sendable {
        public var flightId: UUID
        public var fetchedAt: Date
        public var stale: Bool
        public var legs: [Leg]

        public struct Leg: Decodable, Sendable {
            var id: String
            var ident: String
            var originIata: String
            var destinationIata: String
            var scheduledOut: Date
            var scheduledIn: Date
            var status: FlightStatus
            var delayMinutes: Int
        }
    }

    public static func decodeForecastAnswer(_ data: Data) throws -> ForecastAnswer {
        try FlightJSON.decoder.decode(ForecastAnswer.self, from: data)
    }

    public static func decodeInboundAnswer(_ data: Data) throws -> InboundAnswer {
        try FlightJSON.decoder.decode(InboundAnswer.self, from: data)
    }

    /// The app's forecast, or nil when the backend has none.
    public static func decodeForecast(_ data: Data) throws -> ArrivalForecast? {
        try decodeForecastAnswer(data).forecast.map {
            ArrivalForecast(ident: $0.ident, days: $0.days, observed: $0.observed, latePercent: $0.latePercent,
                            averageLateMinutes: $0.averageLateMinutes, percents: $0.percents.byBucket)
        }
    }

    public static func decodeInbound(_ data: Data) throws -> [InboundLeg] {
        try decodeInboundAnswer(data).legs.map {
            InboundLeg(id: $0.id, ident: $0.ident, originIata: $0.originIata, destinationIata: $0.destinationIata,
                       scheduledOut: $0.scheduledOut, scheduledIn: $0.scheduledIn, status: $0.status,
                       delayMinutes: $0.delayMinutes)
        }
    }

    // MARK: InsightsService

    public func arrivalForecast(ident: String) async throws(APIError) -> ArrivalForecast? {
        try await backend.call("flight-insights", method: .get,
                               query: [URLQueryItem(name: "mode", value: "arrival_forecast"),
                                       URLQueryItem(name: "ident", value: ident)],
                               decode: Self.decodeForecast)
    }

    public func inbound(_ id: Flight.ID) async throws(APIError) -> [InboundLeg] {
        try await backend.call("flight-insights", method: .get,
                               query: [URLQueryItem(name: "mode", value: "inbound"),
                                       URLQueryItem(name: "flight_id", value: id.uuidString.lowercased())],
                               decode: Self.decodeInbound)
    }
}
