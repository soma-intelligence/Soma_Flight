import CoreLocation
import Foundation
import Testing
@testable import FlightKit

/// The offline position engine (`RouteEstimator`), the region under the plane (`RegionNamer`) and the
/// offline pack the flight sheet keeps before departure (`OfflineFlightPack`).
@Suite struct RouteEstimatorTests {
    static func date(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }
    let cdg = CLLocationCoordinate2D(latitude: 49.0097, longitude: 2.5479)
    let jfk = CLLocationCoordinate2D(latitude: 40.6413, longitude: -73.7781)
    let nrt = CLLocationCoordinate2D(latitude: 35.7647, longitude: 140.3864)
    let sfo = CLLocationCoordinate2D(latitude: 37.6213, longitude: -122.379)
    let takeoff = date("2026-11-08T10:30:00Z")
    let landing = date("2026-11-08T18:40:00Z")

    var cdgJfk: RouteEstimator { RouteEstimator(origin: cdg, destination: jfk, takeoff: takeoff, landing: landing)! }

    // MARK: Position

    @Test func halfWayFromParisToNewYorkIsOverTheNorthAtlantic() {
        let r = cdgJfk
        let mid = r.position(at: takeoff.addingTimeInterval(r.airborneSeconds / 2))
        #expect(mid.phase == .cruise)
        #expect(abs(mid.altitudeM - 11_000) < 1)
        // The profile is symmetric enough that half the time is close to half the distance.
        #expect(abs(mid.distanceKm - r.distanceKm / 2) < 60)
        #expect(mid.coordinate.latitude > 48 && mid.coordinate.latitude < 55)
        #expect(mid.heading > 250 && mid.heading < 300)
        #expect(RegionNamer.bundled.region(at: mid.coordinate) == OverflownRegion(kind: .sea, name: "the North Atlantic"))
        #expect(RegionNamer.bundled.region(at: mid.coordinate)?.line == "Over the North Atlantic")
    }

    @Test func beforeTakeOffThePlaneIsAtTheOrigin() {
        let fix = cdgJfk.position(at: takeoff.addingTimeInterval(-600))
        #expect(fix.phase == .beforeTakeoff)
        #expect(fix.distanceKm == 0 && fix.altitudeM == 0)
        #expect(RouteEstimator.distanceKm(fix.coordinate, cdg) < 0.01)
    }

    @Test func afterLandingThePlaneIsAtTheDestination() {
        for t in [landing, landing.addingTimeInterval(3600)] {
            let fix = cdgJfk.position(at: t)
            #expect(fix.phase == .landed)
            #expect(fix.altitudeM == 0)
            #expect(RouteEstimator.distanceKm(fix.coordinate, jfk) < 0.01)
        }
    }

    @Test func thePhasesFollowClimbCruiseAndDescent() {
        let r = cdgJfk
        #expect(r.phase(at: takeoff.addingTimeInterval(5 * 60)) == .climbing)
        #expect(r.phase(at: takeoff.addingTimeInterval(19 * 60)) == .climbing)
        #expect(r.phase(at: takeoff.addingTimeInterval(21 * 60)) == .cruise)
        #expect(r.phase(at: landing.addingTimeInterval(-24 * 60)) == .descending)
        #expect(r.phase(at: landing.addingTimeInterval(-26 * 60)) == .cruise)
        // The plane is slow near the runways: the first 10 minutes cover far less than 10 cruise minutes.
        #expect(r.distanceFlown(at: takeoff.addingTimeInterval(600)) < r.cruiseSpeedKmh / 6 * 0.6)
        #expect(r.cruiseSpeedKmh > 650 && r.cruiseSpeedKmh < 950)
    }

