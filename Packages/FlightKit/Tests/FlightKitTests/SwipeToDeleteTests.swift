import CoreGraphics
import Testing
@testable import FlightKit

/// Where a My Flights row lands when the finger lets go.
@Suite struct SwipeToDeleteTests {
    let width: CGFloat = 370

    @Test func aShortPullSnapsBackClosed() {
        #expect(SwipeToDelete.outcome(offset: -20, predicted: -30, width: width) == .closed)
    }

    @Test func aMediumPullOpensTheButton() {
        #expect(SwipeToDelete.outcome(offset: -70, predicted: -80, width: width) == .open)
        // A light flick opens it too.
        #expect(SwipeToDelete.outcome(offset: -30, predicted: -140, width: width) == .open)
    }

    @Test func aLongOrFastPullDeletes() {
        #expect(SwipeToDelete.outcome(offset: -220, predicted: -230, width: width) == .delete)
        #expect(SwipeToDelete.outcome(offset: -90, predicted: -400, width: width) == .delete)
    }

    @Test func aPullRightNeverDeletes() {
        #expect(SwipeToDelete.outcome(offset: 10, predicted: 200, width: width) == .closed)
        #expect(SwipeToDelete.outcome(offset: -200, predicted: -200, width: 0) == .closed)
    }
}
