import Foundation
import Synchronization
import Testing
@testable import FlightKit

// The store side of the 2026-11-18 premium checklist audit (docs/audits/2026-11-18-premium-checklist-audit.md):
// one test or more per finding id.

@MainActor private func eventually(_ cond: () -> Bool) async {
    for _ in 0..<300 where !cond() { try? await Task.sleep(for: .milliseconds(10)) }
}

/// A cache with a list in it, and a save time.
private struct SavedList: FlightListCache {
    var stored: [Flight]
    var savedAt: Date?
    func save(flights: [Flight]) async {}
    func flights() async -> [Flight] { stored }
    func flightsSavedAt() async -> Date? { savedAt }
}

/// A flight service whose `followed()` waits for a gate to open, fails with a scripted error, and counts
/// unfollow calls. Everything else is the fake's.
private final class GatedFlights: FlightService, Sendable {
    let inner = FakeFlightService()
    private let state = Mutex<(open: Bool, followedError: APIError?, unfollowError: APIError?, unfollows: Int,
                               unfollowDelay: Duration)>((true, nil, nil, 0, .zero))

    func close() { state.withLock { $0.open = false } }
    func open() { state.withLock { $0.open = true } }
    func failFollowed(_ e: APIError?) { state.withLock { $0.followedError = e } }
    func failUnfollow(_ e: APIError?) { state.withLock { $0.unfollowError = e } }
    func slowUnfollow(_ d: Duration) { state.withLock { $0.unfollowDelay = d } }
    var unfollows: Int { state.withLock { $0.unfollows } }

    func followed() async throws(APIError) -> [Flight] {
        while !state.withLock({ $0.open }) { try? await Task.sleep(for: .milliseconds(5)) }
        if let e = state.withLock({ $0.followedError }) { throw e }
        return try await inner.followed()
    }
    func unfollow(_ id: Flight.ID) async throws(APIError) {
        let (delay, error) = state.withLock { s -> (Duration, APIError?) in s.unfollows += 1; return (s.unfollowDelay, s.unfollowError) }
        if delay > .zero { try? await Task.sleep(for: delay) }
        if let error { throw error }
        try await inner.unfollow(id)
    }
    func lookup(_ query: FlightQuery) async throws(APIError) -> [Flight] { try await inner.lookup(query) }
    func follow(_ id: Flight.ID, notify: Bool) async throws(APIError) { try await inner.follow(id, notify: notify) }
    func notifies(_ id: Flight.ID) async throws(APIError) -> Bool? { try await inner.notifies(id) }
    func followDetails(_ id: Flight.ID) async throws(APIError) -> FollowDetails? { try await inner.followDetails(id) }
    func saveFollowDetails(_ id: Flight.ID, _ details: FollowDetails) async throws(APIError) {
        try await inner.saveFollowDetails(id, details)
    }
    func flight(_ id: Flight.ID) async throws(APIError) -> Flight { try await inner.flight(id) }
    func events(_ id: Flight.ID) async throws(APIError) -> [FlightEvent] { try await inner.events(id) }
    func updates(for ids: [Flight.ID]) -> AsyncStream<Flight> { inner.updates(for: ids) }
}

/// Friends whose answers to a request, a cancel and a remove take a while, counted.
private actor SlowFriends: FriendsService {
    let inner = FakeFriendsService()
    private(set) var responds = 0, revokes = 0, removes = 0
    var failNext: APIError?

    func setFailNext(_ e: APIError?) { failNext = e }
    private func slow() async throws(APIError) {
        try? await Task.sleep(for: .milliseconds(80))
        if let e = failNext { failNext = nil; throw e }
    }

    func me() async throws(APIError) -> FriendsMe { try await inner.me() }
    func saveProfile(displayName: String?, emoji: String?) async throws(APIError) {
        try await inner.saveProfile(displayName: displayName, emoji: emoji)
    }
    func setPaused(_ paused: Bool) async throws(APIError) { try await inner.setPaused(paused) }
    func friends() async throws(APIError) -> [Friend] { try await inner.friends() }
    func requests() async throws(APIError) -> [FriendRequest] { try await inner.requests() }
    func flights(of friend: Friend.ID?) async throws(APIError) -> [FriendFlight] { try await inner.flights(of: friend) }
    func passport(of friend: Friend.ID) async throws(APIError) -> FriendPassport? { try await inner.passport(of: friend) }
    func update(_ friend: Friend.ID, settings: FriendSettings) async throws(APIError) {
        try await inner.update(friend, settings: settings)
    }
    func remove(_ friend: Friend.ID) async throws(APIError) {
        removes += 1
        try await slow()
        try await inner.remove(friend)
    }
    func invite() async throws(APIError) -> FriendInvite { try await inner.invite() }
    func preview(token: String) async throws(APIError) -> FriendInvitePreview { try await inner.preview(token: token) }
    func respond(token: String, accept: Bool) async throws(APIError) -> Friend.ID? {
        try await inner.respond(token: token, accept: accept)
    }
    func request(code: String) async throws(APIError) -> FriendCodeResult { try await inner.request(code: code) }
    func respond(request: FriendRequest.ID, accept: Bool) async throws(APIError) {
        responds += 1
        try await slow()
        try await inner.respond(request: request, accept: accept)
    }
    func revoke(_ invitation: UUID) async throws(APIError) {
        revokes += 1
        try await slow()
        try await inner.revoke(invitation)
    }
    func resetCode() async throws(APIError) -> String { try await inner.resetCode() }
}

