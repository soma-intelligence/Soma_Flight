import CoreLocation
import Foundation
import MapKit
import Synchronization
import SwiftUI
import Testing
@testable import FlightKit

/// Task 7 re-review: failed hand-over, owner-scoped reads, generation, owner record, camera ladder.
@Suite @MainActor struct ShellReviewRound2Tests {
    private let userA = UUID(uuidString: "5a1e0000-0000-4000-8000-000000000002")!  // FakeAuth email sign-in
    private let userB = UUID(uuidString: "5a1e0000-0000-4000-8000-000000000001")!  // FakeAuth Apple sign-in

    private func waitUntil(_ condition: () async -> Bool) async throws {
        for _ in 0..<200 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("condition not met in 2 s")
    }

    private struct WipeFailed: Error {}

    // MARK: N1

    @Test func aFailedWipeKeepsTheNewAccountOutUntilItSucceeds() async throws {
        let env = try await AppEnvironment.fake()
        let failuresLeft = Mutex(0)
        let seen = Mutex<[UUID?]>([])
        let session = SessionStore(auth: env.auth, onUserChange: { user in
            if user != nil, failuresLeft.withLock({ n in defer { n = max(0, n - 1) }; return n > 0 }) { throw WipeFailed() }
            try await env.adopt(user: user)
        }, retryDelays: [.milliseconds(30), .milliseconds(30), .milliseconds(30)])
        session.start()
        try await env.auth.signInWithEmail("a@example.com")
        try await waitUntil { session.session?.userId == userA }
        await env.makeMyFlightsStore(owner: userA).load()
        #expect(!(await env.cache.flights()).isEmpty)

        failuresLeft.withLock { $0 = 2 }
        try await env.auth.signInWithApple(idToken: "t", nonce: "n")
        // The wipe failed: nobody is shown, never B over A's data, and the error is up.
        try await waitUntil { session.error == .localData }
        seen.withLock { $0.append(session.session?.userId) }
        #expect(session.session == nil)
        #expect(await env.cache.owner() == userA)
        // B's stores, were any built now, would read nothing of A's.
        #expect(await env.cache.scoped(for: userB).flights().isEmpty)
        // The retries get through: B shows once the cache is B's.
        try await waitUntil { session.session?.userId == userB }
        #expect(session.error == nil)
        #expect(await env.cache.owner() == userB)
        #expect(await env.cache.flights().isEmpty)
        #expect(seen.withLock { $0 } == [nil])
    }

    @Test func scopedReadsAreEmptyForAnotherOwner() async throws {
        let env = try await AppEnvironment.fake()
        try await env.adopt(user: userA)
        let list = env.makeMyFlightsStore(owner: userA)
        await list.load()
        let flight = try #require(list.live.first ?? list.upcoming.first)
        let other = env.cache.scoped(for: userB)
        #expect(await other.flights().isEmpty)
        #expect(await other.past().isEmpty)
        #expect(await other.flightsSavedAt() == nil)
        await other.save(flights: [])
        #expect(!(await env.cache.flights()).isEmpty)

        // Offline, the detail screen of another account does not find A's flight in the cache.
        let service = try #require(env.flights as? FakeFlightService)
        await service.setNextError(.offline)
        let foreign = env.makeFlightDetailStore(id: flight.id, owner: userB)
        await foreign.load()
        #expect(foreign.flight == nil)
        await service.setNextError(.offline)
        let own = env.makeFlightDetailStore(id: flight.id, owner: userA)
        await own.load()
        #expect(own.flight?.id == flight.id)
    }

    // MARK: N2

    @Test func noWipeLeavesOpenScopesWorking() async throws {
        let cache = try CacheStore.inMemory()
        try await cache.claim(for: userA)
        let scope = cache.scoped(for: userA)
        // Same owner: no wipe, so the generation stays and the scope still writes.
        #expect(try await !cache.claim(for: userA))
        await scope.save(flights: try await FakeFlightService().followed())
        #expect(!(await cache.flights()).isEmpty)
        // A real wipe closes it.
        try await cache.claim(for: userB)
        await scope.save(flights: try await FakeFlightService().followed())
        #expect(await cache.flights().isEmpty)
    }

    // MARK: N5

