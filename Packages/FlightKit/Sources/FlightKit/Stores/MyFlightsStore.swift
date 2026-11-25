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
    /// The list on show is the device's saved copy, read before the network answered (E1) or after it
    /// failed. False once a load succeeds.
    public private(set) var isShowingCache = false
    /// Why the last action (an unfollow) failed, kept apart from the load's `error` so its Retry runs the
    /// action again (E6). Cleared by `clearActionError()` or the next successful action.
    public private(set) var actionError: ActionFailure?
    /// Flights whose unfollow is on its way to the server: the swipe and the menu do nothing for them (E15).
    public private(set) var unfollowing: Set<Flight.ID> = []
    /// Flights the user removed that wait out their Undo window (`HomeModel.unfollowWithUndo`): left out of
    /// every list, still followed on the server.
    public private(set) var hidden: Set<Flight.ID> = []
    /// Asked when a call meets `.unauthorized`: true when the session was renewed and the call is worth
    /// one more try (E3). The home points it at `SessionStore.recoverSession()`.
    @ObservationIgnored public var onUnauthorized: (@MainActor () async -> Bool)?
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
    public var live: [Flight] { shown.filter { Self.isLive($0) }.sorted(by: Self.byOut) }
    /// Everything else (scheduled, canceled, diverted, landed) by scheduled out. My Flights leaves out the
    /// ones that are over (`LandedFlights.isOver`): Passport shows those.
    public var upcoming: [Flight] { shown.filter { !Self.isLive($0) }.sorted(by: Self.byOut) }
    /// Every followed flight, over or not, in no order: what Passport reads its just landed flights from.
    public var flights: [Flight] { shown }

    /// Every followed flight but the ones waiting out their Undo window.
    private var shown: [Flight] { hidden.isEmpty ? Array(all.values) : all.values.filter { !hidden.contains($0.id) } }

    /// True when the list has a flight with this id (hidden ones included).
    public func contains(_ id: Flight.ID) -> Bool { all[id] != nil }

    /// The followed flight with this id, hidden ones included.
    public func flight(_ id: Flight.ID) -> Flight? { all[id] }

    private static func isLive(_ f: Flight) -> Bool { f.status == .departed || f.status == .enRoute }
    private static func byOut(_ a: Flight, _ b: Flight) -> Bool {
        let x = a.scheduledOut ?? .distantFuture, y = b.scheduledOut ?? .distantFuture
        return x == y ? a.id.uuidString < b.id.uuidString : x < y
    }

    /// Latest call wins: a call superseded while awaiting drops its result. The first load shows the
    /// device's saved list at once, before the network answers (E1); any failure falls back on it while
    /// nothing else is on show. A `.unauthorized` answer asks `onUnauthorized` once and retries when the
    /// session was renewed (E3).
    public func load() async {
        await load(retryingAuth: true)
    }

    private func load(retryingAuth: Bool) async {
        loadGeneration += 1
        let gen = loadGeneration
        unfollowedDuringLoad = []
        isLoading = true
        defer { if gen == loadGeneration { isLoading = false } }
        if !hasLoaded, all.isEmpty { await showCache(gen: gen) }
        do {
            let list = try await service.followed()
            guard gen == loadGeneration else { return }
            var merged: [Flight.ID: Flight] = [:]
            for f in list where !unfollowedDuringLoad.contains(f.id) {
                // A flight pushed while the snapshot was in flight may be newer than it.
                if let cur = all[f.id], cur.updatedAt > f.updatedAt { merged[f.id] = cur } else { merged[f.id] = f }
            }
            all = merged
            hidden.formIntersection(merged.keys)
            lastUpdated = merged.values.map(\.updatedAt).max()
            fetchedAt = Date.now
            error = nil; isOffline = false; hasLoaded = true; isShowingCache = false
            isLiveSynced = updatesTask != nil
            if updatesTask != nil, Set(all.keys) != subscribed { subscribe() }
            onListChange?(Array(merged.values))
            await cache?.save(flights: Array(merged.values))
        } catch {
            guard gen == loadGeneration else { return }
            if error == .unauthorized, retryingAuth, let onUnauthorized, await onUnauthorized() {
                guard gen == loadGeneration else { return }
                await load(retryingAuth: false)
                return
            }
            self.error = error
            isOffline = error == .offline
            hasLoaded = true
            isLiveSynced = false
            if all.isEmpty { await showCache(gen: gen) }
        }
    }

    /// Fills an empty list from the device's saved copy. Never replaces flights already on show.
    private func showCache(gen: Int) async {
        guard let cache else { return }
        let cached = await cache.flights()
        let savedAt = await cache.flightsSavedAt()
        // A list saved empty still counts: the account is known to follow nothing, so no loader.
        guard gen == loadGeneration, all.isEmpty, !cached.isEmpty || savedAt != nil else { return }
        all = Dictionary(cached.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
        lastUpdated = savedAt ?? cached.map(\.updatedAt).max()
        fetchedAt = savedAt
        isShowingCache = true
    }

    /// The connection came back or the app returned to the foreground (E2): reloads when the list is not
    /// known to be current (offline, a failed load, no healthy live stream, or older than `staleAfter`).
    /// A healthy live list is left alone.
    public func refreshIfNeeded(staleAfter: TimeInterval = 60, now: Date = .now) async {
        guard !isLoading else { return }
        let stale = fetchedAt.map { now.timeIntervalSince($0) > staleAfter } ?? true
        guard isOffline || error != nil || isShowingCache || !hasLoaded || (!isLiveSynced && stale) else { return }
        await load()
        if updatesTask == nil, hasLoaded, error == nil { startUpdates() }
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
        // A pushed update came through the network: whatever the last load met, the device is online (E2).
        if isOffline || error == .offline { isOffline = false; error = nil }
        onListChange?(Array(all.values))
    }

    /// Unfollows on the server, then drops the flight. A second call for a flight already on its way does
    /// nothing (E15). A failure sets `actionError` (with a retry), not the load's `error` (E6), and returns
    /// the error; nil on success.
    @discardableResult
    public func unfollow(_ flight: Flight) async -> APIError? {
        await unfollow(flight, retryingAuth: true)
    }

    private func unfollow(_ flight: Flight, retryingAuth: Bool) async -> APIError? {
        guard !unfollowing.contains(flight.id) else { return nil }
        unfollowing.insert(flight.id)
        do {
            try await service.unfollow(flight.id)
            unfollowing.remove(flight.id)
            all[flight.id] = nil
            hidden.remove(flight.id)
            unfollowedDuringLoad.insert(flight.id)
            if actionError?.kind == .unfollow { actionError = nil }
            onListChange?(Array(all.values))
            return nil
        } catch {
            unfollowing.remove(flight.id)
            if error == .unauthorized, retryingAuth, let onUnauthorized, await onUnauthorized() {
                return await unfollow(flight, retryingAuth: false)
            }
            actionError = ActionFailure(.unfollow, error) { [weak self] in _ = await self?.unfollow(flight) }
            return error
        }
    }

    /// Takes a flight out of the lists while its Undo window runs (`HomeModel.unfollowWithUndo`).
    public func hide(_ id: Flight.ID) { if all[id] != nil { hidden.insert(id) } }

    /// Puts a hidden flight back (Undo, or the server refused the unfollow).
    public func unhide(_ id: Flight.ID) { hidden.remove(id) }

    public func clearActionError() { actionError = nil }

    #if DEBUG
    /// Tests: a list without a load.
    func seed(_ flights: [Flight]) {
        all = Dictionary(flights.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
        hasLoaded = true
    }
    #endif
}
