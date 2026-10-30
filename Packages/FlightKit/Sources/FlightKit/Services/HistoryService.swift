import Foundation

public enum ExportFormat: Sendable, Hashable {
    case json, csv
}

public protocol HistoryService: Sendable {
    func pastFlights() async throws(APIError) -> [PastFlight]
    func export(_ format: ExportFormat) async throws(APIError) -> Data
}

/// Keeps the past flights for `ttl` so every flight sheet that opens does not fetch the whole history
/// again (its history card only needs a recent copy). A failed fetch is not kept.
public actor CachedHistoryService: HistoryService {
    private let base: any HistoryService
    private let ttl: Duration
    private let now: @Sendable () -> Date
    private var kept: (at: Date, flights: [PastFlight])?

    public init(_ base: any HistoryService, ttl: Duration = .seconds(600), now: @escaping @Sendable () -> Date = { .now }) {
        self.base = base; self.ttl = ttl; self.now = now
    }

    public func pastFlights() async throws(APIError) -> [PastFlight] {
        let t = now()
        if let kept, t.timeIntervalSince(kept.at) < Double(ttl.components.seconds) { return kept.flights }
        let fresh = try await base.pastFlights()
        kept = (t, fresh)
        return fresh
    }

    public func export(_ format: ExportFormat) async throws(APIError) -> Data { try await base.export(format) }
}
