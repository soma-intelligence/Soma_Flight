import CoreLocation
import Foundation
import SwiftUI
import Testing
@testable import FlightKit

/// The shell round of 2026-10-31: cards that slide up, one flight alone on the globe, a globe that is
/// not rebuilt by the sheet, and a full-screen map whose visible area follows the detent.
@Suite @MainActor struct ShellUITests {
    private func loaded() async throws -> HomeModel {
        let home = HomeModel(env: try await AppEnvironment.fake())
        await home.load()
        return home
    }

    private func airport(_ id: String, _ lat: Double, _ lon: Double) -> Airport {
        Airport(id: id, name: id, city: id, country: "", lat: lat, lon: lon, tz: "UTC")
    }

    // MARK: Cards

    @Test func cardsAreKeyedByDepthSoTheSameScreenTwiceIsTwoCards() {
        let id = UUID()
        let path: [SheetRoute] = [.flight(id), .airport("KAUS"), .flight(id)]
        let entries = CardStack<SheetRoute, EmptyView, EmptyView>.entries(path)
        #expect(entries.map(\.depth) == [1, 2, 3])
        #expect(Set(entries).count == 3)
        // Replacing the only card is a new card: the old one drops while the new one rises.
        let a = CardStack<SheetRoute, EmptyView, EmptyView>.entries([.flight(UUID())])
        let b = CardStack<SheetRoute, EmptyView, EmptyView>.entries([.flight(UUID())])
        #expect(a != b)
    }

    // MARK: One flight alone on the globe

    @Test func anOpenFlightIsolatesItsArcAirportsAndPlane() async throws {
        let home = try await loaded()
        #expect(home.isolation == nil)
        let flight = try #require(home.followed.first { $0.position != nil })
        home.open(flight: flight)
        let iso = try #require(home.isolation)
        #expect(iso.route.id == flight.id.uuidString)
        #expect(Set(iso.airports.map(\.id)) == [flight.originIcao, flight.destinationIcao])
        #expect(iso.plane?.id == flight.id)
        // An airport on top shows everything again; closing back onto the flight isolates it again.
        home.open(airport: flight.destinationIcao)
        #expect(home.isolation == nil)
        home.shell.close()
        #expect(home.isolation?.route.id == flight.id.uuidString)
        home.shell.close()
        #expect(home.isolation == nil)
    }

    @Test func aPastFlightIsolatesItsArcWithoutAPlane() async throws {
        let home = try await loaded()
        home.tab = .passport
        let past = try #require(home.passport.flights.first)
        home.open(past: past)
        let iso = try #require(home.isolation)
        #expect(iso.plane == nil)
        #expect(Set(iso.airports.map(\.id)) == [past.originIcao, past.destinationIcao])
        // The Passport arc of the same pair is the same arc, whichever way it is drawn.
        #expect(home.globe.routes.contains { iso.isSameArc($0) })
    }

    @Test func layersFadeEverythingButTheIsolatedFlight() {
        let sfo = airport("KSFO", 37.6, -122.4), jfk = airport("KJFK", 40.6, -73.8), cdg = airport("LFPG", 49.0, 2.5)
        let mine = Route(id: "mine", from: sfo.coordinate, to: jfk.coordinate, level: .onTime, isPast: false)
        let other = Route(id: "other", from: jfk.coordinate, to: cdg.coordinate, level: .late, isPast: false)
        let p1 = FlightAnnotationModel(id: UUID(), ident: "UA1", coordinate: sfo.coordinate, heading: 0, level: .onTime)
        let p2 = FlightAnnotationModel(id: UUID(), ident: "AF2", coordinate: cdg.coordinate, heading: 0, level: .late)
        let iso = GlobeIsolation(route: mine, airports: [sfo, jfk], plane: p1)

        let all = GlobeLayers(routes: [mine, other], planes: [p1, p2], airports: [sfo, jfk, cdg], isolation: nil, fade: 0)
        #expect(all.routes.count == 2)
        #expect(all.routes.allSatisfy { $0.opacity == 1 })
        #expect(all.airports.allSatisfy { $0.titled })

        let half = GlobeLayers(routes: [mine, other], planes: [p1, p2], airports: [sfo, jfk, cdg], isolation: iso, fade: 0.5)
        #expect(half.routes.first { $0.id == "other" }?.opacity == 0.5)
        #expect(half.routes.first { $0.id == "mine" }?.opacity == 1)
        #expect(half.routes.count == 2)
        #expect(half.airports.first { $0.id == "LFPG" }.map { $0.opacity == 0.5 && !$0.titled } == true)
        #expect(half.airports.filter { $0.id != "LFPG" }.allSatisfy { $0.opacity == 1 && $0.titled })
        #expect(half.planes.first { $0.id == p2.id }?.opacity == 0.5)

        // Faded out: only the flight is left, so nothing invisible can be tapped.
        let alone = GlobeLayers(routes: [mine, other], planes: [p1, p2], airports: [sfo, jfk, cdg], isolation: iso, fade: 0)
        #expect(alone.routes.map(\.id) == ["mine"])
        #expect(Set(alone.airports.map(\.id)) == ["KSFO", "KJFK"])
        #expect(alone.planes.map(\.id) == [p1.id])
    }

    @Test func theFadeEasesInAndOut() {
        #expect(GlobeLayers.eased(from: 1, to: 0, at: 0) == 1)
        #expect(GlobeLayers.eased(from: 1, to: 0, at: 1) == 0)
        #expect(GlobeLayers.eased(from: 1, to: 0, at: 0.5) == 0.5)
        // Slow at the ends.
        #expect(1 - GlobeLayers.eased(from: 1, to: 0, at: 0.1) < 0.1)
    }

    // MARK: The globe is not rebuilt by the sheet

    @Test func globeContentIsBuiltOncePerChangeOfFlights() async throws {
        let home = try await loaded()
        let first = home.globe
        home.shell.detent = .collapsed
        home.shell.detent = .medium
        let again = home.globe
        // Same arcs, from the cache: the same great-circle runs, not rebuilt ones.
        #expect(first == again)
        #expect(first.routes.map(\.runs.count) == again.routes.map(\.runs.count))
        home.tab = .passport
        #expect(home.globe != first)
        home.tab = .flights
        #expect(home.globe == first)
    }

    // MARK: Full-screen map

    @Test func longHaulArcFitsAboveTheMediumSheetOnTheFullScreenMap() throws {
        let cdg = airport("LFPG", 49.0097, 2.5479), sfo = airport("KSFO", 37.6188, -122.3750)
        let route = Route(from: cdg.coordinate, to: sfo.coordinate, level: .late, isPast: false)
        let screen = CGSize(width: 402, height: 874)
        for inset in [ShellModel.mapInset(in: .standard)] {
            let vp = GlobeViewport(size: screen, visible: CGRect(x: 0, y: 62, width: 402, height: 874 - 62 - inset))
            let cam = GlobeMap.camera(for: .route(route), in: vp)
            #expect(cam.distance <= GlobeMap.maximumDistance(at: cam.centerCoordinate.latitude, in: vp))
            #expect(GlobeMap.fits(route.runs.flatMap { $0 }, camera: cam, in: vp))
        }
    }
}
