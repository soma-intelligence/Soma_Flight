import Foundation
import Supabase

/// Direct flights on a route from `alternate-flights`, which reads AeroAPI's schedules under the backend's
/// daily spend cap and caches each route and hour for 30 minutes. `decode` is the exact path the answers
/// take, and the contract tests run the backend's example file through it.
public final class SupabaseAlternateFlightsService: AlternateFlightsService {
    private let backend: SupabaseBackend

    public init(backend: SupabaseBackend) { self.backend = backend }

    /// The function's answer as it travels.
    public struct Answer: Decodable, Sendable {
        public var origin: String
        public var destination: String
        public var after: Date
        public var fetchedAt: Date
        public var stale: Bool
        public var flights: [Row]

        public struct Row: Decodable, Sendable {
            var id: String
            var ident: String
            var `operator`: String?
            var originIata: String
            var destinationIata: String
            var scheduledOut: Date
            var scheduledIn: Date
            var estimatedOut: Date?
            var estimatedIn: Date?
            var status: FlightStatus
            var aircraftType: String?
        }
    }

    public static func decodeAnswer(_ data: Data) throws -> Answer {
        try FlightJSON.decoder.decode(Answer.self, from: data)
    }

    public static func decode(_ data: Data) throws -> [AlternateFlight] {
        try decodeAnswer(data).flights.map {
            AlternateFlight(id: $0.id, ident: $0.ident, operator: $0.operator, originIata: $0.originIata,
                            destinationIata: $0.destinationIata, scheduledOut: $0.scheduledOut,
                            scheduledIn: $0.scheduledIn, estimatedOut: $0.estimatedOut, estimatedIn: $0.estimatedIn,
                            status: $0.status, aircraftType: $0.aircraftType)
        }
    }

    public func alternates(origin: String, destination: String, after: Date) async throws(APIError) -> [AlternateFlight] {
        try await backend.call("alternate-flights", method: .get,
                               query: [URLQueryItem(name: "origin", value: origin),
                                       URLQueryItem(name: "destination", value: destination),
                                       URLQueryItem(name: "after", value: Self.iso(after))],
                               decode: Self.decode)
    }

    /// "2026-11-03T15:30:00Z": whole seconds, UTC.
    static func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }
}