    @Test func distanceOnlyGrowsAndEndsAtTheDestination() {
        let track = cdgJfk.track(every: 120)
        #expect(track.first?.time == takeoff)
        #expect(track.last?.time == landing)
        for (a, b) in zip(track, track.dropFirst()) { #expect(b.distanceKm >= a.distanceKm) }
        #expect(abs((track.last?.distanceKm ?? 0) - cdgJfk.distanceKm) < 1e-6)
    }

    @Test func acrossTheAntimeridianTokyoToSanFranciscoStaysOnTheMap() throws {
        let r = try #require(RouteEstimator(origin: nrt, destination: sfo, takeoff: takeoff,
                                            landing: takeoff.addingTimeInterval(9.5 * 3600)))
        let track = r.track(every: 300)
        var crossed = false
        for (a, b) in zip(track, track.dropFirst()) {
            #expect(b.coordinate.longitude >= -180 && b.coordinate.longitude <= 180)
            #expect(b.heading >= 0 && b.heading < 360)
            // Neighbours a few minutes apart never jump more than a few degrees, except across the date line.
            let jump = abs(b.coordinate.longitude - a.coordinate.longitude)
            if jump > 180 { crossed = true } else { #expect(jump < 10) }
        }
        #expect(crossed)
        let mid = r.position(at: takeoff.addingTimeInterval(r.airborneSeconds / 2))
        #expect(mid.coordinate.latitude > 44)
        #expect(RegionNamer.bundled.region(at: mid.coordinate)?.name == "the North Pacific")
    }

    // MARK: The sheet's estimate

    /// AF 6 CDG to JFK in the air, last heard `age` seconds before `now`.
    func inTheAir(age: TimeInterval, now: Date) -> Flight {
        Flight(providerId: "AF6", ident: "AF6", originIcao: "LFPG", destinationIcao: "KJFK",
               scheduledOut: takeoff.addingTimeInterval(-15 * 60), scheduledIn: landing.addingTimeInterval(7 * 60),
               actualOut: takeoff.addingTimeInterval(-15 * 60), actualOff: takeoff, status: .enRoute,
               position: Position(lat: 50, lon: -20, at: now.addingTimeInterval(-age)), updatedAt: now.addingTimeInterval(-age))
    }