@Suite @MainActor struct StoreAuditFixTests {
    // MARK: E1, cache before the network

    @Test func e1ShowsTheSavedListBeforeTheNetworkAnswers() async throws {
        let svc = GatedFlights()
        let saved = try await svc.inner.followed()
        let savedAt = Date.now.addingTimeInterval(-600)
        svc.close()
        let store = MyFlightsStore(flights: svc, cache: SavedList(stored: saved, savedAt: savedAt))
        let load = Task { await store.load() }
        await eventually { !store.flights.isEmpty }
        #expect(store.flights.count == saved.count)
        #expect(store.isShowingCache)
        #expect(store.fetchedAt == savedAt)
        #expect(!store.hasLoaded)
        svc.open()
        await load.value
        #expect(!store.isShowingCache)
        #expect(store.hasLoaded && store.error == nil)
    }

    @Test func e1AServerFailureFallsBackOnTheCacheToo() async throws {
        let svc = GatedFlights()
        let saved = try await svc.inner.followed()
        svc.failFollowed(.providerUnavailable)
        // The cache read first already filled the list; with a cache read only on `.offline` before, a
        // server outage showed nothing.
        let store = MyFlightsStore(flights: svc, cache: SavedList(stored: saved))
        await store.load()
        #expect(store.error == .providerUnavailable)
        #expect(!store.isOffline)
        #expect(store.flights.count == saved.count)
        #expect(store.isShowingCache)
    }

    // MARK: E2, offline lifts

    @Test func e2APushedUpdateClearsOffline() async throws {
        let svc = GatedFlights()
        let store = MyFlightsStore(flights: svc)
        await store.load()
        store.startUpdates()
        svc.failFollowed(.offline)
        await store.load()
        #expect(store.isOffline && store.error == .offline)
        var f = try #require(store.live.first ?? store.upcoming.first)
        f.gateOrigin = "B12"; f.updatedAt = .now.addingTimeInterval(60)
        await svc.inner.push(f)
        await eventually { !store.isOffline }
        #expect(!store.isOffline)
        #expect(store.error == nil)
    }

    @Test func e2ReconnectReloadsAnOfflineList() async throws {
        let svc = GatedFlights()
        svc.failFollowed(.offline)
        let store = MyFlightsStore(flights: svc)
        await store.load()
        #expect(store.isOffline)
        svc.failFollowed(nil)
        await store.refreshIfNeeded()
        #expect(!store.isOffline && store.error == nil)
        #expect(!store.flights.isEmpty)
    }

    @Test func e2ConnectivityCallsBackOnReconnectOnly() async {
        let c = Connectivity(online: true)
        var calls = 0
        c.onReconnect { calls += 1 }
        c.set(online: false)
        try? await Task.sleep(for: .milliseconds(30))
        #expect(calls == 0)
        c.set(online: true)
        await eventually { calls == 1 }
        #expect(calls == 1)
    }

    // MARK: E3, session refresh

    @Test func e3UnauthorizedRenewsTheSessionAndRetries() async {
        let svc = GatedFlights()
        svc.failFollowed(.unauthorized)
        let store = MyFlightsStore(flights: svc)
        var asked = 0
        store.onUnauthorized = {
            asked += 1
            svc.failFollowed(nil)
            return true
        }
        await store.load()
        #expect(asked == 1)
        #expect(store.error == nil)
        #expect(!store.flights.isEmpty)
    }

