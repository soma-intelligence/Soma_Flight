import Foundation
import Observation

/// Offline copy of the followed list. `CacheStore` is the SwiftData implementation.
public protocol FlightListCache: Sendable {
    func save(flights: [Flight]) async
    func flights() async -> [Flight]
    /// When the list was last saved; nil when unknown.
    func flightsSavedAt() async -> Date?
}

public extension FlightListCache {
    func flightsSavedAt() async -> Date? { nil }
}

/// Offline copy of the Passport history.
public protocol PastFlightCache: Sendable {
    func save(past: [PastFlight]) async
    func past() async -> [PastFlight]
    func pastSavedAt() async -> Date?
}

@MainActor @Observable
public final class MyFlightsStore {
    public private(set) var error: APIError?
    public private(set) var lastUpdated: Date?
    public private(set) var isOffline = false
    /// True once a `load()` has finished, whatever its outcome. Screens show a spinner, not the empty
    /// invitation, until then; an empty list with `error` set is a failure, not an empty account.
    public private(set) var hasLoaded = false
    /// When the list was last confirmed: now after a successful load or pushed update, the cache's save
    /// time while offline. Unlike `lastUpdated` (newest flight change) it measures how fresh the whole list is.
    public internal(set) var fetchedAt: Date?
    /// True while a `load()` is running (the latest one, when calls overlap). Lets a retry after a failed
    /// first load show progress instead of a frozen banner.
    public private(set) var isLoading = false
    /// True while the list is kept current by a healthy realtime subscription: the last load worked, the
    /// device is online and the update loop is running. A quiet stream then means "nothing changed", not
    /// "nothing heard", so screens skip the age badge. Offline, after a failed refresh, before the loop
    /// starts and after it ends this is false and `fetchedAt` against the TTL decides.
    public private(set) var isLiveSynced = false
    private var all: [Flight.ID: Flight] = [:]
    @ObservationIgnored private var loadGeneration = 0
    @ObservationIgnored private var unfollowedDuringLoad: Set<Flight.ID> = []

    /// Called with the whole list after each change the store trusts: a successful load, a pushed update,
    /// an unfollow. Not after a failed load, so an offline launch never ends the Live Activity.
    @ObservationIgnored public var onListChange: (@MainActor ([Flight]) -> Void)?

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
    /// Everything else (scheduled, canceled, diverted, landed) by scheduled out. My Flights leaves out the
    /// ones that are over (`LandedFlights.isOver`): Passport shows those.
    public var upcoming: [Flight] { all.values.filter { !Self.isLive($0) }.sorted(by: Self.byOut) }
    /// Every followed flight, over or not, in no order: what Passport reads its just landed flights from.
    public var flights: [Flight] { Array(all.values) }

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
        isLoading = true
        defer { if gen == loadGeneration { isLoading = false } }
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
            fetchedAt = Date.now
            error = nil; isOffline = false; hasLoaded = true
            isLiveSynced = updatesTask != nil
            if updatesTask != nil, Set(all.keys) != subscribed { subscribe() }
            onListChange?(Array(merged.values))
            await cache?.save(flights: Array(merged.values))
        } catch {
            guard gen == loadGeneration else { return }
            self.error = error
            isOffline = error == .offline
            hasLoaded = true
            isLiveSynced = false
            if isOffline, all.isEmpty, let cache {
                let cached = await cache.flights()
                let savedAt = await cache.flightsSavedAt()
                guard gen == loadGeneration, all.isEmpty else { return }
                all = Dictionary(cached.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
                lastUpdated = savedAt ?? cached.map(\.updatedAt).max()
                fetchedAt = savedAt
            }
        }
    }

    /// Idempotent: a running update loop is kept.
    public func startUpdates() {
        guard updatesTask == nil else { return }
        subscribe()
        isLiveSynced = hasLoaded && error == nil && !isOffline
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
            // The stream ended (cancelled by a re-subscribe leaves a newer task in place).
            guard let self, !Task.isCancelled else { return }
            self.updatesTask = nil
            self.isLiveSynced = false
        }
    }

    private func apply(_ f: Flight) {
        guard let cur = all[f.id], f.updatedAt >= cur.updatedAt else { return }
        all[f.id] = f
        lastUpdated = max(lastUpdated ?? f.updatedAt, f.updatedAt)
        fetchedAt = Date.now
        onListChange?(Array(all.values))
    }

    public func unfollow(_ flight: Flight) async {
        do {
            try await service.unfollow(flight.id)
            all[flight.id] = nil
            unfollowedDuringLoad.insert(flight.id)
            error = nil
            onListChange?(Array(all.values))
        } catch { self.error = error }
    }
}
