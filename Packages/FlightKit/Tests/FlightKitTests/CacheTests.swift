import Testing
import Foundation
@testable import FlightKit

@Suite @MainActor struct CacheTests {
    @Test func roundTripFlights() async throws {
        let cache = try CacheStore.inMemory()
        #expect(await cache.flights().isEmpty)
        #expect(await cache.savedAt(.flights) == nil)
        let flights = Array(try await FakeFlightService().followed().prefix(3))
        await cache.save(flights: flights)
        #expect(await cache.flights() == flights)
        #expect(await cache.savedAt(.flights) != nil)
        // Saving again replaces, it does not append.
        await cache.save(flights: Array(flights.prefix(1)))
        #expect(await cache.flights() == Array(flights.prefix(1)))
    }

    @Test func roundTripPast() async throws {
        let cache = try CacheStore.inMemory()
        let past = try await FakeHistoryService().pastFlights()
        #expect(!past.isEmpty)
        await cache.save(past: past)
        #expect(await cache.past() == past)
        #expect(await cache.savedAt(.past) != nil)
        #expect(await cache.savedAt(.flights) == nil)
    }

    @Test func myFlightsOfflineShowsCache() async throws {
        let svc = FakeFlightService()
        let cache = try CacheStore.inMemory()
        await cache.save(flights: Array(try await svc.followed().prefix(2)))
        let savedAt = try #require(await cache.savedAt(.flights))
        await svc.setNextError(.offline)
        let store = MyFlightsStore(flights: svc, cache: cache)
        await store.load()
        #expect(store.live.count + store.upcoming.count == 2)
        #expect(store.isOffline)
        #expect(store.lastUpdated == savedAt)
    }

    @Test func myFlightsRecoversAfterOffline() async throws {
        let svc = FakeFlightService()
        let cache = try CacheStore.inMemory()
        await cache.save(flights: Array(try await svc.followed().prefix(2)))
        await svc.setNextError(.offline)
        let store = MyFlightsStore(flights: svc, cache: cache)
        await store.load()
        #expect(store.isOffline)
        await store.load()
        #expect(!store.isOffline && store.error == nil)
        #expect(await cache.flights().count == (try await svc.followed()).count)
    }

    @Test func detailShowsCachedFlightWhenOffline() async throws {
        let svc = FakeFlightService()
        let cache = try CacheStore.inMemory()
        let all = try await svc.followed()
        await cache.save(flights: all)
        let target = all[0]
        await svc.setNextError(.offline)
        let store = FlightDetailStore(id: target.id, flights: svc, airports: FakeAirportService(), cache: cache)
        await store.load()
        #expect(store.flight?.id == target.id)
        #expect(store.error == .offline)
    }

    @Test func passportOfflineShowsCachedPast() async throws {
        let history = FakeHistoryService()
        let cache = try CacheStore.inMemory()
        let online = PassportStore(history: history, cache: cache)
        await online.load()
        let n = online.flights.count
        #expect(n > 0)
        await history.setNextError(.offline)
        let store = PassportStore(history: history, cache: cache)
        await store.load()
        #expect(store.flights.count == n)
        #expect(store.isOffline)
        #expect(store.lastUpdated == (await cache.savedAt(.past)))
    }
}
