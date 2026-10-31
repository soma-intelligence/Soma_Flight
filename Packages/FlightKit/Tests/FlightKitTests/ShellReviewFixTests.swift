import CoreLocation
import Foundation
import MapKit
import Synchronization
import SwiftUI
import Testing
@testable import FlightKit

/// Task 7 review round 1: camera fit, account hand-over, cache wipe, shell navigation.
@Suite @MainActor struct ShellReviewFixTests {
    private let userA = UUID(uuidString: "5a1e0000-0000-4000-8000-000000000002")!  // FakeAuth email sign-in
    private let userB = UUID(uuidString: "5a1e0000-0000-4000-8000-000000000001")!  // FakeAuth Apple sign-in

    private func waitUntil(_ condition: () async -> Bool) async throws {
        for _ in 0..<200 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("condition not met in 2 s")
    }

    private func airport(_ id: String, _ lat: Double, _ lon: Double) -> Airport {
        Airport(id: id, name: id, city: id, country: "", lat: lat, lon: lon, tz: "UTC")
    }

    // MARK: Camera (finding 1)

    @Test func longHaulArcFitsAboveTheSheet() throws {
        let cdg = airport("LFPG", 49.0097, 2.5479), sfo = airport("KSFO", 37.6188, -122.3750)
        let route = Route(from: cdg.coordinate, to: sfo.coordinate, level: .late, isPast: false)
        let vp = GlobeViewport.phone
        let cam = GlobeMap.camera(for: .route(route), in: vp)
        let box = GlobeMap.fitBox(vp)
        // Both ends land inside the part of the map the sheet leaves visible, clear of the globe's rim.
        for end in [cdg.coordinate, sfo.coordinate] {
            let p = try #require(GlobeMap.project(end, camera: cam, in: vp))
            #expect(box.contains(p))
        }
        // And so does every point of the arc between them.
        #expect(GlobeMap.fits(route.runs.flatMap { $0 }, camera: cam, in: vp))
        // Within the distance MapKit accepts, so the camera it applies is the one computed here.
        #expect(cam.distance <= GlobeMap.maximumDistance(at: cam.centerCoordinate.latitude))
        // Tight: a camera 15% closer no longer holds it.
        let closer = MapCamera(centerCoordinate: cam.centerCoordinate, distance: cam.distance * 0.85, heading: cam.heading, pitch: 0)
        #expect(!GlobeMap.fits([cdg.coordinate, sfo.coordinate] + route.runs.flatMap { $0 }, camera: closer, in: vp))
    }

    @Test func arcThatFitsIsSeenFromAbove() {
        let cdg = airport("LFPG", 49.0, 2.5), jfk = airport("KJFK", 40.6, -73.8)
        let route = Route(from: cdg.coordinate, to: jfk.coordinate, level: .onTime, isPast: false)
        let cam = GlobeMap.camera(for: .route(route), in: .phone)
        #expect(cam.heading == 0)
        #expect(abs(cam.centerCoordinate.latitude - 51.5) < 3)
    }

    @Test func longHaulArcFitsAtEveryDetent() throws {
        let cdg = airport("LFPG", 49.0097, 2.5479), sfo = airport("KSFO", 37.6188, -122.3750)
        let route = Route(from: cdg.coordinate, to: sfo.coordinate, level: .late, isPast: false)
        // Collapsed: the full-screen map's visible area runs down to the sheet, 120 pt above the bottom.
        let collapsed = GlobeViewport(size: CGSize(width: 402, height: 874),
                                      visible: CGRect(x: 0, y: 62, width: 402, height: 874 - 120 - 62))
        for vp in [GlobeViewport.phone, collapsed] {
            let cam = GlobeMap.camera(for: .route(route), in: vp)
            let box = GlobeMap.fitBox(vp)
            for end in [cdg.coordinate, sfo.coordinate] {
                let p = try #require(GlobeMap.project(end, camera: cam, in: vp))
                #expect(box.contains(p))
            }
        }
    }

