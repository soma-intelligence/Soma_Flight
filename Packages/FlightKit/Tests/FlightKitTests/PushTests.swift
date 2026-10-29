import Foundation
import Synchronization
import Testing
@testable import FlightKit

/// Task 10: notification payloads, the permission flow and routing a tap to a flight.
@Suite @MainActor struct PushTests {
    private let id = UUID(uuidString: "0f8fad5b-d9cb-469f-a165-70867728950e")!
    private let event = UUID(uuidString: "7c9e6679-7425-40de-944b-e07fc1f90ae7")!

    // MARK: Payload

    @Test func theBackendsPayloadParses() throws {
        let info: [AnyHashable: Any] = [
            "aps": ["alert": ["title": "AA829", "body": "Gate B12"], "thread-id": id.uuidString.lowercased()],
            "flightId": id.uuidString.lowercased(), "eventId": event.uuidString.lowercased(),
        ]
        let payload = try #require(PushPayload(userInfo: info))
        #expect(payload == PushPayload(flightId: id, eventId: event))
    }

    @Test func snakeCaseKeysWorkToo() throws {
        let payload = try #require(PushPayload(userInfo: ["flight_id": id.uuidString]))
        #expect(payload.flightId == id)
        #expect(payload.eventId == nil)
    }

    @Test func otherNotificationsAreNotFlights() {
        #expect(PushPayload(userInfo: ["aps": ["alert": "Hi"]]) == nil)
        #expect(PushPayload(userInfo: ["flightId": "not-a-uuid"]) == nil)
        #expect(PushPayload(userInfo: ["flightId": 12]) == nil)
    }

    // MARK: Inbox

    @Test func theInboxKeepsATapUntilTaken() {
        let inbox = PushInbox()
        #expect(inbox.receiveTap(["flightId": id.uuidString]))
        #expect(inbox.serial == 1)
        #expect(!inbox.receiveTap(["x": 1]))
        #expect(inbox.serial == 1)
        #expect(inbox.takePendingFlight() == id)
        #expect(inbox.takePendingFlight() == nil)
    }

    // MARK: Permission and registration

    private final class Authorizer: NotificationAuthorizer, @unchecked Sendable {
        var current: NotificationPermission
        var grants: Bool
        var prompts = 0
        init(_ current: NotificationPermission, grants: Bool = true) { self.current = current; self.grants = grants }
        func status() async -> NotificationPermission { current }
        func request() async -> Bool {
            prompts += 1
            current = grants ? .authorized : .denied
            return grants
        }
    }

    private func coordinator(_ auth: Authorizer, push: FakePushService = FakePushService(),
                             asks: Counter) -> PushCoordinator {
        PushCoordinator(push: push, authorizer: auth, enabled: true) { asks.count += 1 }
    }

    private final class Counter { var count = 0 }

    @Test func launchNeverShowsThePrompt() async {
        let auth = Authorizer(.notDetermined), asks = Counter()
        await coordinator(auth, asks: asks).refresh()
        #expect(auth.prompts == 0)
        #expect(asks.count == 0)
    }

    @Test func launchAsksForATokenOnlyWhenAllowed() async {
        let auth = Authorizer(.authorized), asks = Counter()
        await coordinator(auth, asks: asks).refresh()
        #expect(asks.count == 1)
        let denied = Authorizer(.denied), more = Counter()
        await coordinator(denied, asks: more).refresh()
        #expect(more.count == 0)
    }

    @Test func theFirstFollowShowsThePromptAndAsksForAToken() async {
        let auth = Authorizer(.notDetermined), asks = Counter()
        let c = coordinator(auth, asks: asks)
        await c.didFollow()
        #expect(auth.prompts == 1)
        #expect(asks.count == 1)
        await c.didFollow()
        #expect(auth.prompts == 1)
        #expect(asks.count == 2)
    }

    @Test func aDenialLeavesFollowsAloneAndNeverAsksAgain() async {
        let auth = Authorizer(.notDetermined, grants: false), asks = Counter()
        let c = coordinator(auth, asks: asks)
        await c.didFollow()
        await c.didFollow()
        #expect(auth.prompts == 1)
        #expect(asks.count == 0)
    }

