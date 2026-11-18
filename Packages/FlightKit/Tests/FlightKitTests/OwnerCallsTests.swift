import Foundation
import SwiftUI
import Testing
@testable import FlightKit

/// The owner's calls of 2026-11-18 after the premium audit: an airport direction reads Moderate from a
/// 10 min average or more than a quarter of its flights late, and a canceled flight is grey, not red.
@MainActor @Suite struct OwnerCallsTests {
    func perf(total: Int, delayed: Int, avg: Int) -> AirportPerformance {
        AirportPerformance(total: total, onTime: total - delayed, delayed: delayed, canceled: 0,
                           avgDelayMinutes: avg, trend: [])
    }

    @Test func moderateFromTenMinutesOrAQuarterLate() {
        #expect(perf(total: 100, delayed: 10, avg: 9).delayStats.severity == .normal)
        #expect(perf(total: 100, delayed: 10, avg: 10).delayStats.severity == .moderate)
        #expect(perf(total: 100, delayed: 25, avg: 5).delayStats.severity == .normal, "a quarter exactly stays Calm")
        #expect(perf(total: 100, delayed: 26, avg: 5).delayStats.severity == .moderate)
        // The seed's SFO: 11 min average and 53 of 156 late no longer read "Calm".
        #expect(PreviewData.stats("KSFO").severity == .moderate)
        #expect(AirportStatus.board(AirportBrief(total: 100, onTime: 90, delayed: 10, canceled: 0, avgDelayMinutes: 10),
                                    "Departures").level == .minor)
    }

    @Test func canceledIsGreyEverywhere() {
        #expect(FlightStatusSummary.tone(for: .canceled) == Theme.canceled)
        #expect(FlightStatusSummary.textTone(for: .canceled) == Theme.canceledText)
        let f = PreviewData.canceled
        #expect(FriendFacts.status(f, now: PreviewData.now).color == Theme.canceledText)
        #expect(FriendFacts.when(f, now: PreviewData.now).color == Theme.canceledText)
    }
}
