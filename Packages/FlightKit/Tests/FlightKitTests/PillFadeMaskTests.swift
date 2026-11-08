import Testing
@testable import FlightKit

@Suite struct PillFadeMaskTests {
    @Test func fadeSpansTheFadeAndThePillsUpperHalf() {
        #expect(PillFadeMask.fadeHeight(pillHeight: 60) == 74)
    }

    @Test func sheetPillCountsTheInsetItReachesInto() {
        // 34 pt home indicator, the pill 14 pt into it: the clear part is the pill's half plus 20.
        #expect(PillFadeMask.clearHeight(pillHeight: 60, bottomInset: 34, reachesIntoInset: true) == 50)
    }

    @Test func panelPillClearsFromItsMiddle() {
        #expect(PillFadeMask.clearHeight(pillHeight: 60, bottomInset: 34, reachesIntoInset: false) == 30)
    }

    @Test func clearPartNeverGoesNegative() {
        #expect(PillFadeMask.clearHeight(pillHeight: 10, bottomInset: 0, reachesIntoInset: true) == 0)
    }
}
