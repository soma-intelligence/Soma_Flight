import CoreLocation
import Foundation
import Testing
@testable import FlightKit

/// The sky behind the plane on the "Where is my plane?" card, and the card's title once the flight is over.
@MainActor @Suite struct PlaneSkyTests {
    static func date(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }
    static let sfo = Airport(id: "KSFO", iata: "SFO", name: "San Francisco", city: "San Francisco", country: "US",
                             lat: 37.6188, lon: -122.3750, tz: "America/Los_Angeles")
    static let den = Airport(id: "KDEN", iata: "DEN", name: "Denver", city: "Denver", country: "US",
                             lat: 39.8617, lon: -104.6731, tz: "America/Denver")
    static let paris = CLLocationCoordinate2D(latitude: 48.8566, longitude: 2.3522)

    @Test func phaseFromElevation() {
        #expect(SkyPhase.from(elevation: -30, rising: true) == .night)
        #expect(SkyPhase.from(elevation: -6.01, rising: false) == .night)
        #expect(SkyPhase.from(elevation: -6, rising: true) == .dawn)
        #expect(SkyPhase.from(elevation: 0, rising: true) == .dawn)
        #expect(SkyPhase.from(elevation: 5.9, rising: false) == .dusk)
        #expect(SkyPhase.from(elevation: -3, rising: false) == .dusk)
        #expect(SkyPhase.from(elevation: 6, rising: false) == .day)
        #expect(SkyPhase.from(elevation: 60, rising: true) == .day)
    }

    /// Paris on the summer solstice: sunrise 05:47 and sunset 21:58 local time (03:47 and 19:58 UTC).
    @Test func phaseOverADayInParis() {
        #expect(SkyPhase.at(Self.paris, time: Self.date("2026-06-21T00:00:00Z")) == .night)
        #expect(SkyPhase.at(Self.paris, time: Self.date("2026-06-21T03:50:00Z")) == .dawn)
        #expect(SkyPhase.at(Self.paris, time: Self.date("2026-06-21T12:00:00Z")) == .day)
        #expect(SkyPhase.at(Self.paris, time: Self.date("2026-06-21T20:00:00Z")) == .dusk)
        #expect(SkyPhase.at(Self.paris, time: Self.date("2026-06-21T22:30:00Z")) == .night)
    }

    /// Sydney in December: the sun climbs through the northern sky, and rising still reads as dawn.
    @Test func southernHemisphere() {
        let sydney = CLLocationCoordinate2D(latitude: -33.8688, longitude: 151.2093)
        // Sunrise about 05:40 AEDT (18:40 UTC the day before), sunset about 20:05 AEDT (09:05 UTC).
        #expect(SkyPhase.at(sydney, time: Self.date("2026-12-14T18:45:00Z")) == .dawn)
        #expect(SkyPhase.at(sydney, time: Self.date("2026-12-15T02:00:00Z")) == .day)
        #expect(SkyPhase.at(sydney, time: Self.date("2026-12-15T09:10:00Z")) == .dusk)
        #expect(SkyPhase.at(sydney, time: Self.date("2026-12-15T13:00:00Z")) == .night)
    }

    @Test func polarNightAndMidnightSun() {
        let tromso = CLLocationCoordinate2D(latitude: 69.6492, longitude: 18.9553)
        #expect(SkyPhase.at(tromso, time: Self.date("2026-12-21T23:00:00Z")) == .night)
        // Midnight sun: low on the northern horizon at 01:00 local, but never night; high and bright at noon.
        #expect(SkyPhase.at(tromso, time: Self.date("2026-06-21T23:00:00Z")) != .night)
        #expect(SkyPhase.at(tromso, time: Self.date("2026-06-21T11:00:00Z")) == .day)
    }

    static func flight(_ status: FlightStatus, position: Position? = nil) -> Flight {
        Flight(providerId: "p", ident: "UAL1882", originIcao: "KSFO", originIata: "SFO", destinationIcao: "KDEN",
               destinationIata: "DEN", scheduledOut: date("2026-10-02T14:00:00Z"), scheduledIn: date("2026-10-02T16:30:00Z"),
               actualIn: status == .arrived ? date("2026-10-02T16:41:00Z") : nil,
               aircraftType: "B39M", registration: "N47280", status: status, position: position)
    }

    @Test func titleForAPastFlight() {
        let now = Self.date("2026-11-18T12:00:00Z")
        let arrived = Self.flight(.arrived)
        #expect(PlaneSection.isPast(arrived, archived: false, now: now))
        #expect(PlaneSection.title(isPast: true) == "About this plane")
        #expect(PlaneSection.title(isPast: false) == "Where is my plane?")
        #expect(PlaneSection.isPast(Self.flight(.scheduled), archived: true, now: now))
        #expect(!PlaneSection.isPast(Self.flight(.scheduled), archived: false, now: now))
        #expect(!PlaneSection.isPast(Self.flight(.enRoute), archived: false, now: now))
        // Just landed, the arrival still ahead of the clock: not over yet.
        #expect(!PlaneSection.isPast(arrived, archived: false, now: Self.date("2026-10-02T16:30:00Z")))
    }

