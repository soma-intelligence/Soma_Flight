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

    @Test func aNewUserGetsFreshStoresAndAnEmptyStack() async throws {
        let home = try await loaded()
        home.open(airport: "KSFO")
        let before = ObjectIdentifier(home.myFlights)
        home.userChanged()
        #expect(home.shell.path.isEmpty)
        #expect(ObjectIdentifier(home.myFlights) != before)
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

    @Test func launchPicksFakesOnlyWhenAsked() async throws {
        let fake = try await AppEnvironment.forLaunch(arguments: ["SomaFlight", "-useFakes"])
        #expect(fake.recents == .memory)
    }

    // MARK: Mac globe beside the panel

    /// A 1180 x 800 window with the 360 pt panel and its 12 pt inset covering the left.
    private let mac = GlobeViewport.mac(size: CGSize(width: 1180, height: 800),
                                        visible: CGRect(x: 372, y: 0, width: 808, height: 800))

    @Test func macClampFollowsTheMapHeight() {
        #expect(mac.farLimit == 26_400_000)
        #expect(GlobeMap.maximumDistance(at: 60, in: mac) < GlobeMap.maximumDistance(at: 60))
        #expect(GlobeViewport.phone.farLimit == 40_000_000)
        #expect(GlobeViewport.phone.centreShift == 0)
    }

    @Test func longHaulArcFitsRightOfThePanel() throws {
        let cdg = CLLocationCoordinate2D(latitude: 49.0097, longitude: 2.5479)
        let sfo = CLLocationCoordinate2D(latitude: 37.6188, longitude: -122.3750)
        let route = Route(from: cdg, to: sfo, level: .late, isPast: false)
        let cam = GlobeMap.camera(for: .route(route), in: mac)
        #expect(cam.distance <= GlobeMap.maximumDistance(at: cam.centerCoordinate.latitude, in: mac))
        for end in [cdg, sfo] {
            let p = try #require(GlobeMap.project(end, camera: cam, in: mac))
            // Clear of the panel and inside the window.
            #expect(p.x > 372 && p.x < 1180)
            #expect(p.y > 0 && p.y < 800)
        }
        #expect(GlobeMap.fits(route.runs.flatMap { $0 }, camera: cam, in: mac))
    }

    @Test func macCentreLandsAboveTheMiddleOfTheVisibleArea() throws {
        let c = CLLocationCoordinate2D(latitude: 40, longitude: -100)
        let p = try #require(GlobeMap.project(c, camera: MapCamera(centerCoordinate: c, distance: 5_000_000, heading: 0, pitch: 0), in: mac))
        #expect(abs(p.x - 776) < 0.5)
        #expect(abs(p.y - 358) < 0.5)
    }
}