    @Test func anUnreadableOwnerRecordBelongsToNobody() async throws {
        let env = try await AppEnvironment.fake()
        await env.cache.save(flights: try await FakeFlightService().followed())
        await env.cache.setOwnerRecord("not-a-uuid")
        #expect(await env.cache.owner() == nil)
        #expect(await !env.cache.isOwned(by: nil))
        // adopt and claim agree: handing it to nobody wipes it.
        try await env.adopt(user: nil)
        #expect(await env.cache.flights().isEmpty)
        #expect(await env.cache.isOwned(by: nil))
    }

    // MARK: N3

    private func route(_ a: (Double, Double), _ b: (Double, Double)) -> Route {
        Route(from: CLLocationCoordinate2D(latitude: a.0, longitude: a.1),
              to: CLLocationCoordinate2D(latitude: b.0, longitude: b.1), level: .onTime, isPast: false)
    }

    private func expectBothEndsFit(_ r: Route, in vp: GlobeViewport = .phone) throws -> MapCamera {
        let cam = GlobeMap.camera(for: .route(r), in: vp)
        let box = GlobeMap.fitBox(vp)
        for end in [r.from, r.to] {
            let p = try #require(GlobeMap.project(end, camera: cam, in: vp))
            #expect(box.contains(p))
        }
        #expect(GlobeMap.overflow([r.from] + r.runs.flatMap { $0 } + [r.to], camera: cam, in: vp) == 0)
        #expect(cam.distance <= GlobeMap.maximumDistance(at: cam.centerCoordinate.latitude))
        return cam
    }

    @Test func southernLongHaulsFitAndLookFromTheEquatorSide() throws {
        let syd = (-33.95, 151.18), scl = (-33.39, -70.79), jnb = (-26.14, 28.24), per = (-31.94, 115.97)
        for r in [route(syd, scl), route(jnb, per)] {
            let cam = try expectBothEndsFit(r)
            let mid = try #require(GlobeMap.sphericalMean([r.from] + r.runs.flatMap { $0 } + [r.to]))
            // Never further toward the pole than the arc's middle.
            #expect(cam.centerCoordinate.latitude >= mid.latitude - 1e-6)
        }
    }

    @Test func candidateCentersStepTowardTheEquator() {
        let north = GlobeMap.candidateCenters(around: CLLocationCoordinate2D(latitude: 60, longitude: 0))
        let south = GlobeMap.candidateCenters(around: CLLocationCoordinate2D(latitude: -60, longitude: 0))
        #expect(north.map(\.latitude).min()! < 60 && north.map(\.latitude).max()! <= 60 + 1e-6)
        #expect(south.map(\.latitude).max()! > -60 && south.map(\.latitude).min()! >= -60 - 1e-6)
    }

    @Test func antimeridianTransPacificFits() throws {
        let cam = try expectBothEndsFit(route((33.94, -118.41), (-33.95, 151.18)))
        #expect(abs(cam.centerCoordinate.longitude) > 150)
    }

    @Test func veryShortRouteSitsInTheMiddleAtTheClosestDistance() throws {
        let r = route((40.64, -73.78), (40.78, -73.87))
        let cam = try expectBothEndsFit(r)
        #expect(cam.distance == GlobeMap.minimumRouteDistance)
        #expect(abs(cam.centerCoordinate.latitude - 40.71) < 0.05)
    }

    @Test func whenNothingFitsTheLeastOverflowingCameraIsKept() throws {
        // A sliver of a map: nothing can hold Sydney to Santiago.
        let vp = GlobeViewport(size: CGSize(width: 120, height: 495), visible: CGRect(x: 0, y: 62, width: 120, height: 389))
        let r = route((-33.95, 151.18), (-33.39, -70.79))
        let pts = [r.from] + r.runs.flatMap { $0 } + [r.to]
        let cam = GlobeMap.camera(for: .route(r), in: vp)
        let worst = GlobeMap.candidateCenters(around: try #require(GlobeMap.sphericalMean(pts))).map {
            GlobeMap.overflow(pts, camera: MapCamera(centerCoordinate: $0, distance: GlobeMap.maximumDistance(at: $0.latitude, in: vp),
                                                     heading: 0, pitch: 0), in: vp)
        }
        #expect(GlobeMap.overflow(pts, camera: cam, in: vp) == worst.min())
        #expect(GlobeMap.overflow(pts, camera: cam, in: vp) > 0)
    }
}