    @Test func theTokenIsRegisteredAsAnAlertOncePerAccount() async throws {
        let push = FakePushService(), asks = Counter()
        let c = coordinator(Authorizer(.authorized), push: push, asks: asks)
        let token = Data([1, 2, 3])
        let a = UUID(), b = UUID()
        c.accountChanged(owner: a)
        await c.register(token: token)
        await c.register(token: token)
        #expect(await push.registrations == [.init(deviceToken: token, kind: .alert, flightId: nil)])
        // The same device, another account: registered again so the server moves it.
        c.accountChanged(owner: b)
        await c.register(token: token)
        #expect(await push.registrations.count == 2)
        // A rotated token registers too.
        await c.register(token: Data([9]))
        #expect(await push.registrations.count == 3)
    }

    @Test func aFailedRegistrationIsTriedAgain() async {
        let push = FakePushService(), asks = Counter()
        let c = coordinator(Authorizer(.authorized), push: push, asks: asks)
        await push.setNextError(.offline)
        await c.register(token: Data([1]))
        #expect(await push.registrations.isEmpty)
        await c.register(token: Data([1]))
        #expect(await push.registrations.count == 1)
    }

    // MARK: Routing

    private func home() async throws -> (HomeModel, PushInbox, FakePushService, Counter) {
        let push = FakePushService()
        var env = try await AppEnvironment.fake()
        env.push = push
        let home = HomeModel(env: env)
        let inbox = PushInbox(), asks = Counter()
        home.attachPush(inbox: inbox, authorizer: Authorizer(.denied)) { asks.count += 1 }
        await home.load()
        return (home, inbox, push, asks)
    }

    @Test func aTapOpensAFollowedFlight() async throws {
        let (home, inbox, _, _) = try await home()
        let flight = try #require(home.followed.first)
        inbox.receiveTap(["flightId": flight.id.uuidString])
        await home.processInbox()
        #expect(home.shell.path == [.flight(flight.id)])
        #expect(inbox.pendingFlight == nil)
    }

    @Test func aTapOnAFlightNotInMyFlightsLoadsItById() async throws {
        let (home, inbox, _, _) = try await home()
        let followed = Set(home.followed.map(\.id))
        let other = try #require(try await home.env.flights.lookup(.airport("KAUS")).first { !followed.contains($0.id) })
        inbox.receiveTap(["flightId": other.id.uuidString])
        await home.processInbox()
        #expect(home.shell.path == [.flight(other.id)])
    }

    @Test func aTapOnAnUnknownFlightOpensNothing() async throws {
        let (home, inbox, _, _) = try await home()
        inbox.receiveTap(["flightId": UUID().uuidString])
        await home.processInbox()
        #expect(home.shell.path.isEmpty)
        #expect(inbox.pendingFlight == nil)
    }

    @Test func aColdStartTapWaitsForTheHome() async throws {
        // The tap lands before the home exists; the home picks it up once it is attached and started.
        let inbox = PushInbox()
        let env = try await AppEnvironment.fake()
        let home = HomeModel(env: env)
        let flight = try #require(try await env.flights.followed().first)
        inbox.receiveTap(["flightId": flight.id.uuidString])
        home.attachPush(inbox: inbox, authorizer: Authorizer(.denied)) {}
        await home.start()
        #expect(home.shell.path == [.flight(flight.id)])
    }

    @Test func nothingOpensWhileSignedOut() async throws {
        let base = try await AppEnvironment.fake()
        let env = AppEnvironment(flights: base.flights, airports: base.airports, auth: base.auth, history: base.history,
                                 push: base.push, cache: base.cache, requiresSignIn: true)
        let home = HomeModel(env: env)
        let inbox = PushInbox()
        home.attachPush(inbox: inbox, authorizer: Authorizer(.denied)) {}
        let flight = try #require(try await env.flights.followed().first)
        inbox.receiveTap(["flightId": flight.id.uuidString])
        inbox.receive(deviceToken: Data([1]))
        await home.processInbox()
        #expect(home.shell.path.isEmpty)
        #expect(inbox.pendingFlight == flight.id)
    }

