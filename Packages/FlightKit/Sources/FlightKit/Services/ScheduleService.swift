import FlightImportKit
import Foundation

/// One airline schedule question: the flights of a day on a route, from an airport, to an airport or under a
/// flight number. At least one of `origin`, `destination` and `ident` is set; the backend refuses a query with
/// none. Airports are ICAO codes and `airline` is the ICAO airline code ("UAL"), as the backend wants them.
public struct ScheduleQuery: Sendable, Hashable {
    public var origin: String?
    public var destination: String?
    public var airline: String?
    /// The IATA flight designator ("UA1958").
    public var ident: String?
    /// The day, as the departure airport's calendar reads it.
    public var day: LocalDay
    /// Minutes after local midnight: the backend reads the hours around it only, so a busy airport's
    /// evening is not cut off past its page limit.
    public var time: Int?

    public init(origin: String? = nil, destination: String? = nil, airline: String? = nil, ident: String? = nil,
                day: LocalDay, time: Int? = nil) {
        self.origin = origin; self.destination = destination; self.airline = airline; self.ident = ident
        self.day = day; self.time = time
    }
}

/// One schedules answer: its flights, and whether the backend stopped at its page limit with more left.
public struct ScheduleDay: Sendable, Hashable {
    public var flights: [ScheduledFlight]
    public var truncated: Bool

    public init(flights: [ScheduledFlight], truncated: Bool = false) {
        self.flights = flights; self.truncated = truncated
    }
}

/// A flight on an airline's schedule, before anyone follows it.
public struct ScheduledFlight: Sendable, Hashable, Identifiable {
    public var ident: String
    public var airline: String?
    public var origin: String
    public var destination: String
    public var scheduledOut: Date
    public var scheduledIn: Date?
    public var aircraftType: String?

    public var id: String { "\(ident) \(scheduledOut.timeIntervalSince1970)" }

    public init(ident: String, airline: String? = nil, origin: String, destination: String, scheduledOut: Date,
                scheduledIn: Date? = nil, aircraftType: String? = nil) {
        self.ident = ident; self.airline = airline; self.origin = origin; self.destination = destination
        self.scheduledOut = scheduledOut; self.scheduledIn = scheduledIn; self.aircraftType = aircraftType
    }
}

/// Airline schedules for one day, which is how the search finds flights days or weeks ahead. They come from
/// AeroAPI's schedules, which cost money per call: live builds use `SupabaseScheduleService` (edge function
/// `flight-schedules`) when Info.plist turns them on (`SCHEDULES_ENABLED`), else `FakeScheduleService` in
/// debug builds and `UnavailableScheduleService` (no calls) in release; screenshot runs (`-useFakes`) use
/// `FakeScheduleService`.
public protocol ScheduleService: Sendable {
    /// The flights the schedules list for `q`, by departure. Empty when they list none. One `origin` or
    /// `destination` per call: the caller fans out over a city's airports.
    func schedules(_ q: ScheduleQuery) async throws(APIError) -> [ScheduledFlight]
    /// `schedules`, and whether the answer was cut at the backend's page limit.
    func scheduleDay(_ q: ScheduleQuery) async throws(APIError) -> ScheduleDay
}

extension ScheduleService {
    /// A service that never cuts its answers.
    public func scheduleDay(_ q: ScheduleQuery) async throws(APIError) -> ScheduleDay {
        ScheduleDay(flights: try await schedules(q))
    }
}

/// Live builds with the paid sections off: the search cannot look ahead, and no network call is made.
public struct UnavailableScheduleService: ScheduleService {
    public init() {}
    public func schedules(_ q: ScheduleQuery) async throws(APIError) -> [ScheduledFlight] {
        throw .providerUnavailable
    }
}

extension AppEnvironment {
    /// The same environment with `service` for the search's schedule lookups.
    func withSchedules(_ service: any ScheduleService) -> AppEnvironment {
        var env = self
        env.schedules = service
        return env
    }
}
