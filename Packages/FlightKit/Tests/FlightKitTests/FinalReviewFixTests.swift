import Foundation
import Testing
@testable import FlightKit

@MainActor private func eventually(_ cond: () -> Bool) async {
    for _ in 0..<300 where !cond() { try? await Task.sleep(for: .milliseconds(10)) }
}

/// Final whole-branch review: one test group per finding.
@Suite @MainActor struct FinalReviewFixTests {
    let now = Date(timeIntervalSince1970: 1_792_770_120) // 2026-10-23T15:42:00Z

    // MARK: 1. The Live Activity ends at sign-out and deletion, with no home view on screen

    /// A signed-in home with a running activity, driven only through the session: no view modifier and
    /// no direct `userChanged()` call, as when SignInGate has swapped the home for Sign In.
    private func signedInHome() async throws -> (HomeModel, FakeActivityHost) {
        let base = try await AppEnvironment.fake(now: now)
        let env = AppEnvironment(flights: base.flights, airports: base.airports, auth: FakeAuthService(),
                                 history: base.history, push: base.push, cache: base.cache, requiresSignIn: true)
        let home = HomeModel(env: env)
        let host = FakeActivityHost()
        home.attachLiveActivities(FlightActivityController(host: host, push: env.push, lookup: env.lookup,
                                                           now: { [now] in now }))
        home.session.startIfNeeded()
        await eventually { home.session.isResolved }
        await home.session.signInWithApple(idToken: "token", nonce: "nonce")
        await eventually { home.owner != nil }
        await home.start()
        await eventually { !host.running().isEmpty }
        return (home, host)
    }

    @Test func signingOutEndsTheActivityThroughTheModel() async throws {
        let (home, host) = try await signedInHome()
        #expect(!host.running().isEmpty)
        await home.session.signOut()
        await eventually { home.needsSignIn } // the session ends through the auth stream
        #expect(home.needsSignIn) // the gate now shows Sign In: the home view is gone
        await eventually { host.running().isEmpty }
        #expect(host.running().isEmpty)
    }

    @Test func deletingTheAccountEndsTheActivityThroughTheModel() async throws {
        let (home, host) = try await signedInHome()
        #expect(await home.session.deleteAccount())
        #expect(home.needsSignIn)
        await eventually { host.running().isEmpty }
        #expect(host.running().isEmpty)
    }

    @Test func aSignedOutLaunchEndsALeftoverActivityWithoutTheHome() async throws {
        let base = try await AppEnvironment.fake(now: now)
        let env = AppEnvironment(flights: base.flights, airports: base.airports, auth: base.auth, history: base.history,
                                 push: base.push, cache: base.cache, requiresSignIn: true)
        let home = HomeModel(env: env)
        let host = FakeActivityHost()
        let f = try #require(try await env.flights.followed().first)
        host.seed(.init(id: "left", flightId: f.id, ownerId: UUID(), state: .from(f, now: now)))
        home.attachLiveActivities(FlightActivityController(host: host, push: env.push, lookup: env.lookup,
                                                           now: { [now] in now }))
        // What SignInGate does; the home itself never starts (Sign In is on screen).
        home.session.startIfNeeded()
        await eventually { home.needsSignIn && host.running().isEmpty }
        #expect(home.needsSignIn)
        #expect(host.running().isEmpty)
    }

    // MARK: 2. Live position

    @Test func aFollowedFlightInTheAirAsksForItsPositionAndShowsAPlane() async throws {
        let svc = FakeFlightService(now: now)
        let f = try #require(try await svc.followed().first { $0.status == .enRoute || $0.status == .departed })
        let store = FlightDetailStore(id: f.id, flights: svc, airports: FakeAirportService(now: now))
        await store.load()
        await store.refreshPosition()
        #expect(await svc.positionRequests == [f.id])
        let shown = try #require(store.flight)
        #expect(FlightAnnotationModel(flight: shown) != nil)
    }

    @Test func noPositionRequestOnTheGroundOrWhenNotFollowed() async throws {
        let svc = FakeFlightService(now: now)
        let ground = try #require(try await svc.followed().first { $0.status == .scheduled })
        let store = FlightDetailStore(id: ground.id, flights: svc, airports: FakeAirportService(now: now))
        await store.load()
        await store.refreshPosition()
        let air = try #require(try await svc.followed().first { $0.status == .enRoute })
        try await svc.unfollow(air.id)
        let notFollowed = FlightDetailStore(id: air.id, flights: svc, airports: FakeAirportService(now: now))
        await notFollowed.load()
        await notFollowed.refreshPosition()
        #expect(await svc.positionRequests.isEmpty)
    }

