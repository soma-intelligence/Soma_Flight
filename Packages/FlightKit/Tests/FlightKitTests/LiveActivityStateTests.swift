import Foundation
import SwiftUI
import Testing
@testable import FlightKit

/// Task 11: the Live Activity state (backend content-state compatibility), the start and end rules,
/// token registration and the palette.
@Suite @MainActor struct LiveActivityStateTests {
    typealias State = FlightActivityAttributes.ContentState

    let now = Date(timeIntervalSince1970: 1_792_770_120) // 2026-10-23T15:42:00Z

    func flight(_ ident: String = "UA1527", status: FlightStatus = .scheduled, outIn hours: Double = 2,
                duration: Double = 3, gate: String? = "F11", id: UUID = UUID()) -> Flight {
        let out = now.addingTimeInterval(hours * 3600)
        return Flight(id: id, providerId: ident, ident: ident, originIcao: "KSFO", originIata: "SFO",
                      destinationIcao: "KAUS", destinationIata: "AUS",
                      scheduledOut: out, scheduledIn: out.addingTimeInterval(duration * 3600),
                      gateOrigin: gate, gateDestination: "B4", status: status, updatedAt: now)
    }

    func json(_ s: String) throws -> State { try JSONDecoder().decode(State.self, from: Data(s.utf8)) }

    // MARK: Content state

    @Test func contentStateFromFlight() {
        var f = flight()
        f.estimatedOut = f.scheduledOut!.addingTimeInterval(25 * 60)
        let s = State.from(f, now: now)
        #expect(s.status == .scheduled)
        #expect(s.gateOrigin == "F11")
        #expect(s.gateDestination == "B4")
        #expect(s.estimatedOut == f.estimatedOut)
        #expect(s.estimatedIn == f.scheduledIn) // no estimate: the schedule, as the backend sends
        #expect(s.progress == 0)
    }

    @Test func progressMatchesTheBackend() {
        var f = flight(status: .enRoute, outIn: -1, duration: 4)
        #expect(State.from(f, now: now).progress == 0.25)
        f.status = .landed
        #expect(State.from(f, now: now).progress == 1)
        f.status = .unknown
        #expect(State.from(f, now: now).progress == 0)
    }

