import Foundation
import Testing
@testable import FlightActivityKit

/// What Siri, Shortcuts and the Control Center say about the next flight, from the widget snapshot.
@Suite struct FlightAnswerTests {
    static let now = ISO8601DateFormatter().date(from: "2026-11-06T12:00:00Z")!

    @Test func nothingFollowedSaysSo() {
        #expect(FlightAnswer.nextFlight(.empty(at: Self.now), at: Self.now, twelveHour: false) == FlightAnswer.nothingFollowed)
    }

    @Test func theNextFlightIsTheOneInTheAir() {
        let text = FlightAnswer.nextFlight(.preview(now: Self.now), at: Self.now, twelveHour: false)
        #expect(text.hasPrefix("AF 84 to San Francisco is in the air and lands at "))
        #expect(text.hasSuffix(", 20m late, at terminal I, gate G91."))
    }

    @Test func aScheduledFlightGivesItsDepartureDelayAndGate() {
        let f = WidgetSnapshot.preview(now: Self.now).flights[1]
        let text = FlightAnswer.sentence(f, at: Self.now, twelveHour: false)
        #expect(text.hasPrefix("UA 1527 to Austin departs at "))
        #expect(text.hasSuffix(", 25m late, from terminal 3, gate F11."))
    }

    @Test func canceledAndUnknownTimesSayLess() {
        var f = WidgetSnapshot.preview(now: Self.now).flights[3]
        #expect(!FlightAnswer.sentence(f, at: Self.now, twelveHour: false).contains(","))
        f.status = .canceled
        #expect(FlightAnswer.sentence(f, at: Self.now, twelveHour: false) == "BA 287 to San Francisco is canceled.")
    }

    @Test func searchLinksRoundTrip() {
        let url = FlightLink.searchURL(query: " UA 1527 ")
        #expect(url.absoluteString == "somaflight://search?q=UA%201527")
        #expect(FlightLink.searchQuery(from: url) == "UA 1527")
        #expect(FlightLink.searchQuery(from: FlightLink.searchURL(query: "")) == "")
        #expect(FlightLink.searchQuery(from: FlightLink.url(for: UUID())) == nil)
        #expect(FlightLink.flightID(from: url) == nil)
    }
}
