import Foundation
import Testing
@testable import FlightKit

/// The flight sheet's status card, coloured times, More menu wording and the Booking Details sheet.
private func date(_ s: String) -> Date { try! Date(s, strategy: .iso8601) }

@MainActor @Suite struct DetailLookTests {
    @Test func offsetWords() {
        #expect(DetailFacts.offsetWord(nil) == nil)
        #expect(DetailFacts.offsetWord(3) == "3m Late")
        #expect(DetailFacts.offsetWord(-32) == "32m Early")
        #expect(DetailFacts.offsetWord(0) == "On Time")
        #expect(DetailFacts.offsetWord(75) == "1h 15m Late")
        let s = date("2026-04-25T07:15:00Z")
        #expect(DetailFacts.offsetMinutes(scheduled: s, estimated: nil, actual: nil) == nil)
        #expect(DetailFacts.offsetMinutes(scheduled: s, estimated: s.addingTimeInterval(600), actual: s.addingTimeInterval(180)) == 3)
    }

    /// CDG 09:15 to SFO 11:40 scheduled, out 09:18, in 11:08: "Arrived 32m Early", green.
    @Test func landedCard() {
        var f = DetailPart1Tests.ua990
        f.scheduledOut = date("2026-04-25T07:15:00Z"); f.scheduledIn = date("2026-04-25T18:40:00Z")
        f.actualOut = date("2026-04-25T07:18:00Z"); f.actualIn = date("2026-04-25T18:08:00Z")
        f.status = .arrived
        #expect(DetailFacts.landedTitle(f) == "Arrived 32m Early")
        #expect(DetailFacts.landedCaption(f, origin: nil, destination: nil, unit: .km) == "Total 10h 50m")
        #expect(DetailFacts.statusTone(f) == Theme.onTime)
        f.actualIn = date("2026-04-25T18:45:00Z"); f.status = .landed
        #expect(DetailFacts.landedTitle(f) == "Landed 5m Late")
        #expect(DetailFacts.statusTone(f) == Theme.veryLate)
        f.status = .scheduled
        #expect(DetailFacts.landedTitle(f) == nil)
        #expect(DetailFacts.statusTone(f) == nil)
    }

    @Test func menuWording() {
        #expect(DetailFacts.menuTitle("PHONE") == "Phone")
        #expect(DetailFacts.menuTitle("X / TWITTER") == "X / Twitter")
        let url = DetailFacts.mapsURL(DetailPart1Tests.sfo)!.absoluteString
        #expect(url.hasPrefix("https://maps.apple.com/?ll=37.6189,-122.375&q=San%20Francisco"))
    }

    @Test func bookingDetailsChecksBothFields() {
        let draft = FollowDetails(seatClass: .business)
        #expect(BookingDetailsModel.validated(code: " abc123", seat: "23a", draft: draft)
                == .success(FollowDetails(seatClass: .business, seat: "23A", bookingCode: "ABC123")))
        #expect(BookingDetailsModel.validated(code: "ab", seat: "ZZ", draft: draft)
                == .failure(.init(code: DetailFacts.bookingCodeError, seat: DetailFacts.seatError)))
        #expect(BookingDetailsModel.validated(code: "", seat: "", draft: FollowDetails(seat: "1A", bookingCode: "ABC123"))
                == .success(FollowDetails()))
    }

    @Test func pasteKeepsOnlyABookingCode() {
        let m = BookingDetailsModel(details: .empty)
        m.paste("hello world")
        #expect(m.code.isEmpty && m.codeError == DetailFacts.pasteHint)
        m.paste(" xk92lm ")
        #expect(m.code == "XK92LM" && m.codeError == nil)
    }
}

/// The floating bar leaves when the sheet is pulled down to its header.
@Suite struct DetailBarTests {
    @Test func barHidesOnTheCollapsedSheet() {
        #expect(!FlightDetailView.showsBar(height: 120))
        #expect(!FlightDetailView.showsBar(height: 299))
        #expect(FlightDetailView.showsBar(height: 300))
        #expect(FlightDetailView.showsBar(height: .infinity))
    }
}