    @Test func contentStateJSONKeys() throws {
        let s = State(status: .enRoute, gateOrigin: nil, gateDestination: "B4",
                      estimatedOut: Date(timeIntervalSince1970: 1_792_770_120), estimatedIn: nil, progress: 0.5)
        let obj = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(s)) as? [String: Any])
        #expect(Set(obj.keys) == ["status", "gateOrigin", "gateDestination", "estimatedOut", "estimatedIn", "progress"])
        #expect(obj["status"] as? String == "en_route")
        #expect(obj["gateOrigin"] is NSNull)
        #expect(obj["estimatedOut"] as? String == "2026-10-23T15:42:00Z")
        #expect(obj["estimatedIn"] is NSNull)
        #expect(obj["progress"] as? Double == 0.5)
    }

    @Test func canceledState() throws {
        let f = flight(status: .canceled)
        let s = State.from(f, now: now)
        #expect(s.status == .canceled)
        #expect(s.isFinal)
        let back = try JSONDecoder().decode(State.self, from: JSONEncoder().encode(s))
        #expect(back.status == .canceled)
        #expect(FlightActivityDisplay(.from(f, lookup: { _ in nil }), s).statusText == "Canceled")
    }

    @Test func decodesWhatPushSenderSends() throws {
        let s = try json("""
        {"status":"en_route","gateOrigin":"F11","gateDestination":null,
         "estimatedOut":"2026-10-23T15:42:00+00:00","estimatedIn":"2026-10-23T19:12:30.250-05:00","progress":0.412}
        """)
        #expect(s.status == .enRoute)
        #expect(s.gateOrigin == "F11" && s.gateDestination == nil)
        #expect(s.estimatedOut == now)
        #expect(s.estimatedIn == Date(timeIntervalSince1970: 1_792_800_750.25))
        #expect(s.progress == 0.412)
    }

    @Test func isoWithAndWithoutFractions() {
        #expect(ISODate.parse("2026-10-23T15:42:00Z") == now)
        #expect(ISODate.parse("2026-10-23T15:42:00.000Z") == now)
        #expect(ISODate.parse("2026-10-23 15:42:00+00:00") == now)
        let micro = ISODate.parse("2026-10-23T15:42:00.123456+00:00")
        #expect(abs((micro?.timeIntervalSince(now) ?? 0) - 0.123456) < 0.000_001)
        #expect(ISODate.parse("yesterday") == nil)
        #expect(ISODate.parse("2026-10-23T15:42:00.Z") == nil)
    }

    @Test func unknownValuesNeverFailTheDecode() throws {
        let s = try json(#"{"status":"boarding","estimatedOut":"soon","progress":7}"#)
        #expect(s.status == .unknown)
        #expect(s.estimatedOut == nil && s.estimatedIn == nil)
        #expect(s.progress == 1)
        #expect(try json("{}") == State(status: .unknown))
        #expect(try json(#"{"status":12,"gateOrigin":4}"#).status == .unknown)
    }

    @Test func appAndPushedStatesRoundTrip() throws {
        for date in [now, now.addingTimeInterval(0.5)] {
            let s = State(status: .departed, gateOrigin: "A1", gateDestination: "B2",
                          estimatedOut: date, estimatedIn: date.addingTimeInterval(3600), progress: 0.1)
            let data = try JSONEncoder().encode(s)
            #expect(try JSONDecoder().decode(State.self, from: data) == s)
        }
    }

    // MARK: Display

    @Test func displayFollowsTheFlightCard() {
        var f = flight()
        f.estimatedOut = f.scheduledOut!.addingTimeInterval(50 * 60)
        let attrs = FlightActivityAttributes.from(f) { $0 == "KSFO" ? PreviewData.airport("KSFO") : nil }
        let d = FlightActivityDisplay(attrs, .from(f, now: now))
        #expect(d.level == .veryLate)
        #expect(d.statusText == "50m Late")
        #expect(d.ident == "UA 1527")
        #expect(d.originGate == "Gate F11")
        #expect(d.scheduledDeparture != nil)
        #expect(attrs.originTimeZone == PreviewData.airport("KSFO")?.tz)
        #expect(d.compactTime == d.departureTime)
    }

    @Test func paletteMatchesTheTheme() {
        var env = EnvironmentValues()
        env.colorScheme = .dark
        let pairs: [(Color, Color)] = [
            (ActivityPalette.background, Theme.background), (ActivityPalette.primary, Theme.primary),
            (ActivityPalette.secondary, Theme.secondary), (ActivityPalette.track, Theme.grid),
        ] + DelayLevel.allCases.map { (ActivityPalette.color($0), $0.color) }
        for (a, b) in pairs {
            let x = a.resolve(in: env), y = b.resolve(in: env)
            #expect(abs(x.red - y.red) < 0.01 && abs(x.green - y.green) < 0.01 && abs(x.blue - y.blue) < 0.01)
        }
    }

    // MARK: Controller

    /// Adopts "no account" (the fakes) so the rules run, as the home does after start.
    func controller(_ host: FakeActivityHost, _ push: FakePushService = FakePushService(),
                    clock: TestClock? = nil, owner: UUID? = nil) async -> FlightActivityController {
        let t = clock ?? TestClock(now)
        let c = FlightActivityController(host: host, push: push, lookup: { _ in nil }, now: { t.now })
        await c.adopt(owner: owner)
        return c
    }

    @Test func startsForTheNextFlightWithinFourHours() async {
        let host = FakeActivityHost()
        let c = await controller(host)
        let soon = flight("AA1", outIn: 3.5), later = flight("AA2", outIn: 3.9), far = flight("AA3", outIn: 5)
        await c.sync([far, later, soon])
        #expect(host.started.map(\.ident) == ["AA1"])
        await c.sync([far, later, soon])
        #expect(host.started.count == 1) // one at a time
    }

    @Test func nothingStartsBeyondFourHoursOrWhenDisabled() async {
        let host = FakeActivityHost()
        await controller(host).sync([flight(outIn: 4.1), flight(status: .canceled, outIn: 1),
                                     flight(outIn: -3)])
        #expect(host.started.isEmpty)
        host.enabled = false
        await controller(host).sync([flight(outIn: 1)])
        #expect(host.started.isEmpty)
    }

    @Test func aFlightInTheAirComesFirst() async {
        let host = FakeActivityHost()
        await controller(host).sync([flight("AA1", outIn: 1), flight("AF84", status: .enRoute, outIn: -4, duration: 11)])
        #expect(host.started.map(\.ident) == ["AF84"])
    }

    @Test func updatesThenEndsOnArrival() async throws {
        let host = FakeActivityHost()
        let c = await controller(host)
        var f = flight(outIn: 1)
        await c.sync([f])
        f.gateOrigin = "F12"
        await c.sync([f])
        #expect(host.updates.last?.gateOrigin == "F12")
        f.status = .arrived
        await c.sync([f])
        let end = try #require(host.ends.last)
        #expect(end.state?.status == .arrived)
        #expect(end.dismissAt == now.addingTimeInterval(1800))
        #expect(host.running().isEmpty)
    }

    @Test func endsOnCancelLocallyWithAnHour() async throws {
        let host = FakeActivityHost()
        let c = await controller(host)
        var f = flight(outIn: 1)
        await c.sync([f])
        f.status = .canceled
        await c.sync([f])
        let end = try #require(host.ends.last)
        #expect(end.state?.status == .canceled)
        #expect(end.dismissAt == now.addingTimeInterval(3600))
    }

    @Test func unfollowAndSignOutEndAtOnce() async throws {
        let host = FakeActivityHost()
        let c = await controller(host)
        let a = flight("AA1", outIn: 1), b = flight("AA2", outIn: 2)
        await c.sync([a, b])
        await c.sync([b]) // AA1 unfollowed: ended, AA2 takes over
        #expect(host.ends.first?.dismissAt == nil && host.ends.first?.state == nil)
        #expect(host.started.map(\.ident) == ["AA1", "AA2"])
        await c.endAll()
        #expect(host.running().isEmpty)
        #expect(host.ends.last?.dismissAt == nil)
    }

    @Test func pushTokensRegisterAsLiveActivity() async {
        let host = FakeActivityHost()
        let push = FakePushService()
        let c = await controller(host, push)
        let f = flight(outIn: 1)
        await c.sync([f])
        await push.setNextError(.offline)
        await host.emitToken(Data([1, 2]), for: f.id)
        #expect(await push.registrations.isEmpty)
        await c.sync([f]) // retried
        await host.emitToken(Data([3, 4]), for: f.id) // a new token
        let regs = await push.registrations
        #expect(regs == [.init(deviceToken: Data([1, 2]), kind: .liveActivity, flightId: f.id),
                         .init(deviceToken: Data([3, 4]), kind: .liveActivity, flightId: f.id)])
    }

    @Test func theDebugPushActsLikeAnActivityKitPush() async throws {
        let host = FakeActivityHost()
        let c = await controller(host)
        await c.sync([flight(outIn: 1)])
        let update = #"{"aps":{"timestamp":1,"event":"update","content-state":{"status":"departed","gateOrigin":"F12","gateDestination":null,"estimatedOut":"2026-10-23T16:42:00+00:00","estimatedIn":null,"progress":0.05}}}"#
        #expect(await c.applyDebugPush(Data(update.utf8)))
        #expect(host.updates.last?.status == .departed)
        #expect(host.updates.last?.gateOrigin == "F12")
        let end = #"{"aps":{"timestamp":2,"event":"end","dismissal-date":1792773720,"content-state":{"status":"canceled","progress":0}}}"#
        #expect(await c.applyDebugPush(Data(end.utf8)))
        #expect(host.ends.last?.state?.status == .canceled)
        #expect(host.ends.last?.dismissAt == Date(timeIntervalSince1970: 1_792_773_720))
        #expect(await !c.applyDebugPush(Data("{}".utf8)))
    }

    // MARK: Review round 1

    @Test func anotherAccountsActivityEnds() async {
        let host = FakeActivityHost()
        let me = UUID(), them = UUID()
        let f = flight(outIn: 1)
        host.seed(.init(id: "old", flightId: f.id, ownerId: them, state: .from(f, now: now)))
        let c = await controller(host, owner: me)
        #expect(host.running().isEmpty) // ended on adopt
        await c.sync([f])
        #expect(host.started.map(\.ownerId) == [me]) // restarted for the account signed in
        await c.adopt(owner: them)
        #expect(host.running().isEmpty)
    }

    @Test func nothingStartsBeforeTheOwnerIsKnown() async {
        let host = FakeActivityHost()
        let c = FlightActivityController(host: host, push: FakePushService(), lookup: { _ in nil }, now: { [now] in now })
        await c.sync([flight(outIn: 1)])
        #expect(host.started.isEmpty)
        await c.adopt(owner: nil)
        await c.sync([flight(outIn: 1)])
        #expect(host.started.count == 1)
    }

    @Test func aSignedOutLaunchEndsTheActivity() async throws {
        let base = try await AppEnvironment.fake(now: now)
        let env = AppEnvironment(flights: base.flights, airports: base.airports, auth: base.auth, history: base.history,
                                 push: base.push, cache: base.cache, requiresSignIn: true)
        let home = HomeModel(env: env)
        let host = FakeActivityHost()
        let f = try #require(try await env.flights.followed().first)
        host.seed(.init(id: "left", flightId: f.id, ownerId: UUID(), state: .from(f, now: now)))
        home.attachLiveActivities(FlightActivityController(host: host, push: env.push, lookup: env.lookup, now: { [now] in now }))
        await home.start()
        for _ in 0..<200 where home.awaitingSession { try? await Task.sleep(for: .milliseconds(10)) }
        await home.reconcileActivities() // what the shell runs when the session resolves
        #expect(home.needsSignIn)
        #expect(host.running().isEmpty)
        #expect(host.started.isEmpty)
    }

    @Test func theFourHourLine() async {
        let host = FakeActivityHost()
        let clock = TestClock(now)
        let c = await controller(host, clock: clock)
        let f = flight(outIn: 4 + 1.0 / 60) // 4 h 1 min out
        await c.sync([f])
        #expect(host.started.isEmpty)
        #expect(c.wakeAt == f.scheduledOut!.addingTimeInterval(-4 * 3600))
        clock.now = now.addingTimeInterval(60) // exactly 4 h out
        await c.sync([f])
        #expect(host.started.count == 1)
        #expect(c.wakeAt == nil)
    }

    @Test func theStaleDepartureLine() {
        let inside = flight(outIn: -2 + 1.0 / 60), outside = flight(outIn: -2 - 1.0 / 60)
        #expect(FlightActivityController.canStart(inside, now: now))
        #expect(!FlightActivityController.canStart(outside, now: now))
    }

    @Test func theBestCandidateReplacesTheRunningOne() async {
        let host = FakeActivityHost()
        let c = await controller(host)
        let scheduled = flight("AA1", outIn: 3)
        var other = flight("AF84", outIn: 6, duration: 11)
        await c.sync([scheduled, other])
        #expect(host.started.map(\.ident) == ["AA1"])
        other.status = .enRoute // in the air beats scheduled
        await c.sync([scheduled, other])
        #expect(host.started.map(\.ident) == ["AA1", "AF84"])
        #expect(host.running().map(\.flightId) == [other.id])
        #expect(host.ends.last?.state == nil && host.ends.last?.dismissAt == nil)
    }

    @Test func aRelaunchReattaches() async {
        let host = FakeActivityHost()
        let a = flight("AA1", outIn: 1), b = flight("AA2", outIn: 2)
        host.seed(.init(id: "b", flightId: b.id, state: .from(b, now: now)))
        host.seed(.init(id: "a", flightId: a.id, state: .from(a, now: now)))
        let c = await controller(host)
        await c.sync([a, b])
        #expect(host.started.isEmpty) // the candidate's activity is kept
        #expect(host.running().map(\.id) == ["a"]) // the extra one ended
        #expect(host.updates.isEmpty) // nothing changed on the card
    }

    @Test func onlyRealChangesUpdate() async {
        let host = FakeActivityHost()
        let clock = TestClock(now)
        let c = await controller(host, clock: clock)
        let f = flight(status: .enRoute, outIn: -1, duration: 10)
        await c.sync([f])
        clock.now = now.addingTimeInterval(30) // progress moves by 0.0008
        await c.sync([f])
        #expect(host.updates.isEmpty)
        clock.now = now.addingTimeInterval(600)
        await c.sync([f])
        #expect(host.updates.count == 1)
    }

    @Test func aDivertedFlightEndsAfterSixHours() async throws {
        let host = FakeActivityHost()
        let clock = TestClock(now)
        let c = await controller(host, clock: clock)
        var f = flight(status: .enRoute, outIn: -2, duration: 3)
        await c.sync([f])
        f.status = .diverted
        await c.sync([f])
        #expect(host.running().count == 1)
        clock.now = f.scheduledIn!.addingTimeInterval(6 * 3600 + 60)
        await c.sync([f])
        #expect(host.running().isEmpty)
        #expect(host.ends.last?.state?.status == .diverted)
    }

    @Test func endAllForgetsPendingTokens() async {
        let host = FakeActivityHost()
        let push = FakePushService()
        let c = await controller(host, push)
        let f = flight(outIn: 1)
        await c.sync([f])
        await push.setNextError(.offline)
        await host.emitToken(Data([9]), for: f.id)
        #expect(c.pendingTokens.count == 1)
        await c.endAll()
        #expect(c.pendingTokens.isEmpty)
        #expect(host.running().isEmpty)
        await c.sync([f]) // signed out: nothing starts until an owner is adopted
        #expect(host.started.count == 1)
    }

    @Test func scheduledSyncsRunInOrder() async {
        let host = FakeActivityHost()
        let c = await controller(host)
        let f = flight(outIn: 1)
        c.scheduleSync([f])
        c.scheduleSync([]) // unfollowed right after
        await c.sync([])
        #expect(host.running().isEmpty)
        #expect(host.started.count == 1)
        c.scheduleSync([])
        c.scheduleSync([f])
        await c.adopt(owner: nil) // waits for the queue
        #expect(host.running().count == 1)
    }

    @Test func dayMarkAndStaleDate() {
        let out = Date(timeIntervalSince1970: 1_792_803_600) // 2026-10-24T01:00Z, 18:00 in San Francisco
        let attrs = FlightActivityAttributes(flightId: UUID(), ident: "AF83", originIata: "SFO", destinationIata: "CDG",
                                             originTimeZone: "America/Los_Angeles", destinationTimeZone: "Europe/Paris")
        let state = State(status: .enRoute, estimatedOut: out, estimatedIn: out.addingTimeInterval(10.5 * 3600))
        let d = FlightActivityDisplay(attrs, state)
        #expect(d.arrivalTime == "13:30")
        #expect(d.arrivalDayMark == "+1")
        #expect(d.spokenEnd(departure: false).hasPrefix("Arrives CDG 13:30 (+1 day)"))
        #expect(state.staleDate == out.addingTimeInterval(11.5 * 3600))
        var short = attrs
        short.destinationTimeZone = "America/Los_Angeles" // an hour in the same zone, same evening
        #expect(FlightActivityDisplay(short, State(status: .enRoute, estimatedOut: out, estimatedIn: out.addingTimeInterval(3600)))
            .arrivalDayMark == nil)
    }

    // MARK: Store and home wiring

    @Test func aFailedLoadLeavesTheActivityAlone() async {
        let service = FakeFlightService(now: now)
        let store = MyFlightsStore(flights: service)
        var calls = 0
        store.onListChange = { _ in calls += 1 }
        await store.load()
        #expect(calls == 1)
        await service.setNextError(.offline)
        await store.load()
        #expect(calls == 1)
        if let f = store.upcoming.first { await store.unfollow(f) }
        #expect(calls == 2)
    }

    @Test func theHomeStartsAndSignOutEnds() async throws {
        let env = try await AppEnvironment.fake(now: now)
        let home = HomeModel(env: env)
        let host = FakeActivityHost()
        home.attachLiveActivities(FlightActivityController(host: host, push: env.push, lookup: env.lookup, now: { [now] in now }))
        await home.start()
        await waitUntil { !host.started.isEmpty }
        #expect(host.started.first?.ident == "AF84") // the seed's flight in the air
        await home.activities?.endAll()
        #expect(host.running().isEmpty)
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<200 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
    }
}

