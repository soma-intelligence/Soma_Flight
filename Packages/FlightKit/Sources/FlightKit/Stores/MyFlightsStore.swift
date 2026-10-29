import Foundation
import Observation

/// Offline copy of the followed list. Task 5 supplies the SwiftData implementation.
public protocol FlightListCache: Sendable {
    func save(flights: [Flight]) async
    func flights() async -> [Flight]
}

@MainActor @Observable
public final class MyFlightsStore {
    public private(set) var error: APIError?
    public private(set) var lastUpdated: Date?
    public private(set) var isOffline = false
    private var all: [Flight.ID: Flight] = [:]
    @ObservationIgnored private var loadGeneration = 0
    @ObservationIgnored private var unfollowedDuringLoad: Set<Flight.ID> = []

    private let service: any FlightService
    private let cache: (any FlightListCache)?
    @ObservationIgnored private var updatesTask: Task<Void, Never>?
    @ObservationIgnored private var subscribed: Set<Flight.ID> = []

    public init(flights: any FlightService, cache: (any FlightListCache)? = nil) {
        self.service = flights; self.cache = cache
    }

    deinit { updatesTask?.cancel() }

    /// Departed or en route, soonest departure first.
    public var live: [Flight] { all.values.filter { Self.isLive($0) }.sorted(by: Self.byOut) }
    /// Everything else (scheduled, canceled, diverted, landed) by scheduled out. Canceled stays until unfollowed.
    public var upcoming: [Flight] { all.values.filter { !Self.isLive($0) }.sorted(by: Self.byOut) }

    private static func isLive(_ f: Flight) -> Bool { f.status == .departed || f.status == .enRoute }
    private static func byOut(_ a: Flight, _ b: Flight) -> Bool {
        let x = a.scheduledOut ?? .distantFuture, y = b.scheduledOut ?? .distantFuture
        return x == y ? a.id.uuidString < b.id.uuidString : x < y
    }

    /// Latest call wins: a call superseded while awaiting drops its result.
    public func load() async {
        loadGeneration += 1
        let gen = loadGeneration
        unfollowedDuringLoad = []
        do {
            let list = try await service.followed()
            guard gen == loadGeneration else { return }
            var merged: [Flight.ID: Flight] = [:]
            for f in list where !unfollowedDuringLoad.contains(f.id) {
                // A flight pushed while the snapshot was in flight may be newer than it.
                if let cur = all[f.id], cur.updatedAt > f.updatedAt { merged[f.id] = cur } else { merged[f.id] = f }
            }
            all = merged
            lastUpdated = merged.values.map(\.updatedAt).max()
            error = nil; isOffline = false
            if updatesTask != nil, Set(all.keys) != subscribed { subscribe() }
            await cache?.save(flights: Array(merged.values))
        } catch {
            guard gen == loadGeneration else { return }
            self.error = error
            isOffline = error == .offline
            if isOffline, all.isEmpty, let cache {
                let cached = await cache.flights()
                guard gen == loadGeneration, all.isEmpty else { return }
                all = Dictionary(cached.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
                lastUpdated = cached.map(\.updatedAt).max()
            }
        }
    }

    /// Idempotent: a running update loop is kept.
    public func startUpdates() {
        guard updatesTask == nil else { return }
        subscribe()
    }

    private func subscribe() {
        updatesTask?.cancel()
        subscribed = Set(all.keys)
        let stream = service.updates(for: Array(subscribed))
        updatesTask = Task { [weak self] in
            for await f in stream {
                guard let self else { return }
                self.apply(f)
            }
        }
    }

    private func apply(_ f: Flight) {
        guard let cur = all[f.id], f.updatedAt >= cur.updatedAt else { return }
        all[f.id] = f
        lastUpdated = max(lastUpdated ?? f.updatedAt, f.updatedAt)
    }

    public func unfollow(_ flight: Flight) async {
        do {
            try await service.unfollow(flight.id)
            all[flight.id] = nil
            unfollowedDuringLoad.insert(flight.id)
            error = nil
        } catch { self.error = error }
    }
}
