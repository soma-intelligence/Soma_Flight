import Foundation

public enum ExportFormat: Sendable, Hashable {
    case json, csv
}

public protocol HistoryService: Sendable {
    func pastFlights() async throws(APIError) -> [PastFlight]
    func export(_ format: ExportFormat) async throws(APIError) -> Data
    /// Stores a flight the traveller added (`source` manual or import) and returns it as stored, with the
    /// distance, countries and origin zone the server filled in.
    func add(_ flight: PastFlight) async throws(APIError) -> PastFlight
    /// Stores many flights at once (an import), in batches; returns them as stored. A failed batch throws,
    /// and the batches before it stay stored.
    func addAll(_ flights: [PastFlight]) async throws(APIError) -> [PastFlight]
    /// Replaces a manual or imported flight; `.notFound` when it is gone, archived or someone else's.
    func update(_ flight: PastFlight) async throws(APIError) -> PastFlight
    /// Deletes a manual or imported flight; `.notFound` when it is gone, archived or someone else's.
    func delete(_ id: PastFlight.ID) async throws(APIError)
}

/// A read-only history (test doubles, previews) refuses every write as the server would when it cannot
/// take one. The Supabase service, the fake and the cache implement the writes.
public extension HistoryService {
    func add(_ flight: PastFlight) async throws(APIError) -> PastFlight { throw .providerUnavailable }
    func addAll(_ flights: [PastFlight]) async throws(APIError) -> [PastFlight] { throw .providerUnavailable }
    func update(_ flight: PastFlight) async throws(APIError) -> PastFlight { throw .providerUnavailable }
    func delete(_ id: PastFlight.ID) async throws(APIError) { throw .providerUnavailable }
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

    // Writes go through and drop the kept copy, which no longer matches.

    public func add(_ flight: PastFlight) async throws(APIError) -> PastFlight {
        defer { kept = nil }
        return try await base.add(flight)
    }

    public func addAll(_ flights: [PastFlight]) async throws(APIError) -> [PastFlight] {
        defer { kept = nil }
        return try await base.addAll(flights)
    }

    public func update(_ flight: PastFlight) async throws(APIError) -> PastFlight {
        defer { kept = nil }
        return try await base.update(flight)
    }

    public func delete(_ id: PastFlight.ID) async throws(APIError) {
        defer { kept = nil }
        try await base.delete(id)
    }
}