/// Records what the controller asks ActivityKit for.
@MainActor final class FakeActivityHost: FlightActivityHost {
    struct End { var id: String; var state: FlightActivityAttributes.ContentState?; var dismissAt: Date? }
    var enabled = true
    var areActivitiesEnabled: Bool { enabled }
    var onPushToken: (@MainActor (Data, UUID) async -> Void)?
    private(set) var started: [FlightActivityAttributes] = []
    private(set) var updates: [FlightActivityAttributes.ContentState] = []
    private(set) var ends: [End] = []
    private var live: [RunningFlightActivity] = []

    func running() -> [RunningFlightActivity] { live }

    func start(attributes: FlightActivityAttributes, state: FlightActivityAttributes.ContentState) throws -> String {
        started.append(attributes)
        let id = "activity-\(started.count)"
        live.append(.init(id: id, flightId: attributes.flightId, ownerId: attributes.ownerId, state: state))
        return id
    }

    func update(id: String, state: FlightActivityAttributes.ContentState) async {
        updates.append(state)
        if let i = live.firstIndex(where: { $0.id == id }) { live[i].state = state }
    }

    func end(id: String, state: FlightActivityAttributes.ContentState?, dismissAt: Date?) async {
        ends.append(End(id: id, state: state, dismissAt: dismissAt))
        live.removeAll { $0.id == id }
    }

