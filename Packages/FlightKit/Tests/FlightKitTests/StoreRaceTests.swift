import Testing
import Foundation
import Synchronization
@testable import FlightKit

private let wn4410 = UUID(uuidString: "20fae9c5-79ee-5ec3-a45a-015ed6c7fd9d")!

@MainActor private func eventually(_ cond: () -> Bool) async {
    for _ in 0..<300 where !cond() { try? await Task.sleep(for: .milliseconds(10)) }
}

/// Wraps the fake. The first `followed()` and first `lookup()` read their data at call time and
/// then stall, so they return a stale snapshot after later calls finished. Also counts live
/// update subscriptions and can script `flight(_:)` and `events(_:)`.
final class ScriptedFlights: FlightService, Sendable {
    let inner = FakeFlightService()
    private let calls = Mutex<(followed: Int, lookup: Int)>((0, 0))
    private let subs = Mutex<Int>(0)
    private let stall: Duration
    private let stallFollowedCall: Int
    private let flightOverride: Flight?
    private let eventsOverride: [FlightEvent]?
    private let eventsError: APIError?

    init(stall: Duration = .milliseconds(300), stallFollowedCall: Int = 1, flight: Flight? = nil, events: [FlightEvent]? = nil, eventsError: APIError? = nil) {
        self.stall = stall; self.stallFollowedCall = stallFollowedCall; flightOverride = flight; eventsOverride = events; self.eventsError = eventsError
    }

    var activeSubscriptions: Int { subs.withLock { $0 } }

    func lookup(_ query: FlightQuery) async throws(APIError) -> [Flight] {
        let n = calls.withLock { $0.lookup += 1; return $0.lookup }
        let r = try await inner.lookup(query)
        if n == 1 { try? await Task.sleep(for: stall) }
        return r
    }
    func followed() async throws(APIError) -> [Flight] {
        let n = calls.withLock { $0.followed += 1; return $0.followed }
        let r = try await inner.followed()
        if n == stallFollowedCall { try? await Task.sleep(for: stall) }
        return r
    }
    func follow(_ id: Flight.ID, notify: Bool) async throws(APIError) { try await inner.follow(id, notify: notify) }
    func unfollow(_ id: Flight.ID) async throws(APIError) { try await inner.unfollow(id) }
    func notifies(_ id: Flight.ID) async throws(APIError) -> Bool? { try await inner.notifies(id) }
    func flight(_ id: Flight.ID) async throws(APIError) -> Flight {
        if let f = flightOverride { return f }
        return try await inner.flight(id)
    }
    func events(_ id: Flight.ID) async throws(APIError) -> [FlightEvent] {
        if let e = eventsError { throw e }
        if let e = eventsOverride { return e }
        return try await inner.events(id)
    }
    func updates(for ids: [Flight.ID]) -> AsyncStream<Flight> {
        subs.withLock { $0 += 1 }
        let source = inner.updates(for: ids)
        return AsyncStream { cont in
            let t = Task { for await f in source { cont.yield(f) }; cont.finish() }
            cont.onTermination = { [self] _ in t.cancel(); subs.withLock { $0 -= 1 } }
        }
    }
}

private struct StubCache: FlightListCache {
    var stored: [Flight]
    func save(flights: [Flight]) async {}
    func flights() async -> [Flight] { stored }
}

@Suite @MainActor struct StoreRaceTests {
    @Test func staleLoadDoesNotOverwriteNewer() async throws {
        let svc = ScriptedFlights()
        let store = MyFlightsStore(flights: svc)
        let slow = Task { await store.load() }          // reads old data, stalls
        try await Task.sleep(for: .milliseconds(50))
        var f = try await svc.inner.followed()[0]
        f.gateOrigin = "Z99"; f.updatedAt = .now.addingTimeInterval(60)
        await svc.inner.push(f)
        await store.load()                              // newer, returns first
        #expect((store.live + store.upcoming).first { $0.id == f.id }?.gateOrigin == "Z99")
        await slow.value
        #expect((store.live + store.upcoming).first { $0.id == f.id }?.gateOrigin == "Z99")
    }

    @Test func loadStartedBeforeUnfollowDoesNotResurrect() async throws {
        let svc = ScriptedFlights()
        let store = MyFlightsStore(flights: svc)
        let victim = try await svc.inner.followed()[1]
        let slow = Task { await store.load() }
        try await Task.sleep(for: .milliseconds(50))
        await store.unfollow(victim)
        await slow.value
        #expect(!(store.live + store.upcoming).contains { $0.id == victim.id })
    }

