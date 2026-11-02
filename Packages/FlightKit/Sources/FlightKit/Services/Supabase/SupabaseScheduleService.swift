import FlightImportKit
import Foundation
import Supabase

/// Airline schedules for a day from `flight-schedules`, which reads AeroAPI's schedules under the backend's
/// daily spend cap. `decode` is the exact path the answers take, and the contract tests run the backend's
/// example file through it.
public final class SupabaseScheduleService: ScheduleService {
    private let backend: SupabaseBackend

    public init(backend: SupabaseBackend) { self.backend = backend }

    /// Reads `SchedulesEnabled` from Info.plist (`SCHEDULES_ENABLED` in the xcconfigs: NO in both until
    /// `flight-schedules` is deployed), the same way as `SupabaseInsightsService.isEnabled`.
    public static func isEnabled(in bundle: Bundle = .main) -> Bool {
        isEnabled(raw: bundle.object(forInfoDictionaryKey: "SchedulesEnabled"))
    }

    static func isEnabled(raw: Any?) -> Bool { SupabaseInsightsService.isEnabled(raw: raw) }

    /// The function's answer as it travels.
    struct Answer: Decodable, Sendable {
        var date: String
        var fetchedAt: Date
        var stale: Bool
        var truncated: Bool?
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

    static func decode(_ data: Data) throws -> [ScheduledFlight] { try decodeDay(data).flights }

    /// The answer with its `truncated` flag (absent reads as false).
    static func decodeDay(_ data: Data) throws -> ScheduleDay {
        let answer = try FlightJSON.decoder.decode(Answer.self, from: data)
        return ScheduleDay(flights: answer.flights.map {
            ScheduledFlight(ident: $0.ident, airline: $0.airline, origin: $0.origin, destination: $0.destination,
                            scheduledOut: $0.scheduledOut, scheduledIn: $0.scheduledIn, aircraftType: $0.aircraftType)
        }, truncated: answer.truncated ?? false)
    }

    /// The request body: only the fields the query sets, the day as "YYYY-MM-DD", the time as minutes.
    static func body(_ q: ScheduleQuery) -> Data {
        var json: [String: Any] = ["date": q.day.description]
        if let v = q.origin { json["origin"] = v }
        if let v = q.destination { json["destination"] = v }
        if let v = q.airline { json["airline"] = v }
        if let v = q.ident { json["ident"] = v }
        if let v = q.time { json["time"] = v }
        return (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
    }

    /// `flight-schedules` never answers not found itself (an unknown airport is a 400, no schedule is an
    /// empty list): a 404 is the function missing from the backend, so the schedules are unavailable.
    static func mapped(_ e: APIError) -> APIError { e == .notFound ? .providerUnavailable : e }

    public func schedules(_ q: ScheduleQuery) async throws(APIError) -> [ScheduledFlight] {
        try await scheduleDay(q).flights
    }

    public func scheduleDay(_ q: ScheduleQuery) async throws(APIError) -> ScheduleDay {
        do {
            return try await backend.call("flight-schedules", method: .post, body: Self.body(q), decode: Self.decodeDay)
        } catch {
            throw Self.mapped(error)
        }
    }
}