    @Test func aFreshLivePositionIsNeverReplacedButAStaleOneIs() throws {
        let now = takeoff.addingTimeInterval(4 * 3600)
        // Live and fresh: the sheet shows the real position, no estimate.
        #expect(FlightEstimate.make(for: inTheAir(age: 3 * 60, now: now), origin: cdg, destination: jfk,
                                    online: true, now: now) == nil)
        // No update for 12 minutes: the estimate takes over, placed by the route engine.
        let stale = try #require(FlightEstimate.make(for: inTheAir(age: 12 * 60, now: now), origin: cdg,
                                                     destination: jfk, online: true, now: now))
        #expect(stale.reason == .stale)
        #expect(stale.phase == .cruise)
        let c = try #require(stale.coordinate)
        #expect(RouteEstimator.distanceKm(c, cdgJfk.position(at: now).coordinate) < 0.01)
        #expect(stale.regionLine() == "Over the North Atlantic")
        // Offline, even a fresh one is an estimate, with the offline badge.
        #expect(FlightEstimate.make(for: inTheAir(age: 60, now: now), origin: cdg, destination: jfk,
                                    online: false, now: now)?.reason == .offline)
    }

    @Test func theRegionLineSaysClimbingAndDescendingNearTheAirports() throws {
        let climbing = takeoff.addingTimeInterval(6 * 60)
        let up = try #require(FlightEstimate.make(for: inTheAir(age: 3600, now: climbing), origin: cdg, destination: jfk,
                                                  online: false, now: climbing))
        #expect(up.phase == .climbing)
        #expect(up.regionLine() == "Climbing over France")
        let descending = landing.addingTimeInterval(-5 * 60)
        let down = try #require(FlightEstimate.make(for: inTheAir(age: 3600, now: descending), origin: cdg,
                                                    destination: jfk, online: false, now: descending))
        #expect(down.phase == .descending)
        #expect(down.regionLine() == "Descending over the United States")
        let e = FlightEstimate(reason: .offline, progress: 0.5, coordinate: nil, heading: nil,
                               lastUpdate: Self.date("2026-11-03T14:02:00Z"), probablyLanded: false)
        #expect(e.lastUpdateLine(timeZone: .gmt) == "Last update 14:02")
        #expect(e.regionLine() == nil)
    }

    // MARK: Inputs

    @Test func aFlightsRunwayTimesWinOverItsGateTimes() throws {
        let f = Flight(providerId: "AF6", ident: "AF6", originIcao: "LFPG", destinationIcao: "KJFK",
                       scheduledOut: takeoff, scheduledIn: landing, actualOut: takeoff,
                       actualOff: takeoff.addingTimeInterval(22 * 60))
        let r = try #require(RouteEstimator(flight: f, origin: cdg, destination: jfk))
        #expect(r.takeoff == takeoff.addingTimeInterval(22 * 60))
        // No runway landing time: the gate arrival less the taxi in.
        #expect(r.landing == landing.addingTimeInterval(-RouteEstimator.taxiIn))
        // Gate times only: the taxi out is added.
        let gates = Flight(providerId: "AF6", ident: "AF6", originIcao: "LFPG", destinationIcao: "KJFK",
                           scheduledOut: takeoff, scheduledIn: landing)
        #expect(RouteEstimator(flight: gates, origin: cdg, destination: jfk)?.takeoff == takeoff.addingTimeInterval(15 * 60))
    }

    @Test func withoutALandingTimeTheTypesCruiseSpeedGivesOne() throws {
        let f = Flight(providerId: "AF6", ident: "AF6", originIcao: "LFPG", destinationIcao: "KJFK", scheduledOut: takeoff)
        let wide = AircraftType(id: "A359", family: .a350, manufacturer: "Airbus", name: "Airbus A350-900")
        let r = try #require(RouteEstimator(flight: f, origin: cdg, destination: jfk, aircraft: wide))
        #expect(abs(r.cruiseSpeedKmh - 900) < 1)
        // About 6.5 h in still air plus the slow climb and descent.
        #expect(r.airborneSeconds > 6.4 * 3600 && r.airborneSeconds < 7 * 3600)
        #expect(RouteEstimator.typicalCruiseKmh(.atr) < RouteEstimator.typicalCruiseKmh(.a320))
    }

    @Test func aBlockTimeLosesTheTaxiAtBothEnds() throws {
        let r = try #require(RouteEstimator(origin: cdg, destination: jfk, gateDeparture: takeoff, blockTime: 8.5 * 3600))
        #expect(r.airborneSeconds == 8.5 * 3600 - RouteEstimator.taxiOut - RouteEstimator.taxiIn)
        #expect(RouteEstimator(origin: cdg, destination: jfk, takeoff: landing, landing: takeoff) == nil)
    }

    @Test func aShortHopShrinksItsClimbAndFliesLower() throws {
        let lhr = CLLocationCoordinate2D(latitude: 51.47, longitude: -0.4543)
        let r = try #require(RouteEstimator(origin: lhr, destination: cdg, takeoff: takeoff,
                                            landing: takeoff.addingTimeInterval(45 * 60)))
        #expect(r.climbSeconds == 45 * 60 * 0.3)
        #expect(r.cruiseAltitudeM < 8_000)
    }

    // MARK: Regions

    @Test func regionsReadAtTheLevelOfCountriesAndOceans() {
        let names = RegionNamer.bundled
        func line(_ lat: Double, _ lon: Double) -> String? {
            names.region(at: CLLocationCoordinate2D(latitude: lat, longitude: lon))?.line
        }
        #expect(line(72, -40) == "Over Greenland")
        #expect(line(53.4, -8) == "Over Ireland")
        #expect(line(64.8, -18.5) == "Over Iceland")
        #expect(line(40, -100) == "Over the United States")
        #expect(line(45, -30) == "Over the North Atlantic")
        #expect(line(-20, -20) == "Over the South Atlantic")
        #expect(line(38, 5) == "Over the Mediterranean Sea")
        #expect(line(-20, 80) == "Over the Indian Ocean")
        #expect(line(-30, -120) == "Over the South Pacific")
        #expect(line(45, 179.9) == "Over the North Pacific")
        #expect(line(45, -179.9) == "Over the North Pacific")
        // Central America splits the two oceans.
        #expect(line(15, -75) == "Over the Caribbean Sea")
        #expect(line(7, -80) == "Over the North Pacific")
        #expect(line(56, 3) == "Over the North Sea")
        #expect(line(85, 0) == "Over the Arctic Ocean")
        #expect(line(-80, 0) == "Over Antarctica")
    }

    @Test func aRegionAskedAgainComesFromTheMemo() {
        let names = RegionNamer(land: RegionNamer.readLand(), seas: RegionNamer.readSeas(),
                                places: [.init(lat: 53.4, lon: -6.3, country: "IE"), .init(lat: 40, lon: -100, country: "ZZ")],
                                countryName: { $0 == "IE" ? "Ireland" : nil })
        let here = CLLocationCoordinate2D(latitude: 53.4, longitude: -8)
        #expect(names.memo.count == 0)
        let first = names.region(at: here)
        #expect(first?.line == "Over Ireland")
        // A redraw at the same point (to the metre) reads the memo, no new entry.
        #expect(names.region(at: CLLocationCoordinate2D(latitude: 53.400_01, longitude: -8.000_01)) == first)
        #expect(names.memo.count == 1)
        // Nothing named (a country with no name in the table) is kept too.
        #expect(names.region(at: CLLocationCoordinate2D(latitude: 40, longitude: -100)) == nil)
        #expect(names.memo.count == 2)
        // The memo stays small.
        for i in 0..<(RegionNamer.Memo.limit + 10) {
            _ = names.region(at: CLLocationCoordinate2D(latitude: 10 + Double(i) * 0.02, longitude: -30))
        }
        #expect(names.memo.count <= RegionNamer.Memo.limit)
    }

    // MARK: Offline pack

    @Test func thePackIsWorthKeepingFromADayBeforeDepartureUntilTheEnd() {
        let f = Flight(providerId: "AF6", ident: "AF6", originIcao: "LFPG", destinationIcao: "KJFK",
                       scheduledOut: takeoff, scheduledIn: landing)
        #expect(!OfflineFlightPack.isWorthSaving(f, now: takeoff.addingTimeInterval(-25 * 3600)))
        #expect(OfflineFlightPack.isWorthSaving(f, now: takeoff.addingTimeInterval(-23 * 3600)))
        #expect(OfflineFlightPack.isWorthSaving(f, now: takeoff.addingTimeInterval(3600)))
        var landed = f; landed.status = .landed
        #expect(!OfflineFlightPack.isWorthSaving(landed, now: takeoff))
        var canceled = f; canceled.status = .canceled
        #expect(!OfflineFlightPack.isWorthSaving(canceled, now: takeoff))
    }

    @Test func thePackCarriesTheRouteAndRebuildsTheEstimate() throws {
        // Whole seconds: the cache keeps milliseconds.
        let f = Flight(providerId: "AF6", ident: "AF6", originIcao: "LFPG", destinationIcao: "KJFK",
                       scheduledOut: takeoff, scheduledIn: landing, updatedAt: takeoff)
        let origin = try #require(AirportDirectory.bundled().airport("LFPG"))
        let destination = try #require(AirportDirectory.bundled().airport("KJFK"))
        let pack = OfflineFlightPack(flight: f, origin: origin, destination: destination, aircraft: nil, savedAt: takeoff)
        #expect(pack.route.count == OfflineFlightPack.routeSegments + 1)
        #expect(abs((pack.route.first?.lat ?? 0) - origin.lat) < 1e-9)
        let data = try FlightJSON.encoder.encode(pack)
        let back = try FlightJSON.decoder.decode(OfflineFlightPack.self, from: data)
        #expect(back == pack)
        #expect(back.estimator?.takeoff == takeoff.addingTimeInterval(RouteEstimator.taxiOut))
        // Old packs go, recent ones stay, newest first.
        let old = OfflineFlightPack(flight: Flight(providerId: "X", ident: "X", originIcao: "LFPG", destinationIcao: "KJFK",
                                                   scheduledOut: takeoff.addingTimeInterval(-5 * 86_400),
                                                   scheduledIn: takeoff.addingTimeInterval(-4 * 86_400)),
                                    origin: origin, destination: destination, aircraft: nil, savedAt: takeoff)
        #expect(OfflineFlightPack.pruned([old, pack], now: takeoff) == [pack])
    }

    @Test func theCacheKeepsOnePackPerFlightForItsOwner() async throws {
        let store = try CacheStore.inMemory()
        let owner = UUID()
        try await store.claim(for: owner)
        let scope = store.scoped(for: owner)
        let now = Date(timeIntervalSince1970: Date.now.timeIntervalSince1970.rounded(.down))
        let f = Flight(providerId: "AF6", ident: "AF6", originIcao: "LFPG", destinationIcao: "KJFK",
                       scheduledOut: now.addingTimeInterval(3600), scheduledIn: now.addingTimeInterval(9 * 3600), updatedAt: now)
        let origin = try #require(AirportDirectory.bundled().airport("LFPG"))
        let destination = try #require(AirportDirectory.bundled().airport("KJFK"))
        let pack = OfflineFlightPack(flight: f, origin: origin, destination: destination, aircraft: nil, savedAt: now)
        await scope.save(pack: pack)
        await scope.save(pack: pack)
        #expect(await scope.pack(for: f.id) == pack)
        #expect(await store.scoped(for: UUID()).pack(for: f.id) == nil)
        // A sign-out wipe takes the packs with it.
        try await store.clear()
        #expect(await store.pack(for: f.id) == nil)
    }

    @MainActor @Test func offlineTheSheetPlacesThePlaneFromThePackOrTheBundledAirports() async throws {
        let svc = FakeFlightService()
        let cache = try CacheStore.inMemory()
        let target = try #require(try await svc.followed().first)
        // Online a few hours before departure: the sheet keeps the pack.
        let online = FlightDetailStore(id: target.id, flights: svc, airports: FakeAirportService(), packs: cache,
                                       lookup: AirportDirectory.bundled().lookup)
        await online.load()
        let flight = try #require(online.flight)
        let departure = try #require(flight.scheduledOut ?? flight.estimatedOut)
        var leaving = flight; leaving.status = .scheduled
        await online.keepOfflinePack(leaving, now: departure.addingTimeInterval(-3600))
        #expect(await cache.pack(for: target.id)?.flight.id == target.id)

        // Offline, nothing else cached: the flight and both airports come back from the pack.
        await svc.setNextError(.offline)
        let offline = FlightDetailStore(id: target.id, flights: svc, airports: FakeAirportService(), packs: cache)
        await offline.load()
        #expect(offline.error == .offline)
        #expect(offline.flight?.id == target.id)
        #expect(offline.origin?.id == online.origin?.id)
        #expect(offline.offlinePack != nil)

        // No pack but a cached flight: the bundled airports fill in.
        let other = try CacheStore.inMemory()
        await other.save(flights: [flight])
        await svc.setNextError(.offline)
        let bundled = FlightDetailStore(id: target.id, flights: svc, airports: FakeAirportService(), cache: other,
                                        lookup: AirportDirectory.bundled().lookup)
        await bundled.load()
        #expect(bundled.origin?.id == flight.originIcao)
    }

    @MainActor @Test func theNewerOfTheListCopyAndThePackShowsOfflineAndLiveDataWins() async throws {
        let svc = FakeFlightService()
        let target = try #require(try await svc.followed().first)
        let origin = try #require(AirportDirectory.bundled().airport(target.originIcao))
        let destination = try #require(AirportDirectory.bundled().airport(target.destinationIcao))
        let then = Date(timeIntervalSince1970: Date.now.timeIntervalSince1970.rounded(.down) - 7200)
        var stale = target; stale.updatedAt = then; stale.gateOrigin = "A1"
        var newer = target; newer.updatedAt = then.addingTimeInterval(3600); newer.gateOrigin = "B7"

        func store(list: Flight, pack: Flight) async throws -> FlightDetailStore {
            let cache = try CacheStore.inMemory()
            await cache.save(flights: [list])
            await cache.save(pack: OfflineFlightPack(flight: pack, origin: origin, destination: destination,
                                                     aircraft: nil, savedAt: pack.updatedAt))
            return FlightDetailStore(id: target.id, flights: svc, airports: FakeAirportService(), cache: cache,
                                     packs: cache)
        }

        // Offline, the pack saved after the list: the pack's flight shows.
        await svc.setNextError(.offline)
        let packWins = try await store(list: stale, pack: newer)
        await packWins.load()
        #expect(packWins.flight?.gateOrigin == "B7")

        // Offline, the list updated after the pack: the list's copy stays.
        await svc.setNextError(.offline)
        let listWins = try await store(list: newer, pack: stale)
        await listWins.load()
        #expect(listWins.flight?.gateOrigin == "B7")

        // Online, the live answer replaces both.
        let live = try await store(list: stale, pack: newer)
        await live.load()
        #expect(live.flight == (try await svc.flight(target.id)))
    }
}