    @Test func skyPlace() throws {
        let now = Self.date("2026-11-18T12:00:00Z")
        // Past: the arrival airport at the arrival time, never now.
        let past = try #require(PlaneSection.skyPlace(Self.flight(.arrived), origin: Self.sfo, destination: Self.den,
                                                      isPast: true, now: now))
        #expect(past.coordinate.latitude == Self.den.lat)
        #expect(past.time == Self.date("2026-10-02T16:41:00Z"))
        // Ahead: the departure airport, now.
        let ahead = try #require(PlaneSection.skyPlace(Self.flight(.scheduled), origin: Self.sfo, destination: Self.den,
                                                       isPast: false, now: now))
        #expect(ahead.coordinate.latitude == Self.sfo.lat)
        #expect(ahead.time == now)
        // In the air: the reported position, else the next airport.
        let at = Position(lat: 40, lon: -110, at: now)
        let air = try #require(PlaneSection.skyPlace(Self.flight(.enRoute, position: at), origin: Self.sfo,
                                                     destination: Self.den, isPast: false, now: now))
        #expect(air.coordinate.latitude == 40)
        let blind = try #require(PlaneSection.skyPlace(Self.flight(.enRoute), origin: Self.sfo, destination: Self.den,
                                                       isPast: false, now: now))
        #expect(blind.coordinate.latitude == Self.den.lat)
        #expect(PlaneSection.skyPlace(Self.flight(.scheduled), origin: nil, destination: nil, isPast: false, now: now) == nil)
        // UA 1882 came into Denver at 10:41 local in October: a day sky.
        #expect(PlaneSection.sky(Self.flight(.arrived), origin: Self.sfo, destination: Self.den, isPast: true, now: now) == .day)
    }

    @Test func seededSkyIsStable() {
        #expect(PlaneSky.seed("N47280") == PlaneSky.seed("N47280"))
        #expect(PlaneSky.seed("N47280") != PlaneSky.seed("F-GSQA"))
        let a = PlaneSky.stars(seed: 42), b = PlaneSky.stars(seed: 42)
        #expect(a.map(\.x) == b.map(\.x) && a.map(\.y) == b.map(\.y))
        #expect(a.allSatisfy { (0...1).contains($0.x) && (0.4...0.9).contains($0.y) })
        #expect(PlaneSky.clouds(seed: 42).map(\.y) == PlaneSky.clouds(seed: 42).map(\.y))
        #expect(PlaneSky.stars(seed: 1).map(\.x) != PlaneSky.stars(seed: 2).map(\.x))
    }
}

#if os(macOS)
import AppKit
import SwiftUI

/// Renders the card in each sky, plus the past title, for a look by eye. Off by default:
///
///     SKY_RENDER_DIR=/some/dir swift test --package-path Packages/FlightKit --filter PlaneSkyRenders
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["SKY_RENDER_DIR"] != nil))
struct PlaneSkyRenders {
    @Test func renderEachSky() throws {
        let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SKY_RENDER_DIR"]!)
        let type = try #require(ReferenceData.bundled().type("B39M") ?? ReferenceData.bundled().type("B77W"))
        let flight = PlaneSkyTests.flight(.scheduled)
        let cases: [(String, SkyPhase?, Bool, Bool)] = [("night", .night, false, false), ("dawn", .dawn, false, false),
                                                        ("day", .day, false, false), ("dusk", .dusk, false, false),
                                                        ("past-day", .day, true, false), ("none", nil, false, false)]
        for (name, sky, past, _) in cases {
            for light in [false, true] {
                let view = PlaneSection(flight: flight, type: type, airline: nil, inbound: [], isPast: past, sky: sky)
                    .padding(16)
                    .frame(width: 393)
                    .background(Theme.background)
                    .environment(\.colorScheme, light ? .light : .dark)
                let renderer = ImageRenderer(content: view)
                renderer.scale = 3
                var image: CGImage?
                NSAppearance(named: light ? .aqua : .darkAqua)!.performAsCurrentDrawingAppearance { image = renderer.cgImage }
                let cg = try #require(image)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let rep = NSBitmapImageRep(cgImage: cg)
                try rep.representation(using: .png, properties: [:])!
                    .write(to: dir.appending(path: "plane-\(name)-\(light ? "light" : "dark").png"))
            }
        }
    }
}
#endif