    @Test func aForegroundNotificationRefreshesTheList() async throws {
        let (home, inbox, _, _) = try await home()
        let flight = try #require(home.followed.first)
        try await home.env.flights.unfollow(flight.id)
        inbox.receiveForeground(PushPayload(flightId: flight.id))
        await home.processInbox()
        #expect(!home.followed.contains { $0.id == flight.id })
        #expect(inbox.foregroundFlight == nil)
    }

    @Test func theTokenInTheInboxIsRegisteredAfterStart() async throws {
        let (home, inbox, push, _) = try await home()
        inbox.receive(deviceToken: Data([7, 7]))
        await home.processInbox()
        #expect(await push.registrations == [.init(deviceToken: Data([7, 7]), kind: .alert, flightId: nil)])
    }

    @Test func theDebugPayloadRunsTheTapHandler() async throws {
        let (home, _, _, _) = try await home()
        let flight = try #require(home.followed.first)
        let d = UserDefaults(suiteName: "PushTests.\(UUID().uuidString)")!
        d.set(flight.id.uuidString, forKey: "pushFlight")
        await home.applyPushLaunchArguments(d)
        #expect(home.shell.path == [.flight(flight.id)])
    }

    // MARK: Review round 1

    @Test func signingOutAndBackInAsTheSameAccountRegistersAgain() async {
        let push = FakePushService()
        let c = coordinator(Authorizer(.authorized), push: push, asks: Counter())
        let a = UUID(), token = Data([1, 2, 3])
        c.accountChanged(owner: a)
        await c.register(token: token)
        c.accountChanged(owner: nil)
        c.accountChanged(owner: a)
        await c.register(token: token)
        #expect(await push.registrations.count == 2)
    }

    @Test func homeModelForgetsTheAccountAtSignOut() async throws {
        let (home, inbox, push, _) = try await home()
        inbox.receive(deviceToken: Data([4]))
        await home.processInbox()
        #expect(await push.registrations.count == 1)
        // The signed-out state reaches the coordinator even though nothing is processed while signed out.
        home.userChanged()
        await home.processInbox()
        #expect(await push.registrations.count == 1)
    }

    @Test func aDisabledCoordinatorNeverPrompts() async {
        let auth = Authorizer(.notDetermined), asks = Counter()
        let c = PushCoordinator(push: FakePushService(), authorizer: auth, enabled: false) { asks.count += 1 }
        await c.didFollow()
        await c.refresh()
        #expect(auth.prompts == 0)
        #expect(asks.count == 0)
    }

    @Test func aTokenArrivingAfterStartIsRegisteredThroughTheSerialPath() async throws {
        let (home, inbox, push, _) = try await home()
        await home.start()
        let before = home.pushSerial
        inbox.receive(deviceToken: Data([5]))
        #expect(home.pushSerial == before + 1)
        await home.processInbox()
        #expect(await push.registrations.contains { $0.deviceToken == Data([5]) })
    }

    @Test func aTapThatCouldNotBeFetchedForNowIsKept() async throws {
        let (home, inbox, _, _) = try await home()
        let followed = Set(home.followed.map(\.id))
        let other = try #require(try await home.env.flights.lookup(.airport("KAUS")).first { !followed.contains($0.id) })
        let flights = try #require(home.env.flights as? FakeFlightService)
        await flights.setNextError(.offline)
        inbox.receiveTap(["flightId": other.id.uuidString])
        await home.processInbox()
        #expect(home.shell.path.isEmpty)
        #expect(inbox.pendingFlight == other.id)
        await home.processInbox()
        #expect(home.shell.path == [.flight(other.id)])
    }

    // MARK: Sign-out cap

    @Test func waitingStopsAtTheLimitWhenTheOperationHangs() async {
        let started = ContinuousClock.now
        let cancelled = Mutex(false)
        await waitingAtMost(.milliseconds(150)) {
            do { try await Task.sleep(for: .seconds(30)) } catch { cancelled.withLock { $0 = true } }
        }
        #expect(ContinuousClock.now - started < .seconds(5))
        // The loser is cancelled.
        try? await Task.sleep(for: .milliseconds(200))
        #expect(cancelled.withLock { $0 })
    }

    @Test func waitingReturnsAtOnceWhenTheOperationIsQuick() async {
        let started = ContinuousClock.now
        await waitingAtMost(.seconds(30)) {}
        #expect(ContinuousClock.now - started < .seconds(5))
    }
}
