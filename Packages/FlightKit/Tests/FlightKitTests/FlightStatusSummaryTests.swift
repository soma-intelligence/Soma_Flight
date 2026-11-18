import Foundation
import Testing
@testable import FlightKit

/// Lot 0 of the refined redesign: the status line's words, level and progress for each case.
private func date(_ s: String) -> Date { try! Date(s, strategy: .iso8601) }

@Suite struct FlightStatusSummaryTests {
    /// Both airports in UTC so the clocks read as written.
    static let cdg = Airport(id: "LFPG", iata: "CDG", name: "Paris Charles de Gaulle", city: "Paris", country: "FR",
                             lat: 49.0, lon: 2.55, tz: "UTC")
    static let sfo = Airport(id: "KSFO", iata: "SFO", name: "San Francisco International", city: "San Francisco",
                             country: "US", lat: 37.6, lon: -122.4, tz: "UTC")
    static let oak = Airport(id: "KOAK", iata: "OAK", name: "Oakland International", city: "Oakland",
                             country: "US", lat: 37.7, lon: -122.2, tz: "UTC")

    /// AF 84, CDG 03:12 to SFO 05:17 (UTC here).
    static var af84: Flight {
        Flight(providerId: "p", ident: "AF84", operator: "AFR", originIcao: "LFPG", originIata: "CDG",
               destinationIcao: "KSFO", destinationIata: "SFO",
               scheduledOut: date("2026-11-17T03:12:00Z"), scheduledIn: date("2026-11-17T05:17:00Z"),
               gateOrigin: "B22", status: .scheduled)
    }

    static let before = date("2026-11-17T01:00:00Z")

    private func make(_ f: Flight, now: Date = before, destination: Airport? = sfo,
                      clock: TimeStyle = .h24) -> FlightStatusSummary {
        FlightStatusSummary.make(for: f, now: now, origin: Self.cdg, destination: destination, clock: clock)
    }

    @Test func scheduledOnlySaysScheduled() {
        let s = make(Self.af84)
        #expect(s.text == "Scheduled · gate B22")
        #expect(s.level == .onTime)
        #expect(s.progress == nil)
    }

    @Test func scheduledOnTimeWithGate() {
        var f = Self.af84
        f.estimatedOut = f.scheduledOut
        #expect(make(f).text == "On time · gate B22")
        #expect(make(f).level == .onTime)
        f.gateOrigin = nil
        #expect(make(f).text == "On time")
        f.gateOrigin = ""
        #expect(make(f).text == "On time")
    }

    @Test func departingLate() {
        var f = Self.af84
        f.estimatedOut = f.scheduledOut!.addingTimeInterval(16 * 60)
        let s = make(f)
        #expect(s.text == "16m late · departs 03:28 · gate B22")
        #expect(s.level == .late)
        #expect(s.progress == nil)
        #expect(make(f, clock: .h12).text.contains("3:28"))

        f.estimatedOut = f.scheduledOut!.addingTimeInterval(65 * 60)
        #expect(make(f).level == .veryLate)
        #expect(make(f).text.hasPrefix("1h 5m late"))
    }

    @Test func departedLateInAir() {
        var f = Self.af84
        f.status = .enRoute
        f.actualOut = f.scheduledOut!.addingTimeInterval(16 * 60)
        f.estimatedIn = date("2026-11-17T05:28:00Z")
        let now = date("2026-11-17T04:20:00Z")
        let s = make(f, now: now)
        #expect(s.text == "Departed 16m late · lands 05:28")
        #expect(s.level == .late)
        let p = try! #require(s.progress)
        #expect(p > 0 && p < 1)
        #expect(abs(p - f.progress(at: now)) < 0.0001)
    }

    @Test func inAirOnTime() {
        var f = Self.af84
        f.status = .enRoute
        f.actualOut = f.scheduledOut
        f.estimatedIn = f.scheduledIn
        let s = make(f, now: date("2026-11-17T04:00:00Z"))
        #expect(s.text == "On time · lands 05:17")
        #expect(s.level == .onTime)
        #expect(s.progress != nil)
    }

    @Test func inAirArrivingLateAfterOnTimeDeparture() {
        var f = Self.af84
        f.status = .enRoute
        f.actualOut = f.scheduledOut
        f.estimatedIn = f.scheduledIn!.addingTimeInterval(48 * 60)
        let s = make(f, now: date("2026-11-17T04:00:00Z"))
        #expect(s.text == "48m late · lands 06:05")
        #expect(s.level == .veryLate)
    }

    @Test func landed() {
        var f = Self.af84
        f.status = .landed
        f.actualIn = f.scheduledIn!.addingTimeInterval(11 * 60)
        #expect(make(f).text == "Landed 11m late")
        #expect(make(f).progress == nil)
        f.actualIn = f.scheduledIn
        #expect(make(f).text == "Landed on time")
        f.actualIn = f.scheduledIn!.addingTimeInterval(-32 * 60)
        #expect(make(f).text == "Landed 32m early")
        #expect(make(f).level == .onTime)
        f.status = .arrived
        f.actualIn = f.scheduledIn!.addingTimeInterval(20 * 60)
        #expect(make(f).text == "Landed 20m late")
        #expect(make(f).level == .late)
        f.actualIn = nil
        #expect(make(f).text == "Landed")
    }

    @Test func canceledIsGrey() {
        var f = Self.af84
        f.status = .canceled
        let s = make(f)
        #expect(s.text == "Canceled")
        #expect(s.level == .canceled)
        #expect(s.progress == nil)
        #expect(s.tone == Theme.canceled, "grey, not red (owner call 2026-11-18)")
        #expect(s.textTone == Theme.canceledText)
    }

    @Test func diverted() {
        var f = Self.af84
        f.status = .diverted
        #expect(make(f, destination: Self.oak).text == "Diverted to OAK")
        #expect(make(f, destination: Self.oak).level == .diverted)
        #expect(make(f, destination: Self.sfo).text == "Diverted")
        #expect(make(f, destination: nil).text == "Diverted")
        #expect(make(f).tone == Theme.diverted)
    }
}
