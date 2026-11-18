import Foundation
import Testing
@testable import FlightKit

/// Lot A of the refined redesign: the home row's status, struck times and offline estimate, and the
/// search examples.
private func date(_ s: String) -> Date { try! Date(s, strategy: .iso8601) }

@MainActor @Suite struct HomeRefinedTests {
    /// AF 84 in the air, left 16 minutes late, landing 11 minutes late.
    static var af84: Flight {
        Flight(providerId: "p", ident: "AFR84", operator: "AFR", originIcao: "LFPG", originIata: "CDG",
               destinationIcao: "KSFO", destinationIata: "SFO",
               scheduledOut: date("2026-11-17T09:00:00Z"), scheduledIn: date("2026-11-17T20:00:00Z"),
               estimatedIn: date("2026-11-17T20:11:00Z"), actualOut: date("2026-11-17T09:16:00Z"),
               status: .enRoute)
    }
    static let now = date("2026-11-17T14:00:00Z")

    @Test func inAirRowHasProgressAndLateStatus() {
        let s = MyFlightRow.status(Self.af84, now: Self.now, origin: nil, destination: nil, clock: .h24, estimated: false)
        #expect(s.text.hasPrefix("Departed 16m late"))
        #expect(s.text.contains("lands"))
        #expect(s.progress != nil)
        #expect(s.level == .late)
    }

    @Test func offlineLandingSaysEstimated() {
        let s = MyFlightRow.status(Self.af84, now: Self.now, origin: nil, destination: nil, clock: .h24, estimated: true)
        #expect(s.text.hasSuffix(" est."))
        var scheduled = Self.af84
        scheduled.status = .scheduled
        scheduled.actualOut = nil
        let t = MyFlightRow.status(scheduled, now: Self.now, origin: nil, destination: nil, clock: .h24, estimated: true)
        #expect(!t.text.hasSuffix(" est."))
    }

    @Test func movedTimesAreStruckAndToned() {
        let f = Self.af84
        #expect(FlightRowEnd.struck(time: f.actualOut, scheduled: f.scheduledOut) == f.scheduledOut)
        #expect(FlightRowEnd.struck(time: f.scheduledOut, scheduled: f.scheduledOut) == nil)
        #expect(FlightRowEnd.struck(time: f.scheduledOut!.addingTimeInterval(30), scheduled: f.scheduledOut) == nil)
        let s = MyFlightRow.status(f, now: Self.now, origin: nil, destination: nil, clock: .h24, estimated: false)
        #expect(MyFlightRow.timeTone(f, time: f.actualOut, scheduled: f.scheduledOut, status: s) == s.tone)
        #expect(MyFlightRow.timeTone(f, time: f.scheduledOut, scheduled: f.scheduledOut, status: s) == nil)
        var canceled = f
        canceled.status = .canceled
        #expect(MyFlightRow.timeTone(canceled, time: f.scheduledOut, scheduled: f.scheduledOut, status: s) == Theme.secondary)
    }

    @Test func examplesReadAsPromised() {
        #expect(SearchExamples.examples == ["AF 84", "SFO to JFK", "84 af tomorrow"])
        #expect(OfflineBanner.Pill.text == "Offline \u{00B7} positions estimated")
    }
}
