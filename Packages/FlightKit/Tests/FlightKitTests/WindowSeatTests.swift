import CoreLocation
import Foundation
import Testing
@testable import FlightKit

/// Window side: which side to sit on for the sunrise or sunset, the landmarks and the shade
/// (`WindowAdvisor`), the seat letter's side, and the card's words (`WindowFacts`).
@Suite struct WindowSeatTests {
    static func date(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }
    let lookup = AirportDirectory.bundled()

    func route(_ a: String, _ b: String, _ off: String, _ on: String) throws -> RouteEstimator {
        let o = try #require(lookup.airport(a)), d = try #require(lookup.airport(b))
        return try #require(RouteEstimator(origin: o.coordinate, destination: d.coordinate,
                                           takeoff: Self.date(off), landing: Self.date(on)))
    }

    func advice(_ r: RouteEstimator, table: LandmarkTable = .bundled) -> WindowAdvice? {
        WindowAdvisor.advice(for: r, passes: Landmarks.passes(for: r, table: table),
                             events: SunInFlight.events(for: r), regions: .bundled)
    }

    @Test func aWestboundEveningFlightSeesTheSunsetOnTheRight() throws {
        // London to New York on a June evening: the plane chases the sun, which sets in the north-west,
        // to the right of a south-westerly track. No landmarks, so only the sun decides.
        let r = try route("EGLL", "KJFK", "2026-06-21T18:00:00Z", "2026-06-22T01:30:00Z")
        let events = SunInFlight.events(for: r)
        #expect(events.map(\.kind) == [.sunset])
        let a = try #require(WindowAdvisor.advice(for: r, passes: [], events: events, regions: .bundled))
        #expect(a.side == .right)
        #expect(a.reasons.contains { if case .sunset = $0 { true } else { false } })
        let card = WindowFacts.card(a, seat: nil, family: .b777)
        #expect(card.headline.hasPrefix("Sit on the right for the sunset"), "\(card.headline)")
        #expect(card.lines.first == "Window seats on the right take the row's last letter: F on most single-aisle planes, K on most twin-aisle ones.")
    }

    @Test func anEastboundEveningFlightSeesTheSunsetBehindOnTheLeft() throws {
        // New York to Tel Aviv leaving at 16:00 EST in November: the sun sets behind, south-west, on the left.
        let r = try route("KJFK", "LLBG", "2026-11-08T21:00:00Z", "2026-11-09T07:00:00Z")
        let events = SunInFlight.events(for: r)
        let sunset = try #require(events.first { $0.kind == .sunset })
        #expect(WindowSide.of(bearing: sunset.azimuth, heading: sunset.heading) == .left)
    }

    @Test func aSouthboundMorningFlightHasTheSunOnTheLeft() throws {
        // New York to Miami, 09:00 to 12:00 EDT in July: heading about south-south-west, the morning sun in
        // the east and south-east, so on the left most of the way; the right side is in the shade.
        let r = try route("KJFK", "KMIA", "2026-07-01T13:00:00Z", "2026-07-01T15:45:00Z")
        #expect(WindowAdvisor.sunSide(track: r.track(every: 60), step: 60) == .left)
        // Without landmarks the shade decides.
        let a = try #require(WindowAdvisor.advice(for: r, passes: [], events: SunInFlight.events(for: r), regions: nil))
        #expect(a.side == .right)
        #expect(a.reasons == [.shade])
        let card = WindowFacts.card(a, seat: nil, family: .a320)
        #expect(card.headline == "Sit on the right for the shade")
        #expect(card.lines.contains("The sun stays on the left for most of the day, so the right side is in the shade."))
    }

    @Test func thePeaksOnOneSidePickIt() throws {
        // Milan to London with the Valais peaks (left) against the Eiger alone (right).
        let all = LandmarkTable.bundled
        let table = LandmarkTable(["Matterhorn", "Dom", "Weisshorn", "Eiger"].compactMap { all.named($0) })
        #expect(table.landmarks.count == 4)
        let r = try route("LIMC", "EGLL", "2026-07-01T09:00:00Z", "2026-07-01T11:00:00Z")
        let a = try #require(advice(r, table: table))
        #expect(a.otherSide == ["Eiger"])
        #expect(a.side == .left)
        let names = a.reasons.compactMap { if case .landmarks(let n) = $0 { n } else { nil } }.flatMap { $0 }
        #expect(!names.isEmpty)
        let card = WindowFacts.card(a, seat: nil, family: .a320)
        #expect(card.headline.hasPrefix("Sit on the left for "))
        #expect(card.lines.first == "Window seats on the left are lettered A on most aircraft.")
    }

    @Test func theTravellersSeatIsOnTheGoodOrTheBadSide() {
        let a = WindowAdvice(side: .left, reasons: [.sunset(region: "over the North Atlantic"), .landmarks(["Mont Blanc"])],
                             otherSide: ["Lake Geneva"], sunSide: nil)
        let good = WindowFacts.card(a, seat: "23A", family: .a320)
        #expect(good.headline == "Sit on the left for the sunset over the North Atlantic and Mont Blanc")
        #expect(good.lines.contains("Your seat 23A is on the left, the good side."))
        #expect(good.lines.contains("On the right: Lake Geneva."))
        let bad = WindowFacts.card(a, seat: "23F", family: .a320)
        #expect(bad.lines.contains("Your seat 23F is on the right. A seat on the left gets the better view."))
        let middle = WindowFacts.card(a, seat: "41E", family: .b777)
        #expect(middle.lines.contains("Your seat 41E is in the middle block, away from the windows."))
        // A middle letter on an unknown type says nothing about the seat.
        #expect(!WindowFacts.card(a, seat: "41E", family: nil).lines.contains { $0.hasPrefix("Your seat") })
    }

    @Test func seatLettersMapToSides() {
        #expect(WindowAdvisor.seatSide("12A", family: .a320) == .left)
        #expect(WindowAdvisor.seatSide("12C", family: .b787) == .left)
        #expect(WindowAdvisor.seatSide("12F", family: .b737) == .right)
        #expect(WindowAdvisor.seatSide("12D", family: .ejet) == .right)
        // Four abreast (A B | C D): C sits on the right.
        #expect(WindowAdvisor.seatSide("12C", family: .atr) == .right)
        #expect(WindowAdvisor.seatSide("12C", family: .crj) == .right)
        #expect(WindowAdvisor.seatSide("12C", family: .ejet) == .right)
        #expect(WindowAdvisor.seatSide("12B", family: .atr) == .left)
        #expect(WindowAdvisor.seatSide("12C", family: .a320) == .left)
        #expect(WindowAdvisor.seatSide("12C", family: nil) == .left)
        #expect(WindowAdvisor.seatSide("12K", family: .a350) == .right)
        #expect(WindowAdvisor.seatSide("12K", family: nil) == .right)
        #expect(WindowAdvisor.seatSide("12E", family: .a380) == .center)
        #expect(WindowAdvisor.seatSide("12E", family: .other) == nil)
        #expect(WindowAdvisor.seatSide("12", family: .a320) == nil)
    }

    @Test func nothingNotableGivesNoAdvice() throws {
        #expect(WindowAdvisor.advice(track: [], passes: [], events: [], regions: nil, step: 60) == nil)
        // A night hop with no sights in the table: no sun, nothing to see.
        let r = try route("LSGG", "EGLL", "2026-01-15T00:00:00Z", "2026-01-15T01:20:00Z")
        #expect(advice(r, table: LandmarkTable([])) == nil)
        // A sight dead ahead counts for neither side.
        let t0 = Self.date("2026-01-15T00:00:00Z")
        let ahead = LandmarkPass(landmark: Landmark(name: "X", kind: .mountain, lat: 0, lon: 0, radiusKm: 50), time: t0,
                                 distanceKm: 2, side: .below, fraction: 0.5, altitudeM: 11_000, inDaylight: true)
        #expect(WindowAdvisor.advice(track: [], passes: [ahead], events: [], regions: nil, step: 60) == nil)
    }

    @Test func theCopyHasNoDashes() {
        let a = WindowAdvice(side: .right, reasons: [.sunrise(region: nil), .shade], otherSide: ["A", "B"], sunSide: .left)
        let card = WindowFacts.card(a, seat: "3K", family: .a330)
        for s in [card.headline] + card.lines + [WindowFacts.caption, LandmarkFacts.caption] {
            #expect(!s.contains("\u{2014}"))
        }
        #expect(card.headline == "Sit on the right for the sunrise")
        #expect(card.lines.contains("On the left: A and B."))
    }
}
