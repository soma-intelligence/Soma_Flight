import FlightImportKit
import Foundation
import Supabase

/// Airline schedules for a day from `flight-schedules`, which reads AeroAPI's schedules under the backend's
/// daily spend cap. `decode` is the exact path the answers take, and the contract tests run the backend's
/// example file through it.
public final class SupabaseScheduleService: ScheduleService {
    private let backend: SupabaseBackend

    public init(backend: SupabaseBackend) { self.backend = backend }

    /// The function's answer as it travels.
    struct Answer: Decodable, Sendable {
        var date: String
        var fetchedAt: Date
        var stale: Bool
        var flights: [Row]

        struct Row: Decodable, Sendable {
            var ident: String
            var airline: String?
            var origin: String
            var destination: String
            var scheduledOut: Date
            var scheduledIn: Date?
            var aircraftType: String?
        }
    }

    static func decode(_ data: Data) throws -> [ScheduledFlight] {
        try FlightJSON.decoder.decode(Answer.self, from: data).flights.map {
            ScheduledFlight(ident: $0.ident, airline: $0.airline, origin: $0.origin, destination: $0.destination,
                            scheduledOut: $0.scheduledOut, scheduledIn: $0.scheduledIn, aircraftType: $0.aircraftType)
        }
    }

    /// The request body: only the fields the query sets, and the day as "YYYY-MM-DD".
    static func body(_ q: ScheduleQuery) -> Data {
        var json: [String: String] = ["date": q.day.description]
        if let v = q.origin { json["origin"] = v }
        if let v = q.destination { json["destination"] = v }
        if let v = q.airline { json["airline"] = v }
        if let v = q.ident { json["ident"] = v }
        return (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
    }

    public func schedules(_ q: ScheduleQuery) async throws(APIError) -> [ScheduledFlight] {
        try await backend.call("flight-schedules", method: .post, body: Self.body(q), decode: Self.decode)
    }
}
