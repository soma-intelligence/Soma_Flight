import CoreLocation
import Foundation
import Testing
@testable import FlightKit

@Suite @MainActor struct AppEnvironmentTests {
    @Test func fakeWiresSeededServicesAndCache() async throws {
        let env = try await AppEnvironment.fake()
        #expect(env.flights is FakeFlightService)
        #expect(env.airports is FakeAirportService)
        #expect(env.auth is FakeAuthService)
        #expect(env.history is FakeHistoryService)
        #expect(env.push is FakePushService)
        #expect(env.recentsDefaults == nil)

        let flights = env.makeMyFlightsStore(owner: nil)
        await flights.load()
        #expect(!(flights.live + flights.upcoming).isEmpty)
        // The store writes through to the environment's cache.
        #expect(await env.cache.flights().count == (flights.live + flights.upcoming).count)

        let passport = env.makePassportStore(owner: nil)
        await passport.load()
        #expect(!passport.flights.isEmpty)
        #expect(await env.cache.past().count == passport.flights.count)

        let any = try #require(flights.live.first ?? flights.upcoming.first)
        let detail = env.makeFlightDetailStore(id: any.id, owner: nil)
        await detail.load()
        #expect(detail.flight?.id == any.id)
        #expect(detail.origin != nil)

        let airport = env.makeAirportStore(code: any.originIcao)
        await airport.load()
        #expect(airport.airport?.id == any.originIcao)
    }

    @Test func lookupFindsSeedAirportsByEitherCode() async throws {
        let env = try await AppEnvironment.fake()
        let sfo = try #require(env.lookup("KSFO"))
        #expect(env.lookup("sfo") == sfo)
        #expect(env.lookup(" SFO ") == sfo)
        #expect(env.lookup("ZZZZ") == nil)
        // Every far end of a followed flight resolves, so cards show city names.
        for f in try await env.flights.followed() {
            #expect(env.lookup(f.originIcao) != nil)
            #expect(env.lookup(f.destinationIcao) != nil)
        }
    }

    @Test func cacheClearEmptiesEveryKey() async throws {
        let cache = try CacheStore.inMemory()
        await cache.save(flights: try await FakeFlightService().followed())
        await cache.save(past: try await FakeHistoryService().pastFlights())
        try await cache.clear()
        #expect(await cache.flights().isEmpty)
        #expect(await cache.past().isEmpty)
        #expect(await cache.savedAt(.flights) == nil)
        #expect(await cache.savedAt(.past) == nil)
    }

    /// A signed-in account with a filled cache and one recent search.
    private func filledEnv(suite: String) async throws -> (AppEnvironment, SessionStore) {
        var env = try await AppEnvironment.fake()
        env.recents = .suite(suite)
        UserDefaults(suiteName: suite)!.removePersistentDomain(forName: suite)
        let session = env.makeSessionStore()
        session.start()
        try await env.auth.signInWithEmail("a@example.com")
        try await waitUntil { session.session != nil }
        let flights = env.makeMyFlightsStore(owner: session.session?.userId)
        await flights.load()
        let passport = env.makePassportStore(owner: session.session?.userId)
        await passport.load()
        let search = env.makeSearchStore()
        search.text = "SFO"
        await search.search()
        #expect(!(await env.cache.flights()).isEmpty)
        #expect(!(await env.cache.past()).isEmpty)
        #expect(UserDefaults(suiteName: suite)!.stringArray(forKey: SearchStore.recentKey) == ["SFO"])
        return (env, session)
    }

    @Test func signOutClearsCacheAndRecents() async throws {
        let suite = "test.signout.\(UUID().uuidString)"
        let (env, session) = try await filledEnv(suite: suite)
        await session.signOut()
        #expect(await env.cache.flights().isEmpty)
        #expect(await env.cache.past().isEmpty)
        #expect(await env.cache.owner() == nil)
        #expect(UserDefaults(suiteName: suite)!.stringArray(forKey: SearchStore.recentKey) == nil)
        // A fresh store for the next account starts empty, with no recents.
        #expect(env.makeSearchStore().recent.isEmpty)
        // The stream's own nil that follows finds nothing left to wipe.
        try await waitUntil { session.session == nil }
        #expect(session.error == nil)
        UserDefaults(suiteName: suite)!.removePersistentDomain(forName: suite)
    }