    @Test func arcAcrossTheAntimeridianCentresOverThePacific() throws {
        let sfo = airport("KSFO", 37.6, -122.4), hnd = airport("RJTT", 35.5, 139.8)
        let route = Route(from: sfo.coordinate, to: hnd.coordinate, level: .onTime, isPast: false)
        let cam = GlobeMap.camera(for: .route(route), in: .phone)
        #expect(abs(cam.centerCoordinate.longitude) > 150)
        #expect(GlobeMap.project(sfo.coordinate, camera: cam, in: .phone) != nil)
        #expect(GlobeMap.project(hnd.coordinate, camera: cam, in: .phone) != nil)
    }

    @Test func shortHopStaysClose() {
        let cdg = airport("LFPG", 49.0, 2.5), lhr = airport("EGLL", 51.47, -0.45)
        let route = Route(from: cdg.coordinate, to: lhr.coordinate, level: .onTime, isPast: false)
        let d = GlobeMap.camera(for: .route(route), in: .phone).distance
        #expect(d >= 1_200_000 && d < 3_000_000)
    }

    // MARK: Account hand-over (findings 2, 3, 8)

    @Test func claimWipesOnlyForAnotherUser() async throws {
        let cache = try CacheStore.inMemory()
        let flights = try await FakeFlightService().followed()
        // Data saved while nobody was signed in (the fakes before Task 9) goes at the first sign-in.
        await cache.save(flights: flights)
        #expect(try await cache.claim(for: userA))
        #expect(await cache.flights().isEmpty)
        #expect(await cache.owner() == userA)
        await cache.save(flights: flights)
        // Same user: kept.
        #expect(try await !cache.claim(for: userA))
        #expect(!(await cache.flights()).isEmpty)
        // Another user, with no sign-out in between: wiped.
        #expect(try await cache.claim(for: userB))
        #expect(await cache.flights().isEmpty)
        #expect(await cache.owner() == userB)
    }

    @Test func aScopeTakenBeforeAWipeCannotWriteAfterIt() async throws {
        let cache = try CacheStore.inMemory()
        let flights = try await FakeFlightService().followed()
        let stale = cache.scoped(for: userA)
        try await cache.claim(for: userA)
        // A load of the previous account finishing late.
        await stale.save(flights: flights)
        #expect(await cache.flights().isEmpty)
        await cache.scoped(for: userA).save(flights: flights)
        #expect(!(await cache.flights()).isEmpty)
    }

    @Test func storesBuiltBeforeASwitchCannotRefillTheCache() async throws {
        let env = try await AppEnvironment.fake()
        try await env.adopt(user: userA)
        let old = env.makeMyFlightsStore(owner: userA)
        try await env.adopt(user: userB)
        await old.load()
        #expect(await env.cache.flights().isEmpty)
    }

    @Test func switchingAccountsDirectlyWipesBeforeTheNewSessionShows() async throws {
        let env = try await AppEnvironment.fake()
        let session = env.makeSessionStore()
        session.start()
        try await env.auth.signInWithEmail("a@example.com")
        try await waitUntil { session.session?.userId == userA }
        await env.makeMyFlightsStore(owner: userA).load()
        #expect(!(await env.cache.flights()).isEmpty)
        // B signs in over A, no nil in between.
        try await env.auth.signInWithApple(idToken: "t", nonce: "n")
        try await waitUntil { session.session?.userId == userB }
        // Checked the moment B is published: the wipe already happened.
        #expect(await env.cache.flights().isEmpty)
        #expect(await env.cache.owner() == userB)
    }

    private struct WipeFailed: Error {}

    @Test func signOutWipesFirstAndStaysSignedInWhenTheWipeFails() async throws {
        let auth = FakeAuthService()
        let calls = Mutex<[UUID?]>([])
        let fail = Mutex(false)
        let session = SessionStore(auth: auth, onUserChange: { user in
            calls.withLock { $0.append(user) }
            if fail.withLock({ $0 }) { throw WipeFailed() }
        })
        session.start()
        try await auth.signInWithEmail("a@example.com")
        try await waitUntil { session.session != nil }

        fail.withLock { $0 = true }
        await session.signOut()
        #expect(session.error == .localData)
        // The server was never told: the account is still signed in, so nothing is left orphaned.
        try await Task.sleep(for: .milliseconds(50))
        #expect(session.session != nil)

        fail.withLock { $0 = false }
        await session.signOut()
        #expect(session.error == nil)
        try await waitUntil { session.session == nil }
        // The wipe for nobody ran before the auth call; the stream's nil hands over again (a no-op).
        #expect(calls.withLock { $0 } == [nil, userA, nil, nil, nil])
    }

