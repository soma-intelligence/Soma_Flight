import Foundation
import Observation

@MainActor @Observable
public final class SearchStore {
    public var text = ""
    public var date = Date.now
    public private(set) var results: [Flight] = []
    public private(set) var error: APIError?
    public private(set) var isSearching = false

    private let flights: any FlightService

    public init(flights: any FlightService) { self.flights = flights }

    /// On any error `text` stays as typed.
    public func search() async {
        guard let query = FlightQuery.parse(text, date: date) else {
            results = []; error = .notFound; return
        }
        isSearching = true
        defer { isSearching = false }
        do {
            results = try await flights.lookup(query)
            error = nil
        } catch {
            self.error = error
            if error == .notFound { results = [] }
        }
    }

    /// True when the flight is now followed. Plan and rate limits set `error` and add nothing.
    public func follow(_ flight: Flight) async -> Bool {
        do {
            try await flights.follow(flight.id, notify: true)
            error = nil
            return true
        } catch {
            self.error = error
            return false
        }
    }
}