    @Test func snapshotKeepsNewerPushedFlight() async throws {
        let svc = ScriptedFlights(stallFollowedCall: 2)
        let store = MyFlightsStore(flights: svc)
        await store.load()
        store.startUpdates()
        let slow = Task { await store.load() }          // second call reads old data, stalls
        try await Task.sleep(for: .milliseconds(50))
        var f = store.live[0]
        f.gateOrigin = "P1"; f.updatedAt = .now.addingTimeInterval(120)
        await svc.inner.push(f)
        await eventually { store.live.first?.gateOrigin == "P1" }
        await slow.value                                // old snapshot lands last
        #expect(store.live.first?.gateOrigin == "P1")
        var stale = f
        stale.gateOrigin = "OLD"; stale.updatedAt = f.updatedAt.addingTimeInterval(-60)
        await svc.inner.push(stale)                     // an older push is ignored too
        try await Task.sleep(for: .milliseconds(100))
        #expect(store.live.first?.gateOrigin == "P1")
    }

    @Test func staleSearchDoesNotOverwriteNewer() async throws {
        let svc = ScriptedFlights()
        let store = SearchStore(flights: svc)
        store.text = "AF84"
        let slow = Task { await store.search() }
        try await Task.sleep(for: .milliseconds(50))
        store.text = "UA1527"
        await store.search()
        await slow.value
        #expect(store.results.allSatisfy { $0.ident == "UA1527" })
        #expect(!store.results.isEmpty)
        #expect(!store.isSearching)
    }

    @Test func offlineFallsBackToCache() async throws {
        let svc = FakeFlightService()
        let cached = try await svc.followed().prefix(2)
        await svc.setNextError(.offline)
        let store = MyFlightsStore(flights: svc, cache: StubCache(stored: Array(cached)))
        await store.load()
        #expect(store.isOffline)
        #expect(store.live.count + store.upcoming.count == 2)
        #expect(store.lastUpdated == cached.map(\.updatedAt).max())
    }

    @Test func storeReleaseCancelsUpdates() async throws {
        let svc = ScriptedFlights(stall: .zero)
        var store: MyFlightsStore? = MyFlightsStore(flights: svc)
        await store?.load()
        store?.startUpdates()
        #expect(svc.activeSubscriptions == 1)
        store = nil
        await eventually { svc.activeSubscriptions == 0 }
        #expect(svc.activeSubscriptions == 0)
    }

    @Test func detailDivertedUsesActualAirport() async throws {
        var f = try await FakeFlightService().flight(wn4410)
        f.destinationIcao = "KSFO"                      // planned airport
        let ev = FlightEvent(flightId: f.id, kind: .diversion, payload: ["destination": "KOAK"], receivedAt: .now)
        let store = FlightDetailStore(id: f.id, flights: ScriptedFlights(flight: f, events: [ev]), airports: FakeAirportService())
        await store.load()
        #expect(store.destination?.id == "KOAK")
        #expect(store.error == nil)
    }

    @Test func detailDivertedWithoutEventsHidesPlannedDestination() async throws {
        var f = try await FakeFlightService().flight(wn4410)
        f.destinationIcao = "KSFO"
        let store = FlightDetailStore(id: f.id, flights: ScriptedFlights(flight: f, eventsError: .providerUnavailable), airports: FakeAirportService())
        await store.load()
        #expect(store.error == .providerUnavailable)
        #expect(store.destination == nil)
        #expect(store.flight?.id == f.id)
    }

    @Test func detailAirportFailureSetsError() async {
        let airports = FakeAirportService()
        await airports.setNextError(.rateLimited)
        let store = FlightDetailStore(id: wn4410, flights: FakeFlightService(), airports: airports)
        await store.load()
        #expect(store.error == .rateLimited)
    }

    @Test func deleteAccountFailureIsExposed() async throws {
        let auth = FakeAuthService()
        let store = SessionStore(auth: auth)
        store.start()
        try await auth.signInWithEmail("a@b.co")
        await eventually { store.session != nil }
        await auth.setNextError(.unauthorized)
        await store.deleteAccount()
        #expect(store.error == .unauthorized)
        #expect(store.session != nil)
    }
}
