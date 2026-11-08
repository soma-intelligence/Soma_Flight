import CoreLocation
import Foundation
import Testing
@testable import FlightKit

/// The sun from the plane: NOAA solar position (`SolarPosition`), sunrises and sunsets along an estimated
/// route (`SunInFlight`) and the card's words (`SunFacts`).
@Suite struct SunInFlightTests {
    static func date(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }
    let lookup = AirportDirectory.bundled()

    func route(_ a: String, _ b: String, _ off: String, _ on: String) throws -> RouteEstimator {
        let o = try #require(lookup.airport(a)), d = try #require(lookup.airport(b))
        return try #require(RouteEstimator(origin: o.coordinate, destination: d.coordinate,
                                           takeoff: Self.date(off), landing: Self.date(on)))
    }

    // MARK: Solar position

    @Test func matchesTheNRELReferenceSun() {
        // Reda and Andreas, "Solar Position Algorithm for Solar Radiation Applications" (NREL, 2004),
        // the worked example: Golden, Colorado, 2003-10-17 12:30:30 local (UTC-7). Topocentric zenith
        // 50.11162 (with 0.016 degree of refraction at 820 mbar), azimuth 194.34024.
        let s = sun(at: Self.date("2003-10-17T19:30:30Z"), coord: CLLocationCoordinate2D(latitude: 39.742476, longitude: -105.1786))
        #expect(abs(s.geometricElevation - (90 - 50.11162 - 0.016)) < 0.1)
        #expect(abs(s.azimuth - 194.34024) < 0.1)
        #expect(s.elevation > s.geometricElevation)
    }

    @Test func matchesNOAAsDeclinationAndEquationOfTime() {
        let zero = CLLocationCoordinate2D(latitude: 0, longitude: 0)
        // June solstice 2026-06-21 08:24 UTC: declination at its maximum, 23.44 degrees.
        #expect(abs(sun(at: Self.date("2026-06-21T08:24:00Z"), coord: zero).declination - 23.44) < 0.05)
        // Early November the sundial runs about 16.4 minutes fast, the year's peak.
        let eot = sun(at: Self.date("2026-11-03T12:00:00Z"), coord: zero).equationOfTimeMinutes
        #expect(abs(eot - 16.4) < 0.3)
        // At the equinox the sun stands over the equator at noon: elevation near 90.
        let noon = sun(at: Self.date("2026-03-20T12:07:00Z"), coord: zero)
        #expect(noon.geometricElevation > 89)
    }

    @Test func groundSunriseAndSunsetMatchTheAlmanac() {
        // A fix every minute at one place on the ground gives the almanac's times.
        func events(_ c: CLLocationCoordinate2D, from start: String) -> [SunEvent] {
            let t0 = Self.date(start)
            let fixes = (0...1440).map {
                RouteFix(time: t0.addingTimeInterval(Double($0) * 60), coordinate: c, heading: 0, phase: .cruise,
                         distanceKm: 0, altitudeM: 0)
            }
            return SunInFlight.events(along: fixes)
        }
        // Paris on the June solstice: sunrise 05:47 CEST (03:47 UTC), sunset 21:58 CEST (19:58 UTC).
        let paris = events(CLLocationCoordinate2D(latitude: 48.8566, longitude: 2.3522), from: "2026-06-21T00:00:00Z")
        #expect(paris.map(\.kind) == [.sunrise, .sunset])
        #expect(abs(paris[0].time.timeIntervalSince(Self.date("2026-06-21T03:47:00Z"))) < 180)
        #expect(abs(paris[1].time.timeIntervalSince(Self.date("2026-06-21T19:58:00Z"))) < 180)
        // New York on the December solstice: sunset 16:32 EST (21:32 UTC).
        let ny = events(CLLocationCoordinate2D(latitude: 40.7128, longitude: -74.006), from: "2026-12-21T12:00:00Z")
        let sunset = ny.first { $0.kind == .sunset }
        #expect(sunset.map { abs($0.time.timeIntervalSince(Self.date("2026-12-21T21:32:00Z"))) < 180 } == true)
    }

    @Test func fromElevenKilometresTheHorizonDipsAboutThreeAndAHalfDegrees() {
        #expect(abs(SunInFlight.horizonDip(altitudeM: 11_000) - 3.36) < 0.05)
        #expect(SunInFlight.horizonDip(altitudeM: 0) == 0)
        #expect(SunInFlight.horizon(altitudeM: 0) == -0.833)
    }

    // MARK: Events along a route

    @Test func anOvernightFlightSeesTheSunSetThenRise() throws {
        // New York to Tel Aviv, leaving at 16:00 EST in November, landing next morning.
        let r = try route("KJFK", "LLBG", "2026-11-08T21:00:00Z", "2026-11-09T07:00:00Z")
        let events = SunInFlight.events(for: r)
        #expect(events.map(\.kind) == [.sunset, .sunrise])
        let sunset = try #require(events.first), sunrise = try #require(events.last)
        #expect(sunset.fraction < 0.2)
        #expect(sunrise.fraction > 0.6)
        // Up there the sun sets later than on the ground: New York's sunset is 16:42 EST that day.
        #expect(sunset.time > Self.date("2026-11-08T21:30:00Z"))
        // Into the sunrise, out of the sunset: east and west of the plane's heading.
        #expect(sunrise.azimuth > 60 && sunrise.azimuth < 140)
        #expect(sunset.azimuth > 220 && sunset.azimuth < 280)
    }

    @Test func parisToTokyoOvernightSeesSunriseOverRussiaAndSunsetBeforeLanding() throws {
        let r = try route("LFPG", "RJAA", "2026-11-08T21:30:00Z", "2026-11-09T09:00:00Z")
        let events = SunInFlight.events(for: r)
        #expect(events.map(\.kind) == [.sunrise, .sunset])
        #expect(RegionNamer.bundled.region(at: events[0].coordinate)?.name == "Russia")
    }

    @Test func aPolarFlightUnderTheMidnightSunHasNoEvent() throws {
        // Tromso to Longyearbyen on the June solstice: the sun never sets that far north.
        let r = try route("ENTC", "ENSB", "2026-06-21T22:00:00Z", "2026-06-21T23:35:00Z")
        #expect(SunInFlight.events(for: r).isEmpty)
    }

    @Test func aShortDaytimeHopHasNoEvent() throws {
        let r = try route("EGLL", "LFPG", "2026-06-21T10:00:00Z", "2026-06-21T11:00:00Z")
        #expect(SunInFlight.events(for: r).isEmpty)
    }

    // MARK: Words

    @Test func eachLineNamesTheRegionAndTheNearerAirportsTime() throws {
        let jfk = try #require(lookup.airport("KJFK")), tlv = try #require(lookup.airport("LLBG"))
        let r = try route("KJFK", "LLBG", "2026-11-08T21:00:00Z", "2026-11-09T07:00:00Z")
        let lines = SunFacts.lines(SunInFlight.events(for: r), origin: jfk, destination: tlv, clock: .h24)
        #expect(lines.count == 2)
        let first = try #require(lines.first?.text), last = try #require(lines.last?.text)
        #expect(first.hasPrefix("Sunset over "))
        #expect(first.hasSuffix(" \(jfk.city) time"))
        #expect(last.hasPrefix("Sunrise over "))
        #expect(last.hasSuffix(" \(tlv.city) time"))
        for line in lines { #expect(!line.text.contains("\u{2014}")) }
    }

    @Test func aCanceledFlightHasNoSunCard() throws {
        let jfk = try #require(lookup.airport("KJFK")), tlv = try #require(lookup.airport("LLBG"))
        var f = Flight(providerId: "LY8", ident: "LY8", originIcao: "KJFK", destinationIcao: "LLBG",
                       scheduledOut: Self.date("2026-11-08T20:45:00Z"), scheduledIn: Self.date("2026-11-09T07:10:00Z"))
        #expect(!SunFacts.events(f, origin: jfk, destination: tlv, aircraft: nil).isEmpty)
        f.status = .canceled
        #expect(SunFacts.events(f, origin: jfk, destination: tlv, aircraft: nil).isEmpty)
        #expect(SunFacts.events(f, origin: nil, destination: tlv, aircraft: nil).isEmpty)
    }
}