    @Test func accountDeletionClearsCache() async throws {
        let suite = "test.delete.\(UUID().uuidString)"
        let (env, session) = try await filledEnv(suite: suite)
        await session.deleteAccount()
        #expect(session.error == nil)
        #expect(await env.cache.flights().isEmpty)
        #expect(await env.cache.past().isEmpty)
        UserDefaults(suiteName: suite)!.removePersistentDomain(forName: suite)
    }

    @Test func failedDeletionKeepsCache() async throws {
        let auth = FakeAuthService()
        let cache = try CacheStore.inMemory()
        await cache.save(flights: try await FakeFlightService().followed())
        let session = SessionStore(auth: auth, onUserChange: { try await cache.claim(for: $0) })
        await auth.setNextError(.providerUnavailable)
        await session.deleteAccount()
        #expect(session.error == .providerUnavailable)
        #expect(!(await cache.flights()).isEmpty)
    }

    @Test func sessionEndingOnItsOwnClearsCache() async throws {
        let auth = FakeAuthService()
        let cache = try CacheStore.inMemory()
        let session = SessionStore(auth: auth, onUserChange: { try await cache.claim(for: $0) })
        session.start()
        try await auth.signInWithEmail("a@example.com")
        try await waitUntil { session.session != nil }
        await cache.save(flights: try await FakeFlightService().followed())
        #expect(!(await cache.flights()).isEmpty)
        // Signed out elsewhere (expired token): the stream goes nil without signOut() here.
        await auth.signOut()
        try await waitUntil { session.session == nil }
        try await waitUntil { await cache.flights().isEmpty }
    }

    private func waitUntil(_ condition: () async -> Bool) async throws {
        for _ in 0..<200 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("condition not met in 2 s")
    }

    @Test func globeContentForFollowedAndPast() async throws {
        let env = try await AppEnvironment.fake()
        let followed = try await env.flights.followed()
        let g = GlobeContent.followed(followed, lookup: env.lookup)
        #expect(g.routes.count == followed.count)
        #expect(Set(g.routes.map(\.id)) == Set(followed.map(\.id.uuidString)))
        #expect(g.planes.count == followed.filter { $0.position != nil }.count)
        #expect(Set(g.airports.map(\.id)) == Set(followed.flatMap { [$0.originIcao, $0.destinationIcao] }))

        let past = try await env.history.pastFlights()
        let p = GlobeContent.past(past, lookup: env.lookup)
        let pairs = Set(past.map { [$0.originIcao, $0.destinationIcao].sorted().joined(separator: "-") })
        #expect(p.routes.count == pairs.count)
        #expect(p.routes.allSatisfy { $0.isPast })
        #expect(p.planes.isEmpty)
    }

    @Test func focusCameraCentresOnTheArc() throws {
        let a = Airport(id: "LFPG", name: "CDG", city: "Paris", country: "FR", lat: 49.0, lon: 2.5, tz: "Europe/Paris")
        let b = Airport(id: "KJFK", name: "JFK", city: "New York", country: "US", lat: 40.6, lon: -73.8, tz: "America/New_York")
        let route = Route(from: a.coordinate, to: b.coordinate, level: .onTime, isPast: false)
        let cam = GlobeMap.camera(for: .route(route), in: .phone)
        // Between the two ends in longitude, and far enough out to hold a 5,800 km arc.
        #expect(cam.centerCoordinate.longitude < 2.5 && cam.centerCoordinate.longitude > -73.8)
        #expect(cam.distance > 5_800_000)
        let close = GlobeMap.camera(for: .airport(a), in: .phone)
        #expect(close.centerCoordinate.latitude == 49.0)
        #expect(close.distance < 50_000)
    }
}
