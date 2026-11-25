import Foundation
import Testing
@testable import FlightKit

/// The tabs open from the device's saved copy: Friends keeps its own, a list saved empty is known (no
/// loader), and a list whose load fails on a network with no internet behind it estimates its planes.
@Suite @MainActor struct OfflineCacheTests {
    static let now = ISO8601DateFormatter().date(from: "2026-11-03T08:00:00Z")!

    @Test func friendsShowTheSavedCopyOffline() async throws {
        let cache = try CacheStore.inMemory()
        let online = FriendsStore(service: FakeFriendsService(now: Self.now), cache: cache)
        await online.load()
        #expect(!online.friends.isEmpty)
        #expect(!online.isShowingCache)

        let offline = FriendsStore(service: OfflineFriends(), cache: cache)
        await offline.load()
        #expect(offline.friends.map(\.id) == online.friends.map(\.id))
        #expect(offline.flights.map(\.id) == online.flights.map(\.id))
        #expect(offline.requests.map(\.id) == online.requests.map(\.id))
        #expect(offline.me == online.me)
        #expect(offline.isShowingCache)
        #expect(offline.cachedAt != nil)
        #expect(offline.error == .offline)
    }

    @Test func friendsCacheBelongsToItsAccount() async throws {
        let cache = try CacheStore.inMemory()
        let me = UUID(), other = UUID()
        try await cache.claim(for: me)
        await FriendsStore(service: FakeFriendsService(now: Self.now), cache: cache.scoped(for: me)).load()
        let stranger = FriendsStore(service: OfflineFriends(), cache: cache.scoped(for: other))
        await stranger.load()
        #expect(stranger.friends.isEmpty)
        #expect(!stranger.isShowingCache)
    }

    @Test func anEmptySavedListIsKnownNotLoading() async throws {
        let svc = FakeFlightService()
        let cache = try CacheStore.inMemory()
        await cache.save(flights: [])
        await svc.setNextError(.offline)
        let store = MyFlightsStore(flights: svc, cache: cache)
        await store.load()
        #expect(store.isShowingCache)
        #expect(store.flights.isEmpty)
    }

    @Test func anEmptySavedHistoryIsKnown() async throws {
        let cache = try CacheStore.inMemory()
        await cache.save(past: [])
        let store = PassportStore(history: FakeHistoryService(), cache: cache)
        #expect(!store.hasCache)
        await store.load()
        #expect(store.hasCache)
    }

    @Test func aFailedLoadMeansNoBackend() async throws {
        let env = try await AppEnvironment.fake(now: Self.now)
        let home = HomeModel(env: env)
        await home.myFlights.load()
        #expect(home.canReachBackend)
        let svc = try #require(env.flights as? FakeFlightService)
        await svc.setNextError(.providerUnavailable)
        await home.myFlights.load()
        #expect(!home.canReachBackend)
    }
}

struct OfflineFriends: FriendsService {
    init() {}
    func me() async throws(APIError) -> FriendsMe { throw .offline }
    func saveProfile(displayName: String?, emoji: String?) async throws(APIError) { throw .offline }
    func setPaused(_ paused: Bool) async throws(APIError) { throw .offline }
    func friends() async throws(APIError) -> [Friend] { throw .offline }
    func requests() async throws(APIError) -> [FriendRequest] { throw .offline }
    func flights(of friend: Friend.ID?) async throws(APIError) -> [FriendFlight] { throw .offline }
    func passport(of friend: Friend.ID) async throws(APIError) -> FriendPassport? { throw .offline }
    func update(_ friend: Friend.ID, settings: FriendSettings) async throws(APIError) { throw .offline }
    func remove(_ friend: Friend.ID) async throws(APIError) { throw .offline }
    func invite() async throws(APIError) -> FriendInvite { throw .offline }
    func preview(token: String) async throws(APIError) -> FriendInvitePreview { throw .offline }
    func respond(token: String, accept: Bool) async throws(APIError) -> Friend.ID? { throw .offline }
    func request(code: String) async throws(APIError) -> FriendCodeResult { throw .offline }
    func respond(request: FriendRequest.ID, accept: Bool) async throws(APIError) { throw .offline }
    func revoke(_ invitation: UUID) async throws(APIError) { throw .offline }
    func resetCode() async throws(APIError) -> String { throw .offline }
}
