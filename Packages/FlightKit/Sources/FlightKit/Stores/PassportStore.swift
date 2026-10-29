import Foundation
import Observation

@MainActor @Observable
public final class PassportStore {
    /// nil = all time.
    public var year: Int?
    public private(set) var error: APIError?
    public private(set) var isOffline = false
    /// Save time of the cached history while offline, nil when the data is live.
    public private(set) var lastUpdated: Date?
    private var all: [PastFlight] = []

    private let history: any HistoryService
    private let cache: (any PastFlightCache)?

    public init(history: any HistoryService, cache: (any PastFlightCache)? = nil) {
        self.history = history; self.cache = cache
    }

    /// Flights in the selected year (by local departure date), newest first.
    public var flights: [PastFlight] {
        all.filter { year == nil || $0.localYear == year }.sorted { $0.date > $1.date }
    }
    public var stats: PassportStats { PassportStats.compute(all, year: year) }
    /// Years with at least one flight, newest first.
    public var years: [Int] { Array(Set(all.map(\.localYear))).sorted(by: >) }

    public func load() async {
        if all.isEmpty, let cache {
            let cached = await cache.past()
            if all.isEmpty { all = cached }
        }
        do {
            all = try await history.pastFlights()
            error = nil; isOffline = false; lastUpdated = nil
            await cache?.save(past: all)
        } catch {
            self.error = error
            isOffline = error == .offline
            if isOffline, let cache { lastUpdated = await cache.pastSavedAt() }
        }
    }
}
