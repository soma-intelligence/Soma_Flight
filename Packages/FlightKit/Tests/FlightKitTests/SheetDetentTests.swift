import SwiftUI
import Testing
@testable import FlightKit

/// The home sheet's three detents: where each rests on a few iPhones, and where a drag lands.
@Suite struct SheetDetentTests {
    /// iPhone 17 Pro: 874 pt tall, 62 pt status bar, 34 pt home indicator.
    let pro = SheetGeometry.standard
    /// iPhone 17 Pro Max (the owner's references): 956 pt.
    let proMax = SheetGeometry(screenHeight: 956, safeTop: 62, safeBottom: 34)
    /// iPhone SE: 667 pt, a 20 pt status bar and no home indicator.
    let se = SheetGeometry(screenHeight: 667, safeTop: 20, safeBottom: 0)

    @Test func fractionsBecomePointsOnEachScreen() {
        #expect(pro.top(of: .expanded) == 62)
        #expect(pro.top(of: .medium) == 373)
        #expect(pro.top(of: .collapsed) == 583)
        #expect(pro.height(of: .medium) == 501)
        #expect(pro.height(of: .collapsed) == 291)

        #expect(proMax.top(of: .expanded) == 62)
        #expect(proMax.top(of: .medium) == 406)
        #expect(proMax.top(of: .collapsed) == 638)

        #expect(se.top(of: .expanded) == 20)
        #expect(se.top(of: .medium) == 279)
        #expect(se.top(of: .collapsed) == 453)
        // A short screen with a home indicator: 67% would leave too little, so the collapsed sheet keeps
        // room for its header, one peek row and the pill.
        let short = SheetGeometry(screenHeight: 600, safeTop: 50, safeBottom: 34)
        #expect(short.top(of: .collapsed) == 600 - 34 - SheetGeometry.minimumCollapsedContent)
    }

    /// Collapsed shows the pinned header and one peek row above the tab pill, never less, and the content
    /// mask ends above the pill.
    @Test func collapsedKeepsTheHeaderAndOnePeekRowAboveTheTabBar() {
        for g in [pro, proMax, se, SheetGeometry(screenHeight: 600, safeTop: 50, safeBottom: 34)] {
            let room = g.contentRoom(in: .collapsed)
            #expect(room >= SheetGeometry.peekRowHeight)
            // The header's bottom, then the room, then the pill and the home indicator: the screen's bottom.
            let headerBottom = g.top(of: .collapsed) + SheetGeometry.headerHeight
            #expect(headerBottom + room + SheetGeometry.tabBarHeight + g.safeBottom == g.screenHeight)
            // Medium and expanded give more room, never less.
            #expect(g.contentRoom(in: .medium) > room)
            #expect(g.contentRoom(in: .expanded) > g.contentRoom(in: .medium))
        }
    }

    /// The references put the medium top at about 43% of the screen and collapsed at about 67%.
    @Test func topsMatchTheReferencesOnTallPhones() {
        for g in [pro, proMax] {
            #expect(abs(g.top(of: .medium) / g.screenHeight - 0.43) < 0.01)
            #expect(abs(g.top(of: .collapsed) / g.screenHeight - 0.67) < 0.01)
        }
    }

    @Test func detentsStayOrderedAndApartOnEveryScreen() {
        for height in stride(from: 560, through: 1000, by: 20) {
            let g = SheetGeometry(screenHeight: CGFloat(height), safeTop: 59, safeBottom: 34)
            #expect(g.top(of: .expanded) < g.top(of: .medium))
            #expect(g.top(of: .collapsed) - g.top(of: .medium) >= SheetGeometry.minimumStep)
            #expect(g.height(of: .collapsed) - g.safeBottom >= SheetGeometry.minimumCollapsedContent)
        }
    }

    @Test func aSlowReleaseSnapsToTheNearestDetent() {
        #expect(pro.snap(top: 300, velocity: 0) == .medium)
        #expect(pro.snap(top: 150, velocity: 0) == .expanded)
        #expect(pro.snap(top: 470, velocity: 0) == .medium)
        #expect(pro.snap(top: 480, velocity: 0) == .collapsed)
        #expect(pro.snap(top: 900, velocity: 0) == .collapsed)
        #expect(pro.nearest(toTop: -40) == .expanded)
    }

    @Test func aFlingCarriesTheSheetInItsDirection() {
        // Up hard from near medium: past it to expanded.
        #expect(pro.snap(top: 300, velocity: -2000) == .expanded)
        // Down from medium: to collapsed.
        #expect(pro.snap(top: 400, velocity: 1500) == .collapsed)
        // A gentle push tips a sheet that sits between two detents.
        #expect(pro.snap(top: 450, velocity: 200) == .collapsed)
        #expect(pro.snap(top: 450, velocity: -200) == .medium)
        // From the top, a flick down skips back to medium rather than past it.
        #expect(pro.snap(top: 62, velocity: 1200) == .medium)
    }

    @Test func systemDetentsRoundTrip() {
        #expect(pro.presentationDetent(for: .expanded) == .large)
        #expect(pro.presentationDetent(for: .medium) == .height(501))
        #expect(pro.presentationDetents.count == 3)
        for d in SheetDetent.allCases { #expect(pro.detent(for: pro.presentationDetent(for: d)) == d) }
        // A height left from another screen size reads as medium.
        #expect(pro.detent(for: .height(123)) == .medium)
    }

    @Test func stepsUpAndDown() {
        #expect(SheetDetent.collapsed.raised == .medium)
        #expect(SheetDetent.medium.raised == .expanded)
        #expect(SheetDetent.expanded.raised == nil)
        #expect(SheetDetent.expanded.lowered == .medium)
        #expect(SheetDetent.collapsed.lowered == nil)
    }
}
