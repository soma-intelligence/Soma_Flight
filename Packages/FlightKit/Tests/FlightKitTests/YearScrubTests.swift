import Testing
import CoreGraphics
@testable import FlightKit

@Suite struct YearScrubTests {
    /// Three chips 60 pt wide with 4 pt gaps: All-Time, 2026, 2025.
    private let spans: [ClosedRange<CGFloat>] = [0...60, 64...124, 128...188]

    @Test func optionsStartWithAllTime() {
        #expect(YearScrub.options([2026, 2025]) == [nil, 2026, 2025])
        #expect(YearScrub.options([]) == [nil])
    }

    @Test func indexOfSelection() {
        let options = YearScrub.options([2026, 2025])
        #expect(YearScrub.index(of: nil, in: options) == 0)
        #expect(YearScrub.index(of: 2025, in: options) == 2)
        #expect(YearScrub.index(of: 2019, in: options) == nil)
    }

    @Test func scrollIds() {
        #expect(YearScrub.id(nil) == 0)
        #expect(YearScrub.id(2024) == 2024)
    }

    @Test func pointOnAChipPicksIt() {
        #expect(YearScrub.index(atX: 30, spans: spans) == 0)
        #expect(YearScrub.index(atX: 64, spans: spans) == 1)
        #expect(YearScrub.index(atX: 188, spans: spans) == 2)
    }

    @Test func pointInAGapPicksTheNearerChip() {
        #expect(YearScrub.index(atX: 61, spans: spans) == 0)
        #expect(YearScrub.index(atX: 63, spans: spans) == 1)
    }

    @Test func pointPastTheEndsPicksTheEndChip() {
        #expect(YearScrub.index(atX: -40, spans: spans) == 0)
        #expect(YearScrub.index(atX: 500, spans: spans) == 2)
    }

    @Test func noChipsNoIndex() {
        #expect(YearScrub.index(atX: 10, spans: []) == nil)
    }

    @Test func reduceMotionHasItsOwnCurve() {
        #expect(PeriodMotion.animation(reduceMotion: true) != PeriodMotion.animation(reduceMotion: false))
    }
}
