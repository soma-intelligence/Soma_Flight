import Testing
import Foundation
@testable import FlightKit

private let af84 = UUID(uuidString: "6f1c7d7e-3b0a-4f2e-9d55-2f6a1c0b8a11")!
private let wn4410 = UUID(uuidString: "20fae9c5-79ee-5ec3-a45a-015ed6c7fd9d")!

/// Waits until `cond` holds, up to ~2 s.
@MainActor private func eventually(_ cond: () -> Bool) async {
    for _ in 0..<200 where !cond() { try? await Task.sleep(for: .milliseconds(10)) }
}

@Suite @MainActor struct StoresTests {
    @Test func myFlightsSplitsLiveAndUpcoming() async {
        let store = MyFlightsStore(flights: FakeFlightService())
        await store.load()
        #expect(store.live.map(\.id) == [af84])
        #expect(store.upcoming.allSatisfy { $0.status != .enRoute && $0.status != .departed })
        let outs = store.upcoming.map { $0.scheduledOut ?? .distantFuture }
        #expect(outs == outs.sorted())
        #expect(store.lastUpdated == (store.live + store.upcoming).map(\.updatedAt).max())
        #expect(store.error == nil && !store.isOffline)
    }

    @Test func myFlightsAppliesRealtimeUpdate() async {
        let svc = FakeFlightService()
        let store = MyFlightsStore(flights: svc)
        await store.load()
        store.startUpdates()
        store.startUpdates() // idempotent
        var f = store.live[0]
        f.gateOrigin = "Z99"
        await svc.push(f)
        await eventually { store.live.first?.gateOrigin == "Z99" }
        #expect(store.live[0].gateOrigin == "Z99")
    }

    @Test func myFlightsCanceledShownAsCanceled() async {
        let svc = FakeFlightService()
        let store = MyFlightsStore(flights: svc)
        await store.load()
        store.startUpdates()
        var f = store.live[0]
        f.status = .canceled
        await svc.push(f)
        await eventually { store.live.isEmpty }
        let shown = (store.live + store.upcoming).first { $0.id == f.id }
        #expect(shown?.status == .canceled)
    }

    @Test func myFlightsOfflineKeepsListAndFlags() async {
        let svc = FakeFlightService()
        let store = MyFlightsStore(flights: svc)
        await store.load()
        let n = store.live.count + store.upcoming.count
        await svc.setNextError(.offline)
        await store.load()
        #expect(store.isOffline && store.error == .offline)
        #expect(store.live.count + store.upcoming.count == n)
    }

    @Test func myFlightsUnfollowRemoves() async {
        let store = MyFlightsStore(flights: FakeFlightService())
        await store.load()
        let victim = store.upcoming[0]
        await store.unfollow(victim)
        #expect(!(store.live + store.upcoming).contains { $0.id == victim.id })
    }

    @Test func searchPlanLimitKeepsText() async throws {
        let svc = FakeFlightService()
        let before = try await svc.followed().map(\.id)
        let store = SearchStore(flights: svc)
        store.text = "AF84"
        await store.search()
        let hit = try #require(store.results.first)
        await svc.setNextError(.planLimit)
        #expect(await store.follow(hit) == false)
        #expect(store.text == "AF84")
        #expect(store.error == .planLimit)
        #expect(try await svc.followed().map(\.id) == before)
    }

    @Test func searchRateLimitKeepsText() async throws {
        let svc = FakeFlightService()
        let before = try await svc.followed().map(\.id)
        let store = SearchStore(flights: svc)
        store.text = "UA1527"
        await svc.setNextError(.rateLimited)
        await store.search()
        #expect(store.text == "UA1527")
        #expect(store.error == .rateLimited)
        #expect(!store.isSearching)
        #expect(try await svc.followed().map(\.id) == before)
    }

    @Test func airportStoreLoadsAllParts() async {
        let store = AirportStore(code: "KSFO", airports: FakeAirportService())
        await store.load()
        #expect(store.airport?.id == "KSFO")
        #expect(store.departures != nil && store.arrivals != nil)
        #expect(store.stats != nil && store.weather != nil)
        #expect(Set(store.fetchedAt.keys) == [.departures, .arrivals, .stats, .weather])
    }

    @Test func passportStoreFiltersByYear() async {
        let store = PassportStore(history: FakeHistoryService())
        await store.load()
        #expect(store.years == [2026, 2025, 2024])
        #expect(store.flights.count == 8)
        store.year = 2025
        #expect(store.flights.count == 3)
        #expect(store.stats.flights == 2) // one 2025 flight is canceled
    }

    @Test func sessionStoreFollowsAuth() async throws {
        let auth = FakeAuthService()
        let store = SessionStore(auth: auth)
        store.start()
        try await auth.signInWithEmail("a@b.co")
        await eventually { store.session != nil }
        #expect(store.session?.email == "a@b.co")
        await store.deleteAccount()
        await eventually { store.session == nil }
        #expect(store.session == nil)
        #expect(store.error == nil)
        try await auth.signInWithEmail("c@d.co")
        await eventually { store.session != nil }
        await store.signOut()
        await eventually { store.session == nil }
        #expect(store.session == nil)
    }
}
