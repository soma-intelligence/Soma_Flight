import CoreLocation
import Foundation
import MapKit
import SwiftUI
import Testing
@testable import FlightKit

/// Task 8: the home state both shells share, and the Mac's globe fit beside the panel.
@Suite @MainActor struct HomeModelTests {
    private func loaded() async throws -> HomeModel {
        let home = HomeModel(env: try await AppEnvironment.fake())
        await home.load()
        return home
    }

    /// Passport from the tab opens at full height, as in the reference; My Flights leaves the sheet as it is.
    @Test func passportTabOpensAtFullHeight() async throws {
        let home = HomeModel(env: try await AppEnvironment.fake())
        #expect(home.shell.detent == .medium)
        home.tab = .passport
        #expect(home.shell.detent == .large)
        home.shell.detent = .medium
        home.tab = .flights
        #expect(home.shell.detent == .medium)
        home.shell.detent = ShellModel.collapsed
        home.tab = .passport
        #expect(home.shell.detent == .large)
    }

    private func defaults(_ values: [String: String]) -> UserDefaults {
        let name = "HomeModelTests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        for (k, v) in values { d.set(v, forKey: k) }
        return d
    }

    @Test func globeFollowsTheTab() async throws {
        let home = try await loaded()
        #expect(!home.followed.isEmpty)
        let flights = home.globe
        #expect(!flights.planes.isEmpty)
        #expect(flights.routes.allSatisfy { !$0.isPast })
        home.tab = .passport
        let past = home.globe
        #expect(past.planes.isEmpty)
        #expect(!past.routes.isEmpty)
        #expect(past.routes.allSatisfy { $0.isPast })
    }

    @Test func pinsAndScreensOpenAirportsByICAO() async throws {
        let home = try await loaded()
        home.select(.airport("KAUS"))
        #expect(home.shell.path == [.airport("KAUS")])
        // A screen hands over the IATA code; the stack keys on ICAO, so it is the same screen.
        home.open(airport: "AUS")
        #expect(home.shell.path == [.airport("KAUS")])
        #expect(home.shell.recenter == 1)
        #expect(home.focus == home.env.lookup("KAUS").map(GlobeFocus.airport))
    }

    @Test func aPlaneOpensItsFlightAndTheCameraTakesItsArc() async throws {
        let home = try await loaded()
        let flight = try #require(home.myFlights.live.first)
        home.select(.flight(flight.id))
        #expect(home.shell.path == [.flight(flight.id)])
        let arc = try #require(GlobeContent.route(for: flight, lookup: home.env.lookup))
        #expect(home.focus == .route(arc))
        // A flight no longer followed opens nothing.
        home.shell.reset()
        home.select(.flight(UUID()))
        #expect(home.shell.path.isEmpty)
    }

    @Test func aNewUserGetsFreshStoresAnEmptyStackAndAReload() async throws {
        let home = try await loaded()
        home.open(airport: "KSFO")
        let before = ObjectIdentifier(home.myFlights)
        home.userChanged()
        #expect(home.shell.path.isEmpty)
        #expect(ObjectIdentifier(home.myFlights) != before)
        #expect(!home.myFlights.hasLoaded)
        // The rebuilt stores load on their own.
        for _ in 0..<200 where !(home.myFlights.hasLoaded && home.passport.hasLoaded) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(home.myFlights.hasLoaded)
        #expect(home.passport.hasLoaded)
        #expect(!home.followed.isEmpty)
    }

    @Test func storedUnitsReadAndWriteTheSharedKeys() {
        let d = UserDefaults.standard
        let saved = (d.object(forKey: "units.distance"), d.object(forKey: "units.clock24"))
        defer {
            d.set(saved.0, forKey: "units.distance"); d.set(saved.1, forKey: "units.clock24")
        }
        d.set("mi", forKey: "units.distance"); d.set(false, forKey: "units.clock24")
        let stored = StoredUnits()
        #expect(stored.wrappedValue == Units(distance: .mi, clock: .h12))
        stored.projectedValue.wrappedValue = Units(distance: .km, clock: .h24)
        #expect(d.string(forKey: "units.distance") == "km")
        #expect(d.bool(forKey: "units.clock24"))
    }

    @Test func launchArgumentsOpenAScreen() async throws {
        let home = try await loaded()
        home.applyLaunchArguments(defaults(["tab": "passport", "open": "airport:AUS", "detent": "large"]))
        #expect(home.tab == .passport)
        #expect(home.shell.path == [.airport("KAUS")])
        #expect(home.shell.detent == .large)

        let other = try await loaded()
        other.applyLaunchArguments(defaults(["open": "flight", "tab": "nonsense"]))
        #expect(other.tab == .flights)
        let first = try #require(other.myFlights.live.first)
        #expect(other.shell.path == [.flight(first.id)])
    }

