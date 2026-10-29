import Foundation
import Observation

@MainActor @Observable
public final class SearchStore {
    public var text = ""
    public var date = Date.now
    public private(set) var results: [Flight] = []
    public private(set) var error: APIError?
    public private(set) var isSearching = false
    /// Queries that found something, newest first, at most `recentLimit`.
    public private(set) var recent: [String] = []

    public static let recentLimit = 6
    nonisolated static let recentKey = "recentSearches"

    private let flights: any FlightService
    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private var searchGeneration = 0

    /// - Parameter defaults: where recent searches persist; nil keeps them in memory only.
    public init(flights: any FlightService, defaults: UserDefaults? = nil) {
        self.flights = flights
        self.defaults = defaults
        recent = defaults?.stringArray(forKey: Self.recentKey) ?? []
    }

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
            remember(text)
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

    public func clearRecent() {
        recent = []
        defaults?.removeObject(forKey: Self.recentKey)
    }

    /// Replaces the recent list without persisting it (previews and snapshots).
    func seedRecent(_ queries: [String]) {
        recent = Array(queries.prefix(Self.recentLimit))
    }

    /// Normalised (trimmed, upper case), moved to the front, deduplicated, capped.
    private func remember(_ raw: String) {
        let q = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !q.isEmpty else { return }
        recent = Array(([q] + recent.filter { $0 != q }).prefix(Self.recentLimit))
        defaults?.set(recent, forKey: Self.recentKey)
    }
}