    func emitToken(_ token: Data, for flightId: UUID) async { await onPushToken?(token, flightId) }

    /// Activities left running by an earlier launch.
    func seed(_ activity: RunningFlightActivity) { live.append(activity) }
}

/// A clock the tests move by hand.
final class TestClock: @unchecked Sendable {
    var now: Date
    init(_ now: Date) { self.now = now }
}

#if os(macOS)
import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Renders the Live Activity's views into docs/screens/live-activity-*.png: `simctl io screenshot` does
/// not capture the lock screen (the simulator cannot be locked from the command line) nor the Dynamic
/// Island. The island shapes are drawn here as black capsules around the views, at the iPhone 17 Pro's
/// sizes. Off by default, like the other snapshots:
///
///     SNAPSHOTS=1 swift test --package-path Packages/FlightKit --filter LiveActivitySnapshotTests
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["SNAPSHOTS"] == "1"))
struct LiveActivitySnapshotTests {
    static let outDir: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "docs/screens")

    let now = Date(timeIntervalSince1970: 1_792_770_120)

    var enRoute: FlightActivityDisplay {
        let out = now.addingTimeInterval(-4.5 * 3600)
        let attrs = FlightActivityAttributes(flightId: UUID(), ident: "AF84", originIata: "CDG", destinationIata: "SFO",
                                             scheduledOut: out, scheduledIn: out.addingTimeInterval(11 * 3600),
                                             originTimeZone: "Europe/Paris", destinationTimeZone: "America/Los_Angeles")
        return FlightActivityDisplay(attrs, .init(status: .enRoute, gateOrigin: "K42", gateDestination: "A7",
                                                  estimatedOut: out.addingTimeInterval(15 * 60),
                                                  estimatedIn: out.addingTimeInterval(11 * 3600 + 20 * 60), progress: 0.41))
    }

    var lateDeparture: FlightActivityDisplay {
        let out = now.addingTimeInterval(3.6 * 3600)
        let attrs = FlightActivityAttributes(flightId: UUID(), ident: "UA1527", originIata: "SFO", destinationIata: "AUS",
                                             scheduledOut: out, scheduledIn: out.addingTimeInterval(3.6 * 3600),
                                             originTimeZone: "America/Los_Angeles", destinationTimeZone: "America/Chicago")
        return FlightActivityDisplay(attrs, .init(status: .scheduled, gateOrigin: "F11", gateDestination: nil,
                                                  estimatedOut: out.addingTimeInterval(50 * 60),
                                                  estimatedIn: out.addingTimeInterval(3.6 * 3600 + 45 * 60)))
    }

    func render<V: View>(_ name: String, width: CGFloat, @ViewBuilder _ content: () -> V) throws {
        let view = content().frame(width: width).padding(16).background(Color(white: 0.35))
            .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 3
        var image: CGImage?
        NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance { image = renderer.cgImage }
        let cg = try #require(image)
        try FileManager.default.createDirectory(at: Self.outDir, withIntermediateDirectories: true)
        let url = Self.outDir.appending(path: "live-activity-\(name).png")
        let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, cg, nil)
        #expect(CGImageDestinationFinalize(dest))
    }

    @Test func lockScreen() throws {
        try render("lockscreen", width: 370) {
            VStack(spacing: 12) {
                FlightActivityLockScreenView(enRoute)
                    .background(ActivityPalette.background, in: RoundedRectangle(cornerRadius: 22))
                FlightActivityLockScreenView(lateDeparture)
                    .background(ActivityPalette.background, in: RoundedRectangle(cornerRadius: 22))
            }
        }
    }

    @Test func dynamicIsland() throws {
        try render("island", width: 370) {
            VStack(spacing: 14) {
                // Compact: leading and trailing either side of the camera.
                HStack {
                    FlightActivityCompactLeading(enRoute)
                    Spacer()
                    FlightActivityCompactTrailing(enRoute)
                }
                .padding(.horizontal, 14).frame(width: 250, height: 37)
                .background(.black, in: Capsule())
                HStack {
                    FlightActivityCompactLeading(lateDeparture)
                    Spacer()
                    FlightActivityCompactTrailing(lateDeparture)
                }
                .padding(.horizontal, 14).frame(width: 250, height: 37)
                .background(.black, in: Capsule())
                // Minimal.
                FlightActivityMinimal(enRoute).frame(width: 37, height: 37).background(.black, in: Circle())
                // Expanded.
                VStack(spacing: 8) {
                    HStack(alignment: .top) {
                        FlightActivityExpandedEnd(code: "CDG", time: enRoute.departureTime, alignment: .leading)
                        Spacer()
                        FlightActivityExpandedCenter(enRoute)
                        Spacer()
                        FlightActivityExpandedEnd(code: "SFO", time: enRoute.arrivalTime, alignment: .trailing)
                    }
                    FlightActivityExpandedBottom(enRoute)
                }
                .padding(18)
                .background(.black, in: RoundedRectangle(cornerRadius: 44))
            }
        }
    }
}
#endif