    @Test func e3ARefusedRefreshMarksTheSessionExpired() async {
        struct Refused: AuthService {
            var session: AsyncStream<UserSession?> { AsyncStream { $0.finish() } }
            func signInWithApple(idToken: String, nonce: String, fullName: PersonNameComponents?) async throws(APIError) {}
            func signInWithEmail(_ email: String) async throws(APIError) {}
            func signOut() async {}
            func deleteAccount(appleAuthorizationCode: String?) async throws(APIError) {}
            func refreshSession() async throws(APIError) { throw .unauthorized }
        }
        let session = SessionStore(auth: Refused())
        #expect(await session.recoverSession() == false)
        #expect(session.isSessionExpired)
        #expect(APIError.unauthorized.needsSignIn)
    }

    // MARK: E4, friends in flight

    @Test func e4ADoubleTapOnAcceptSendsOnce() async throws {
        let svc = SlowFriends()
        let store = FriendsStore(service: svc)
        await store.load()
        let request = try #require(store.incoming.first ?? store.requests.first)
        async let a: Void = store.respond(to: request, accept: true)
        async let b: Void = store.respond(to: request, accept: true)
        try await Task.sleep(for: .milliseconds(20))
        #expect(store.isPending(request.id))
        _ = await (a, b)
        #expect(await svc.responds == 1)
        #expect(store.actionError == nil)
        #expect(!store.isPending(request.id))
    }

    @Test func e4RemoveAndCancelAreGuardedPerId() async throws {
        let svc = SlowFriends()
        let store = FriendsStore(service: svc)
        await store.load()
        let friend = try #require(store.friends.first)
        async let r1: Void = store.remove(friend.id)
        async let r2: Void = store.remove(friend.id)
        _ = await (r1, r2)
        #expect(await svc.removes == 1)
        if let sent = store.outgoing.first {
            async let c1: Void = store.cancel(sent)
            async let c2: Void = store.cancel(sent)
            _ = await (c1, c2)
            #expect(await svc.revokes == 1)
        }
    }

    // MARK: E6, action error apart from the load error

    @Test func e6AFailedUnfollowIsAnActionErrorWithARetry() async throws {
        let svc = GatedFlights()
        let store = MyFlightsStore(flights: svc)
        await store.load()
        let f = try #require(store.flights.first)
        svc.failUnfollow(.providerUnavailable)
        let error = await store.unfollow(f)
        #expect(error == .providerUnavailable)
        #expect(store.error == nil)
        #expect(store.actionError?.kind == .unfollow)
        #expect(store.flights.contains { $0.id == f.id })
        svc.failUnfollow(nil)
        await store.actionError?.retry()
        #expect(!store.flights.contains { $0.id == f.id })
        #expect(store.actionError == nil)
    }

    @Test func e6AFailedFriendActionLeavesTheLoadErrorAlone() async throws {
        let svc = SlowFriends()
        let store = FriendsStore(service: svc)
        await store.load()
        let request = try #require(store.requests.first)
        await svc.setFailNext(.providerUnavailable)
        await store.respond(to: request, accept: false)
        #expect(store.error == nil)
        #expect(store.actionError?.kind == .respond)
        await store.actionError?.retry()
        #expect(store.actionError == nil)
        #expect(await svc.responds == 2)
    }

    @Test func e6AFailedFollowFromSearchIsNotASearchError() async throws {
        let flights = FakeFlightService()
        let s = SearchStore(flights: flights)
        let f = try #require(try await flights.followed().first)
        await flights.setNextError(.planLimit)
        #expect(await s.follow(f) == false)
        #expect(s.error == nil)
        #expect(s.followError?.kind == .follow)
        #expect(s.followError?.error == .planLimit)
    }

    // MARK: E7, offline only when the device says so

