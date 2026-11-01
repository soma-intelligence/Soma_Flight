import CoreGraphics
import Foundation
import Testing
@testable import FlightKit

/// The past flight's page zooms out of its Passport row: the numbers of the row end of that zoom, which
/// cards zoom, and the swipe back.
@MainActor
struct CardZoomTests {
    let container = CGSize(width: 400, height: 800)

    @Test func rowEndSitsOnTheRow() {
        let row = CGRect(x: 0, y: 300, width: 400, height: 70)
        let g = CardZoomGeometry(row: row, container: container)
        #expect(g.scale == 1)
        #expect(g.offset == CGSize(width: 0, height: 300))
        // Only the top of the card, the row's height, shows.
        #expect(g.visible == CGRect(x: 0, y: 0, width: 400, height: 70))
        #expect(g.radius == CardZoomGeometry.rowRadius)
    }

    @Test func narrowerRowScalesTheCard() {
        let row = CGRect(x: 20, y: 100, width: 200, height: 60)
        let g = CardZoomGeometry(row: row, container: container)
        #expect(g.scale == 0.5)
        #expect(g.offset == CGSize(width: 20, height: 100))
        // 60 points on screen at half scale: 120 of the card's own.
        #expect(g.visible.height == 120)
        // The corners read rowRadius once scaled.
        #expect(g.radius * g.scale == CardZoomGeometry.rowRadius)
    }

    @Test func identityCutsNothing() {
        let g = CardZoomGeometry(identity: container)
        #expect(g.scale == 1 && g.offset == .zero && g.radius == 0)
        let rect = CGRect(origin: .zero, size: container)
        #expect(CardZoomMask.isOpen(visible: g.visible, radius: g.radius, in: rect))
        // The open mask reaches past the card, so the safe areas still draw.
        let path = CardZoomMask(visible: g.visible, radius: g.radius).path(in: rect)
        #expect(path.boundingRect.contains(rect.insetBy(dx: -100, dy: -100)))
        let row = CardZoomGeometry(row: CGRect(x: 0, y: 0, width: 400, height: 70), container: container)
        #expect(!CardZoomMask.isOpen(visible: row.visible, radius: row.radius, in: rect))
    }

    @Test func onlyPastFlightsZoom() {
        let past = PastFlight(date: Date(timeIntervalSince1970: 0), ident: "UA984", originIcao: "LFPG",
                              destinationIcao: "KSFO", distanceKm: 8_950)
        #expect(SheetRoute.pastFlight(past).zoomID == AnyHashable(past.id))
        #expect(SheetRoute.airport("KSFO").zoomID == nil)
        #expect(SheetRoute.airports.zoomID == nil)
    }

    @Test func sourcesForgetARowThatLeaves() {
        let sources = CardZoomSources()
        let id = UUID()
        sources.set(id, CGRect(x: 0, y: 10, width: 300, height: 60))
        #expect(sources.frame(id)?.minY == 10)
        sources.set(id, nil)
        #expect(sources.frame(id) == nil)
    }

    @Test func pullProgressIsClamped() {
        #expect(PullBack.progress(pull: 0, width: 400) == 0)
        #expect(PullBack.progress(pull: 200, width: 400) == 0.5)
        #expect(PullBack.progress(pull: 900, width: 400) == 1)
        #expect(PullBack.progress(pull: 50, width: 0) == 0)
    }
}