    /// Only the `-useFakes` branch runs here: without it `forLaunch` opens the on-disk cache and the
    /// standard defaults of the test host, which a test must not touch.
    @Test func launchWithUseFakesBuildsTheInMemoryEnvironment() async throws {
        let fake = try await AppEnvironment.forLaunch(arguments: ["SomaFlight", "-useFakes"])
        #expect(fake.recents == .memory)
        #expect(fake.recentsDefaults == nil)
    }

    @Test func metricsScaleLeavesTheIPhoneUntouchedAndFloorsMacType() {
        #expect(Theme.metric(16, 1) == 16)
        #expect(Theme.fontSize(13.5, 1) == 13.5)
        #expect(Theme.metric(20, 0.8) == 16)
        #expect(Theme.fontSize(17, 0.8) == 17 * 0.8)
        // Captions stop at 10 pt; a size already under 10 stays as it is.
        #expect(Theme.fontSize(11, 0.8) == 10)
        #expect(Theme.fontSize(9, 0.8) == 9)
        #expect(EnvironmentValues().metricsScale == 1)
    }

    // MARK: Mac globe beside the panel

    /// A window of `w` x `h` with the 360 pt panel and its 12 pt inset covering the left.
    private func mac(_ w: CGFloat, _ h: CGFloat) -> GlobeViewport {
        GlobeViewport.mac(size: CGSize(width: w, height: h), visible: CGRect(x: 372, y: 0, width: w - 372, height: h))
    }

    /// The clamp MapKit applied at the equator in the sweep (width, height, km), read back from MapKit.
    private let measured: [(CGFloat, CGFloat, Double)] = [
        (900, 640, 26_410), (1000, 1000, 37_140), (1100, 650, 21_946), (1180, 799, 25_148), (1300, 1009, 28_826),
        (1400, 700, 18_570), (1500, 632, 15_648), (1600, 900, 20_891), (1700, 1000, 21_847),
    ]

    @Test func macClampFitsEveryMeasuredWindow() {
        for (w, h, km) in measured {
            let fitted = GlobeViewport.macFarLimit(CGSize(width: w, height: h)) / 1000
            #expect(abs(fitted - km) / km < 0.005, "\(w) x \(h): fitted \(fitted) km, measured \(km) km")
        }
        // The cosine law and the 1% margin below MapKit's clamp.
        let vp = mac(1180, 799)
        #expect(abs(GlobeMap.maximumDistance(at: 60, in: vp) - 25_148_000 * 0.5 * 0.99) < 60_000)
        #expect(GlobeViewport.phoneFarLimit(GlobeViewport.phoneMeasuredSize) == 40_000_000)
        // The full-screen phone map scales the measured point by height over width, as the Mac does.
        #expect(abs(GlobeViewport.phone.farLimit - 40_000_000 * 874 / 495) < 1)
        #expect(GlobeViewport.macFarLimit(.zero) == 40_000_000)
    }

    @Test func longHaulArcFitsRightOfThePanelAtEveryWindowSize() throws {
        let cdg = CLLocationCoordinate2D(latitude: 49.0097, longitude: 2.5479)
        let sfo = CLLocationCoordinate2D(latitude: 37.6188, longitude: -122.3750)
        let route = Route(from: cdg, to: sfo, level: .late, isPast: false)
        for (w, h) in [(900.0, 600.0), (1180, 800), (1400, 700), (1500, 632), (1800, 1000), (1000, 1000)] {
            let vp = mac(w, h)
            let cam = GlobeMap.camera(for: .route(route), in: vp)
            // A distance MapKit accepts, so the camera it shows is the one fitted here.
            #expect(cam.distance <= GlobeMap.maximumDistance(at: cam.centerCoordinate.latitude, in: vp), "\(w) x \(h)")
            // Both ends inside the window and clear of the panel; the least-overflow fallback may crop the
            // arc's middle a little in the smallest window, never its ends.
            for end in [cdg, sfo] {
                let p = try #require(GlobeMap.project(end, camera: cam, in: vp), "\(w) x \(h)")
                #expect(p.x > 372 && p.x < w && p.y > 0 && p.y < h, "\(w) x \(h): \(p)")
            }
        }
    }
}