    @Test func positionColumnsDecodeIntoAPlane() throws {
        let json = #"""
        {"flight": {"id": "8b0b0a39-8f37-4d73-9d0a-5f1f0d2b0c11", "provider_id": "AFR7-1-schedule-1p", "ident": "AF7",
          "origin_icao": "KJFK", "destination_icao": "LFPG", "status": "en_route",
          "position_lat": 48.5, "position_lon": -30.25, "position_altitude_ft": 37000,
          "position_ground_speed_kt": 480, "position_heading": 265,
          "position_at": "2026-11-03T16:00:00+00:00", "updated_at": "2026-11-03T16:00:01.123456+00:00"}}
        """#
        let f = try SupabaseFlightService.decodePosition(Data(json.utf8))
        let plane = try #require(FlightAnnotationModel(flight: f))
        #expect(plane.latitude == 48.5 && plane.longitude == -30.25 && plane.heading == 265)
        let globe = GlobeContent.followed([f], lookup: { _ in nil })
        #expect(globe.planes.map(\.id) == [f.id])
    }

    // MARK: 3. Event payload contract

    static let eventsContract = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // FlightKitTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // FlightKit
        .deletingLastPathComponent() // Packages
        .deletingLastPathComponent() // repository root
        .appending(path: "supabase/functions/aeroapi-webhook/contract/events.json")

    @Test func theBackendsEventPayloadsReadAsTheTimelineExpects() throws {
        let events = try FlightJSON.decoder.decode([FlightEvent].self, from: Data(contentsOf: Self.eventsContract))
        let byKind = Dictionary(grouping: events, by: \.kind)
        let gate = try #require(byKind[.gateChange]?.first)
        #expect(gate.payload["gate"] == "K42")
        #expect(DetailFacts.eventText(gate) == "Gate changed to K42")
        let delay = try #require(byKind[.delay]?.first)
        #expect(delay.payload["minutes"] == "40")
        #expect(DetailFacts.eventText(delay) == "Delayed by \(Format.minutes(40))")
        let diversion = try #require(byKind[.diversion]?.first)
        #expect(diversion.payload["destination"] == "KOAK")
        #expect(DetailFacts.eventText(diversion) == "Diverted to KOAK")
        #expect(byKind[.cancel]?.isEmpty == false)
    }

    @Test func theFakesWriteTheBackendsKeys() async throws {
        let svc = FakeFlightService(now: now)
        let keys = Set(["gate", "minutes", "destination"])
        for f in try await svc.followed() {
            for e in try await svc.events(f.id) {
                #expect(Set(e.payload.keys).isSubset(of: keys), "\(e.kind): \(e.payload.keys)")
            }
        }
    }

    // MARK: 7. One bad row does not fail a search

    @Test func aLookupKeepsTheRowsItCanRead() throws {
        let json = #"""
        {"flights": [
          {"id": "8b0b0a39-8f37-4d73-9d0a-5f1f0d2b0c11", "provider_id": "AFR7-1", "ident": "AF7",
           "origin_icao": "KJFK", "destination_icao": "LFPG", "status": "scheduled",
           "updated_at": "2026-11-03T16:00:00+00:00"},
          {"id": "8b0b0a39-8f37-4d73-9d0a-5f1f0d2b0c12", "provider_id": "AFR7-2", "ident": "AF7",
           "origin_icao": null, "destination_icao": "LFPG", "status": "scheduled",
           "updated_at": "2026-11-03T16:00:00+00:00"}
        ]}
        """#
        let flights = try SupabaseFlightService.decodeLookup(Data(json.utf8))
        #expect(flights.map(\.providerId) == ["AFR7-1"])
    }

    @Test func myFlightsKeepTheRowsItCanRead() throws {
        let json = #"""
        [{"created_at": "2026-11-01T10:00:00+00:00", "flights": {"id": "8b0b0a39-8f37-4d73-9d0a-5f1f0d2b0c11",
           "provider_id": "AFR7-1", "ident": "AF7", "origin_icao": "KJFK", "destination_icao": "LFPG",
           "status": "scheduled", "updated_at": "2026-11-03T16:00:00+00:00"}},
         {"created_at": "2026-11-01T11:00:00+00:00", "flights": {"id": "8b0b0a39-8f37-4d73-9d0a-5f1f0d2b0c12",
           "provider_id": "AFR7-2", "ident": "AF7", "origin_icao": "KJFK", "destination_icao": null,
           "status": "scheduled", "updated_at": "2026-11-03T16:00:00+00:00"}}]
        """#
        #expect(try SupabaseFlightService.decodeFollowed(Data(json.utf8)).map(\.providerId) == ["AFR7-1"])
    }

    // MARK: 8. out_of_window

    @Test func outOfWindowHasItsOwnErrorAndMessage() {
        #expect(APIError(code: "out_of_window") == .outOfWindow)
        let body = Data(#"{"error":{"code":"out_of_window","message":"Date must be within 10 days back and 2 days ahead"}}"#.utf8)
        #expect(SupabaseBackend.functionError(status: 400, body: body) == .outOfWindow)
        #expect(APIError.outOfWindow.message.contains("10 days back"))
    }

    // MARK: 9. Search knows board rows already followed

    @Test func aBoardRowOfAFollowedFlightCountsAsFollowed() {
        let followed = Flight(providerId: "AFR84-1793600000-schedule-1p", ident: "AF84", originIcao: "LFPG",
                              destinationIcao: "KSFO")
        // The airport board's row: same provider id, its own (v5) id.
        var boardRow = followed
        boardRow.id = UUID()
        let other = Flight(providerId: "UAL1-1", ident: "UA1", originIcao: "KSFO", destinationIcao: "KAUS")
        let set = FollowedFlights([followed])
        #expect(set.contains(followed))
        #expect(set.contains(boardRow))
        #expect(!set.contains(other))
    }
}