    @Test func e7ATimeoutWhileTheDeviceIsOnlineIsTheServer() {
        #expect(SupabaseBackend.map(URLError(.timedOut), deviceOnline: true) == .providerUnavailable)
        #expect(SupabaseBackend.map(URLError(.cannotConnectToHost), deviceOnline: true) == .providerUnavailable)
        #expect(SupabaseBackend.map(URLError(.cannotFindHost), deviceOnline: true) == .providerUnavailable)
        #expect(SupabaseBackend.map(URLError(.timedOut), deviceOnline: false) == .offline)
        // The system saying there is no connection is offline whatever the path monitor last said.
        #expect(SupabaseBackend.map(URLError(.notConnectedToInternet), deviceOnline: true) == .offline)
        #expect(SupabaseBackend.map(NSError(domain: NSURLErrorDomain, code: URLError.Code.timedOut.rawValue),
                                    deviceOnline: true) == .providerUnavailable)
    }

    // MARK: D1, a late answer never lands under new text

    @Test func d1ASearchSubmittedThenEditedDropsItsLateAnswer() async throws {
        // The first lookup stalls: the AF84 answer comes back after the user typed something else.
        let svc = ScriptedFlights(stall: .milliseconds(250))
        let s = SearchStore(flights: svc)
        s.suggestDelay = .milliseconds(1)
        s.liveDelay = .seconds(30) // no live lookup of its own: only the submitted search is in flight
        s.text = "AF84"
        s.textChanged()
        #expect(s.submit() == .searching)
        await eventually { s.isSearching }
        #expect(s.isSearching)
        // A text that starts no search: before the fix the AF84 answer passed the generation check.
        s.text = "lon"
        s.textChanged()
        #expect(!s.isSearching)
        try await Task.sleep(for: .milliseconds(400))
        #expect(s.items.isEmpty)
        #expect(s.error == nil)
        #expect(!s.recent.contains("lon"))
        #expect(s.recent.isEmpty)
    }

    @Test func d1EditingToTheSameRouteKeepsTheSearch() async throws {
        let svc = ScriptedFlights(stall: .milliseconds(150))
        let s = SearchStore(flights: svc)
        s.suggestDelay = .milliseconds(1)
        s.liveDelay = .seconds(30)
        s.text = "AF84"
        s.textChanged()
        #expect(s.submit() == .searching)
        await eventually { s.isSearching }
        s.text = "AF84 " // same route: the answer still fits
        s.textChanged()
        await eventually { !s.isSearching }
        #expect(!s.results.isEmpty)
        #expect(s.results.allSatisfy { $0.ident == "AF84" })
    }

    // MARK: E10, partial data is not a failure

    @Test func e10AFailedSectionLeavesTheFlightError() async throws {
        let f = try #require(try await FakeFlightService().followed().first)
        let store = FlightDetailStore(id: f.id, flights: ScriptedFlights(flight: f, eventsError: .providerUnavailable),
                                      airports: FakeAirportService())
        await store.load()
        #expect(store.flight?.id == f.id)
        #expect(store.error == nil)
        #expect(store.sectionErrors[.events] == .providerUnavailable)
    }

    @Test func i4AFailedAlertsSwitchHasItsOwnError() async throws {
        let flights = FakeFlightService()
        let f = try #require(try await flights.followed().first)
        let store = FlightDetailStore(id: f.id, flights: flights, airports: FakeAirportService())
        await store.load()
        let before = try #require(store.notify)
        await flights.setNextError(.providerUnavailable)
        await store.setNotify(!before)
        #expect(store.notify == before)
        #expect(store.notifyError == .providerUnavailable)
        #expect(store.error == nil)
        await store.retryNotify()
        #expect(store.notify == !before)
        #expect(store.notifyError == nil)
    }

    // MARK: E11

    @Test func e11AFailedLoadIsNotTheAccountsChoices() async {
        let svc = FakeNotificationPreferencesService()
        await svc.setNextError(.providerUnavailable)
        let store = NotificationSettingsStore(service: svc, defaults: UserDefaults(suiteName: "e11.\(UUID())")!)
        await store.load()
        #expect(store.hasLoaded)
        #expect(store.loadFailed)
        #expect(!store.hasPreferences)
        await store.retry()
        #expect(!store.loadFailed)
        #expect(store.hasPreferences)
    }

    // MARK: E14

    @Test func e14ALiveCardGoesStaleSoonerThanTheArrival() {
        let now = Date(timeIntervalSince1970: 1_792_803_600)
        let air = FlightActivityAttributes.ContentState(status: .enRoute, estimatedOut: now.addingTimeInterval(-3600),
                                                        estimatedIn: now.addingTimeInterval(5 * 3600))
        #expect(air.staleDate(now: now) == now.addingTimeInterval(FlightActivityAttributes.ContentState.liveStaleAfter))
        let tomorrow = FlightActivityAttributes.ContentState(status: .scheduled, estimatedOut: now.addingTimeInterval(86_400),
                                                             estimatedIn: now.addingTimeInterval(90_000))
        #expect(tomorrow.staleDate(now: now) == tomorrow.staleDate)
        let attrs = FlightActivityAttributes(flightId: UUID(), ident: "AF83", originIata: "SFO", destinationIata: "CDG",
                                             originTimeZone: "America/Los_Angeles", destinationTimeZone: "Europe/Paris")
        #expect(FlightActivityDisplay(attrs, air, isStale: true).staleNote != nil)
        #expect(FlightActivityDisplay(attrs, air).staleNote == nil)
    }

    // MARK: E15 + I1, undoable unfollow

    fileprivate static func home(_ svc: GatedFlights) async throws -> HomeModel {
        var env = try await AppEnvironment.fake()
        env.flights = svc
        env.fixedConnectivity = true
        let home = HomeModel(env: env)
        home.toastSleep = { _ in try await Task.sleep(for: .milliseconds(60)) }
        await home.myFlights.load()
        return home
    }

    @Test func i1UndoKeepsTheFlightAndNeverAsksTheServer() async throws {
        let svc = GatedFlights()
        let home = try await Self.home(svc)
        let f = try #require(home.followed.first)
        home.unfollowWithUndo(f)
        #expect(!home.followed.contains { $0.id == f.id })
        #expect(home.toastAction?.title == "Undo")
        #expect(home.isUnfollowPending(f.id))
        home.runToastAction()
        await eventually { home.followed.contains { $0.id == f.id } }
        try await Task.sleep(for: .milliseconds(120))
        #expect(home.followed.contains { $0.id == f.id })
        #expect(svc.unfollows == 0)
        #expect(home.toast == nil)
    }

    @Test func i1WithoutUndoTheServerHearsOnceTheWindowEnds() async throws {
        let svc = GatedFlights()
        let home = try await Self.home(svc)
        let f = try #require(home.followed.first)
        home.unfollowWithUndo(f)
        home.unfollowWithUndo(f) // E15: a second swipe while one waits does nothing
        await eventually { svc.unfollows == 1 && !home.isUnfollowPending(f.id) }
        try await Task.sleep(for: .milliseconds(40))
        #expect(svc.unfollows == 1)
        #expect(!home.myFlights.contains(f.id))
    }

    @Test func i1ARefusedUnfollowComesBackWithRetry() async throws {
        let svc = GatedFlights()
        let home = try await Self.home(svc)
        let f = try #require(home.followed.first)
        svc.failUnfollow(.providerUnavailable)
        home.unfollowWithUndo(f)
        await eventually { home.toastAction?.title == "Retry" }
        #expect(home.followed.contains { $0.id == f.id })
        #expect(home.toastIsError)
    }

    @Test func e15UnfollowIsGuardedWhileOnItsWay() async throws {
        let svc = GatedFlights()
        svc.slowUnfollow(.milliseconds(80))
        let store = MyFlightsStore(flights: svc)
        await store.load()
        let f = try #require(store.flights.first)
        async let a = store.unfollow(f)
        async let b = store.unfollow(f)
        _ = await (a, b)
        #expect(svc.unfollows == 1)
    }

    // MARK: I7

    @Test func i7AFlightThatNoLongerExistsSaysSo() async throws {
        let svc = GatedFlights()
        let home = try await Self.home(svc)
        let inbox = PushInbox()
        home.attachPush(inbox: inbox, authorizer: AllowedAuthorizer(), enabled: false, registerForRemote: {})
        _ = inbox.receiveTap(["flightId": UUID().uuidString])
        await home.processInbox()
        #expect(home.toast == HomeModel.flightGoneText)
    }

    // MARK: E5

    @Test func e5ADeniedPermissionIsExposed() async {
        let push = PushCoordinator(push: FakePushService(), authorizer: DeniedAuthorizer(), enabled: true, registerForRemote: {})
        #expect(push.permission == nil)
        await push.refreshPermission()
        #expect(push.permission == .denied)
        #expect(push.isDenied)
    }

    // MARK: A11

    @Test func a11UnitsFollowTheRegionUntilChosen() {
        let us = StoredUnits.defaultUnits(Locale(identifier: "en_US"))
        #expect(us == Units(distance: .mi, clock: .h12))
        let fr = StoredUnits.defaultUnits(Locale(identifier: "fr_FR"))
        #expect(fr == Units(distance: .km, clock: .h24))
    }

    // MARK: E13

    @Test func e13AFailedSendIsNotSynced() async {
        let store = TravelDocumentsStore(secrets: MemorySecretStore(), check: FakeDeviceOwnerCheck(), defaults: nil)
        #expect(store.syncState == .pending)
        await store.attach(cloud: UnavailableTravelVaultService())
        #expect(store.syncState == .failed)
    }
}

private struct DeniedAuthorizer: NotificationAuthorizer {
    func status() async -> NotificationPermission { .denied }
    func request() async -> Bool { false }
}

private struct AllowedAuthorizer: NotificationAuthorizer {
    func status() async -> NotificationPermission { .authorized }
    func request() async -> Bool { true }
}
