import Foundation
import Testing
@testable import FlightKit

/// Lot B of the refined redesign: the flight sheet's hero card (R3), the refresh error (R8) and the airport's
/// severity card (R7) say the right words in the right colour.
private func date(_ s: String) -> Date { try! Date(s, strategy: .iso8601) }

@MainActor @Suite struct DetailHeroTests {
    static let cdg = Airport(id: "LFPG", iata: "CDG", name: "Paris Charles de Gaulle", city: "Paris", country: "FR",
                             lat: 49.0, lon: 2.55, tz: "UTC")
    static let sfo = Airport(id: "KSFO", iata: "SFO", name: "San Francisco International", city: "San Francisco",
                             country: "US", lat: 37.6, lon: -122.4, tz: "UTC")
    static let oak = Airport(id: "KOAK", iata: "OAK", name: "Oakland International", city: "Oakland",
                             country: "US", lat: 37.7, lon: -122.2, tz: "UTC")
    static let airFrance = Airline(id: "AFR", iata: "AF", name: "Air France", colorPrimary: "#002157")

    /// AF 84, CDG 02:56 to SFO 05:06 scheduled (UTC here).
    static var af84: Flight {
        Flight(providerId: "p", ident: "AF84", operator: "AFR", originIcao: "LFPG", originIata: "CDG",
               destinationIcao: "KSFO", destinationIata: "SFO",
               scheduledOut: date("2026-11-17T02:56:00Z"), scheduledIn: date("2026-11-17T14:01:00Z"),
               gateOrigin: "B22", status: .scheduled)
    }

    private func hero(_ f: Flight, now: Date, actual: Airport? = sfo, airline: Airline? = airFrance) -> HeroFacts {
        HeroFacts.make(f, airline: airline, origin: Self.cdg, planned: Self.sfo, actual: actual, prediction: nil,
                       unit: .km, clock: .h24, now: now)
    }

    /// The board: departed 16m late, landing 11m late, 6h 49m to go. The colour is the home row's (late).
    @Test func inTheAirMatchesTheBoard() {
        var f = Self.af84
        f.status = .enRoute
        f.actualOut = date("2026-11-17T03:12:00Z")
        f.estimatedIn = date("2026-11-17T14:12:00Z")
        let now = date("2026-11-17T07:23:00Z")
        let h = hero(f, now: now)
        #expect(h.headline == "Landing 11m late")
        #expect(h.subline == "Air France · in the air · arrives in 6h 49m")
        #expect(h.note == "Airline estimate")
        #expect(h.level == FlightStatusSummary.make(for: f, now: now, origin: Self.cdg, destination: Self.sfo).level)
        #expect(h.level == .late)
        #expect(h.showsGrid)
        #expect((h.progress ?? 0) > 0 && (h.progress ?? 1) < 1)
    }

    @Test func scheduledSaysWhenItLeaves() {
        let h = hero(Self.af84, now: date("2026-11-16T23:36:00Z"), airline: nil)
        #expect(h.headline == "On time so far")
        #expect(h.subline == "scheduled · departs in 3h 20m")
        #expect(h.note == "No sign of a delay yet")
        #expect(h.progress == 0)
        #expect(h.level == .onTime)
    }

    @Test func canceledKeepsTheNoticeAndHidesTheGrid() {
        var f = Self.af84
        f.status = .canceled
        let h = hero(f, now: date("2026-11-17T01:00:00Z"))
        #expect(h.headline == "Canceled")
        #expect(h.subline == "Air France")
        #expect(h.note == HeroFacts.canceledNote)
        #expect(h.level == .canceled)
        #expect(h.progress == nil)
        #expect(!h.showsGrid)
    }

    @Test func divertedNamesTheNewAirport() {
        var f = Self.af84
        f.status = .diverted
        let h = hero(f, now: date("2026-11-17T10:00:00Z"), actual: Self.oak)
        #expect(h.headline == "Diverted to OAK")
        #expect(h.note == "Landing at Oakland (OAK) instead of SFO.")
        #expect(h.level == .diverted)
        let unknown = hero(f, now: date("2026-11-17T10:00:00Z"), actual: Self.sfo)
        #expect(unknown.headline == "Diverted")
        #expect(unknown.note == "Not landing at SFO. The new airport is not known yet.")
    }

    @Test func landedSaysHowTheTripWent() {
        var f = Self.af84
        f.status = .arrived
        f.actualOut = date("2026-11-17T02:56:00Z")
        f.actualIn = date("2026-11-17T14:04:00Z")
        let h = hero(f, now: date("2026-11-17T15:00:00Z"))
        #expect(h.headline == "Arrived 3m late")
        #expect(h.subline?.hasPrefix("Air France · at the gate · total 11h 08m") == true)
        #expect(h.progress == 1)
    }

    /// The hero's freshness goes through `Format.ago` now (A1): under a minute stays "just now".
    @Test func ages() {
        let t = date("2026-11-17T10:00:00Z")
        #expect(Format.ago(t, now: t.addingTimeInterval(30)) == "just now")
        #expect(Format.ago(t, now: t.addingTimeInterval(4 * 60 + 10)) != "just now")
    }

    @Test func refreshErrorSubtitle() {
        let t = date("2026-11-17T10:00:00Z")
        #expect(RefreshErrorCard.subtitle(.providerUnavailable, updatedAt: t, now: t.addingTimeInterval(240))
                == "Last updated 4 min. ago")
        #expect(RefreshErrorCard.subtitle(.offline, updatedAt: t, now: t.addingTimeInterval(20))
                == "Offline · last updated just now")
    }

    @Test func severityWords() {
        #expect(AirportSeverityFacts.word(.major) == "Major")
        #expect(AirportSeverityFacts.word(.moderate) == "Moderate")
        #expect(AirportSeverityFacts.word(.normal) == "Calm")
        #expect(AirportSeverityFacts.subline(causes: 5, updated: "22:28") == "5 causes · updated 22:28")
        #expect(AirportSeverityFacts.subline(causes: 1, updated: nil) == "1 cause")
        let rows = [AdvisoryRowData(symbol: "hourglass", title: "Ground delay program at SFO", text: "Average 47m",
                                    severity: .major)]
        let causes = AirportSeverityFacts.causes(departures: nil, arrivals: nil, weather: nil, programs: rows)
        #expect(causes == [.init(title: "Ground delay program at SFO", level: .major, text: "Average 47m")])
    }

    @Test func airportOverline() {
        #expect(AirportHeader.overline(Self.sfo, code: "KSFO", time: "22:28 PST") == "SFO · KSFO · 22:28 PST")
        #expect(AirportHeader.overline(nil, code: "KSFO", time: nil) == "KSFO")
    }
}
