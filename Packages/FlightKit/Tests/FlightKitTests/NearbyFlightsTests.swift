import CoreLocation
import Foundation
@testable import FlightKit
import Testing

/// The nearby radar: the Info.plist switch, the backend's answer, the fake traffic and the store that
/// refreshes, follows and never asks for location.
@MainActor @Suite struct NearbyFlightsTests {
    nonisolated static let sfo = Airport(id: "KSFO", iata: "SFO", name: "San Francisco Intl", city: "San Francisco", country: "US",
                             lat: 37.62, lon: -122.38, tz: "America/Los_Angeles")
    nonisolated static let lookup: @Sendable (String) -> Airport? = { $0.uppercased() == "SFO" || $0.uppercased() == "KSFO" ? sfo : nil }

    /// A service that answers a list and counts the reads and the places asked about.
    final class Spy: NearbyFlightsService, @unchecked Sendable {
        var reads: [(Double, Double)] = []
        var answers: [[NearbyFlight]] = []
        var failure: APIError?
        var stale = false
        var isAvailable: Bool { true }
        func nearby(latitude: Double, longitude: Double, radiusKm: Double) async throws(APIError) -> NearbyFlightsResult {
            reads.append((latitude, longitude))
            if let failure { throw failure }
            let list = answers.isEmpty ? [] : answers.removeFirst()
            return NearbyFlightsResult(flights: list, fetchedAt: .now, stale: stale)
        }
    }

    static func plane(_ id: String, lat: Double = 37.7, lon: Double = -122.2, heading: Double? = 90) -> NearbyFlight {
        NearbyFlight(id: id, ident: id, latitude: lat, longitude: lon, altitudeFeet: 35_000, groundspeedKnots: 450,
                     heading: heading, origin: "SFO", destination: "LHR")
    }

    // MARK: Switch and contract

    @Test func radarIsOffUnlessInfoPlistSaysYes() {
        #expect(SupabaseNearbyFlightsService.isEnabled(raw: nil) == false)
        #expect(SupabaseNearbyFlightsService.isEnabled(raw: "NO") == false)
        #expect(SupabaseNearbyFlightsService.isEnabled(raw: "$(RADAR_ENABLED)") == false)
        #expect(SupabaseNearbyFlightsService.isEnabled(raw: "YES") == true)
        #expect(SupabaseNearbyFlightsService.isEnabled(raw: true) == true)
        #expect(SupabaseNearbyFlightsService.isEnabled(in: Bundle(for: Spy.self)) == false)
    }

    @Test func unavailableServiceHasNoButtonAndNoData() async {
        let off = UnavailableNearbyFlightsService()
        #expect(off.isAvailable == false)
        await #expect(throws: APIError.providerUnavailable) { try await off.nearby(latitude: 0, longitude: 0, radiusKm: 100) }
    }