    @Test func aFailedWipeFromTheStreamIsSurfaced() async throws {
        let auth = FakeAuthService()
        let session = SessionStore(auth: auth, onUserChange: { user in if user == nil { throw WipeFailed() } })
        session.start()
        try await auth.signInWithEmail("a@example.com")
        try await waitUntil { session.session != nil }
        await auth.signOut()
        try await waitUntil { session.session == nil }
        #expect(session.error == .localData)
    }

    @Test func recentsStorage() async throws {
        var env = try await AppEnvironment.fake()
        #expect(env.recentsDefaults == nil)
        env.recents = .standard
        #expect(env.recentsDefaults == .standard)
    }

    // MARK: Shell navigation (findings 4, 5, 6, 7)

    @Test func airportPinsBackAndForthNeverGrowTheStack() {
        let shell = ShellModel()
        let id = UUID()
        shell.open(flight: id, route: nil)
        for code in ["KAUS", "KSFO", "KAUS", "KSFO", "KAUS"] { shell.open(airport: code) }
        #expect(shell.path == [.flight(id), .airport("KAUS")])
        shell.open(airport: "KSFO")
        #expect(shell.path == [.flight(id), .airport("KAUS"), .airport("KSFO")])
    }

    @Test func reopeningTheShownScreenRecentres() {
        let shell = ShellModel()
        let id = UUID()
        shell.open(flight: id, route: nil)
        #expect(shell.recenter == 0)
        shell.open(flight: id, route: nil)
        #expect(shell.recenter == 1)
        #expect(shell.path == [.flight(id)])
        shell.open(airport: "KAUS")
        shell.open(airport: "KAUS")
        #expect(shell.recenter == 2)
        // A different flight replaces the stack.
        let other = UUID()
        shell.open(flight: other, route: nil)
        #expect(shell.path == [.flight(other)])
    }

    @Test func closePopsAndOpeningRaisesACollapsedSheet() {
        let shell = ShellModel()
        shell.detent = ShellModel.collapsed
        shell.open(airport: "KAUS")
        #expect(shell.detent == .medium)
        shell.detent = .large
        shell.open(airport: "KSFO")
        #expect(shell.detent == .large)
        shell.close()
        #expect(shell.path == [.airport("KAUS")])
        shell.close(); shell.close()
        #expect(shell.path.isEmpty)
    }

    @Test func focusHoldsTheArcOfAFlightThatLeftTheList() {
        let shell = ShellModel()
        let id = UUID()
        let aus = airport("KAUS", 30.19, -97.67)
        let route = Route(from: aus.coordinate, to: CLLocationCoordinate2D(latitude: 37.6, longitude: -122.4), level: .onTime, isPast: false)
        #expect(shell.focus(route: { _ in route }, airport: { _ in aus }) == nil)
        shell.open(flight: id, route: route)
        #expect(shell.focus(route: { _ in route }, airport: { _ in nil }) == .route(route))
        // The update dropped the flight: the camera stays on its arc while the detail is up.
        #expect(shell.focus(route: { _ in nil }, airport: { _ in nil }) == .route(route))
        shell.open(airport: "KAUS")
        #expect(shell.focus(route: { _ in nil }, airport: { _ in aus }) == .airport(aus))
        shell.reset()
        #expect(shell.path.isEmpty)
        shell.path = [.flight(id)]
        #expect(shell.focus(route: { _ in nil }, airport: { _ in nil }) == nil)
    }

    @Test func mapInsetFollowsTheSettledDetentCappedAtMedium() {
        #expect(ShellModel.mapInset(for: ShellModel.collapsed, screenHeight: 874) == 120)
        #expect(ShellModel.mapInset(for: .medium, screenHeight: 874) == 437)
        #expect(ShellModel.mapInset(for: .large, screenHeight: 874) == 437)
    }
}
