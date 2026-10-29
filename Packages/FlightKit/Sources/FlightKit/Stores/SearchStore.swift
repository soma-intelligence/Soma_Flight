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
    @ObservationIgnored private var searchGeneration = 0

    public init(flights: any FlightService) { self.flights = flights }

    /// On any error `text` stays as typed. The latest call wins; a superseded call drops its result.
    public func search() async {
        searchGeneration += 1
        let gen = searchGeneration
        guard let query = FlightQuery.parse(text, date: date) else {
            results = []; error = .notFound; isSearching = false; return
        }
        isSearching = true
        do {
            let found = try await flights.lookup(query)
            guard gen == searchGeneration else { return }
            results = found
            error = nil
        } catch {
            guard gen == searchGeneration else { return }
            self.error = error
            if error == .notFound { results = [] }
        }
        isSearching = false
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