    @Test func decodesTheNearbyContract() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appending(path: "supabase/functions/nearby-flights/contract/nearby.json"))
        let result = try SupabaseNearbyFlightsService.decode(data)
        #expect(result.fetchedAt == FlightJSON.parse("2026-11-07T18:00:00Z"))
        #expect(!result.stale && !result.truncated)
        #expect(result.flights.map(\.ident) == ["AF84", "UA1"])
        let af = try #require(result.flights.first)
        #expect(af.id == "AFR84-2" && af.operator == "AF" && af.type == "A359")
        #expect(af.altitudeFeet == 38_000 && af.groundspeedKnots == 489 && af.heading == 262)
        #expect(af.origin == "CDG" && af.destination == "SFO")
        #expect(abs(af.latitude - 37.9) < 1e-9 && abs(af.longitude + 122.6) < 1e-9)
    }

    // MARK: Fake traffic

    @Test func fakeTrafficIsPlausibleAndMoves() async throws {
        let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let a = try await FakeNearbyFlightsService(now: { t0 }).nearby(latitude: 37.62, longitude: -122.38, radiusKm: 100)
        let b = try await FakeNearbyFlightsService(now: { t0.addingTimeInterval(60) }).nearby(latitude: 37.62, longitude: -122.38, radiusKm: 100)
        #expect(a.flights.count == 12 && b.flights.count == 12)
        #expect(Set(a.flights.map(\.id)).count == 12)
        #expect(a.flights.map(\.id) == b.flights.map(\.id))
        for f in a.flights {
            // Inside about 100 km of the centre, airliner height and speed, a heading on the compass.
            let km = distanceKm(CLLocationCoordinate2D(latitude: 37.62, longitude: -122.38), f.coordinate)
            #expect(km < 110)
            #expect((15_000...40_000).contains(f.altitudeFeet ?? 0))
            #expect((280...480).contains(f.groundspeedKnots ?? 0))
            #expect((0..<360).contains(f.heading ?? -1))
        }
        // A minute of flight at 280 to 480 knots is 8 to 15 km. A plane that leaves the area in that
        // minute comes back in at the far side, so a few may jump; most just fly on.
        let flown = zip(a.flights, b.flights).map { distanceKm($0.coordinate, $1.coordinate) }
        #expect(flown.filter { $0 > 5 && $0 < 20 }.count >= 9, "\(flown)")
        // The same place and time give the same planes.
        let again = try await FakeNearbyFlightsService(now: { t0 }).nearby(latitude: 37.62, longitude: -122.38, radiusKm: 100)
        #expect(again == a)
    }

    @Test func fakeServiceCanFail() async {
        let fake = FakeNearbyFlightsService(nextError: .rateLimited)
        await #expect(throws: APIError.rateLimited) { try await fake.nearby(latitude: 0, longitude: 0, radiusKm: 50) }
    }

    @Test func fakeEnvironmentOffersTheRadarAndLiveDefaultDoesNot() async throws {
        let env = try await AppEnvironment.fake()
        #expect(env.nearby.isAvailable)
        #expect(UnavailableNearbyFlightsService().isAvailable == false)
    }

    // MARK: Store

    @Test func neverAsksForLocationItOnlyReadsIt() async {
        let locator = FakeRadarLocator(nil)
        let spy = Spy()
        let store = RadarStore(service: spy, locator: locator, lookup: Self.lookup, sleep: { _ in throw CancellationError() })
        await store.run()
        // No permission and no airport: nothing is read, and the screen asks for an airport code.
        #expect(store.status == .needsPlace)
        #expect(spy.reads.isEmpty)
        #expect(locator.asked == 1)
    }

    @Test func centresOnMyPlaceWhenAlreadyAllowed() async {
        let spy = Spy()
        spy.answers = [[Self.plane("A")]]
        let store = RadarStore(service: spy, locator: FakeRadarLocator(CLLocationCoordinate2D(latitude: 48.85, longitude: 2.35)),
                               lookup: Self.lookup, sleep: { _ in throw CancellationError() })
        await store.run()
        #expect(store.place == .me(latitude: 48.85, longitude: 2.35))
        #expect(spy.reads.first?.0 == 48.85)
        #expect(store.flights.map(\.id) == ["A"] && store.status == .ready)
    }

    @Test func chosenAirportIsUsedAndUnknownCodeIsRefused() async {
        let spy = Spy()
        let store = RadarStore(service: spy, locator: FakeRadarLocator(nil), lookup: Self.lookup, sleep: { _ in throw CancellationError() })
        #expect(store.choose(code: "ZZZ") == false)
        #expect(store.choose(code: "sfo"))
        await store.refresh()
        #expect(store.place == .airport(Self.sfo))
        #expect(spy.reads.count == 1 && spy.reads[0].0 == 37.62)
    }

    @Test func refreshesEveryMinuteUntilCancelled() async {
        let spy = Spy()
        let sleeps = SleepLog()
        let store = RadarStore(service: spy, locator: FakeRadarLocator(nil), lookup: Self.lookup, startAt: Self.sfo,
                               sleep: { d in
                                   if await sleeps.add(d) >= 3 { throw CancellationError() }
                               })
        await store.run()
        #expect(spy.reads.count == 3)
        #expect(await sleeps.all == Array(repeating: Duration.seconds(60), count: 3))
        #expect(RadarStore.refreshInterval == .seconds(60))
    }

    @Test func cancelledTaskStopsReading() async {
        let spy = Spy()
        let store = RadarStore(service: spy, locator: FakeRadarLocator(nil), lookup: Self.lookup, startAt: Self.sfo)
        let task = Task { await store.run() }
        // Let the first read land, then hide the radar: the task is cancelled in its minute of sleep.
        while spy.reads.isEmpty { await Task.yield() }
        task.cancel()
        await task.value
        #expect(spy.reads.count == 1)
    }

    @Test func followingRecentresOnThePlaneAndSearchesAroundIt() async {
        let spy = Spy()
        spy.answers = [[Self.plane("A", lat: 37.7, lon: -122.2)], [Self.plane("A", lat: 38.1, lon: -121.8)], [Self.plane("A", lat: 38.5, lon: -121.4)]]
        let store = RadarStore(service: spy, locator: FakeRadarLocator(nil), lookup: Self.lookup, startAt: Self.sfo,
                               sleep: { _ in throw CancellationError() })
        await store.refresh()
        let serial = store.cameraSerial
        store.follow(store.flights[0])
        #expect(store.followedID == "A" && store.selectedID == "A" && store.cameraSerial > serial)
        await store.refresh()
        // The second read was made around the plane, not the airport.
        #expect(spy.reads[1].0 == 37.7 && spy.reads[1].1 == -122.2)
        #expect(store.followed?.latitude == 38.1)
        await store.refresh()
        #expect(spy.reads[2].0 == 38.1)
        store.stopFollowing()
        #expect(store.followed == nil)
    }

    @Test func aFailedReadKeepsThePlanesAndShowsTheError() async {
        let spy = Spy()
        spy.answers = [[Self.plane("A")]]
        let store = RadarStore(service: spy, locator: FakeRadarLocator(nil), lookup: Self.lookup, startAt: Self.sfo)
        await store.refresh()
        spy.failure = .providerUnavailable
        await store.refresh()
        #expect(store.status == .failed(.providerUnavailable))
        #expect(store.flights.map(\.id) == ["A"])
    }

    @Test func choosingAnotherAirportClearsFollowAndPlanes() async {
        let spy = Spy()
        spy.answers = [[Self.plane("A")]]
        let store = RadarStore(service: spy, locator: FakeRadarLocator(nil), lookup: Self.lookup, startAt: Self.sfo)
        await store.refresh()
        store.follow(store.flights[0])
        store.choose(airport: Self.sfo)
        #expect(store.followedID == nil && store.flights.isEmpty && store.selectedID == nil)
    }

    @Test func cardTextsForARouteAndMissingParts() {
        #expect(RadarCard.route(Self.plane("A")) == "SFO → LHR")
        var p = Self.plane("B"); p.origin = nil
        #expect(RadarCard.route(p) == "LHR")
        p.destination = nil
        #expect(RadarCard.route(p) == nil)
    }
}

actor SleepLog {
    private(set) var all: [Duration] = []
    func add(_ d: Duration) -> Int { all.append(d); return all.count }
}
