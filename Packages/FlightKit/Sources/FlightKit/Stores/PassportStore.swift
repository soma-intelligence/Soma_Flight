import Foundation
import Observation

@MainActor @Observable
public final class PassportStore {
    /// nil = all time.
    public var year: Int?
    public private(set) var error: APIError?
    private var all: [PastFlight] = []

    private let history: any HistoryService

    public init(history: any HistoryService) { self.history = history }

    /// Flights in the selected year (by local departure date), newest first.
    public var flights: [PastFlight] {
        all.filter { year == nil || $0.localYear == year }.sorted { $0.date > $1.date }
    }
    public var stats: PassportStats { PassportStats.compute(all, year: year) }
    /// Years with at least one flight, newest first.
    public var years: [Int] { Array(Set(all.map(\.localYear))).sorted(by: >) }

    public func load() async {
        do {
            all = try await history.pastFlights()
            error = nil
        } catch { self.error = error }
    }
}
