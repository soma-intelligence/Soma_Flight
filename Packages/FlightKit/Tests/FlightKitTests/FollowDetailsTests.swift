import Foundation
import Testing
@testable import FlightKit

@Suite struct FollowDetailsTests {
    @Test func normalizedSeat() {
        #expect(FollowDetails.normalizedSeat(" 23a ") == .some("23A"))
        #expect(FollowDetails.normalizedSeat("") == .some(nil))
        #expect(FollowDetails.normalizedSeat("hello") == nil)
        #expect(FollowDetails.normalizedSeat("12L") == nil)
        #expect(FollowDetails.normalizedSeat("1234A") == nil)
    }

    @Test func normalizedBookingCode() {
        #expect(FollowDetails.normalizedBookingCode("abc12d") == .some("ABC12D"))
        #expect(FollowDetails.normalizedBookingCode("ab") == nil)
        #expect(FollowDetails.normalizedBookingCode("  ") == .some(nil))
        #expect(FollowDetails.normalizedBookingCode("ABCDEFGHI") == nil)
    }

    @Test func normalizedNotes() {
        #expect(FollowDetails.normalizedNotes("  hi ") == .some("hi"))
        #expect(FollowDetails.normalizedNotes("") == .some(nil))
        #expect(FollowDetails.normalizedNotes(String(repeating: "a", count: 2001)) == nil)
        #expect(FollowDetails.normalizedNotes(String(repeating: "a", count: 2000)) != nil)
    }

    @Test func notesCountUnicodeScalars() {
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"
        #expect(FollowDetails.normalizedNotes(String(repeating: family, count: 401)) == nil)
        #expect(FollowDetails.normalizedNotes(String(repeating: family, count: 400)) != nil)
        #expect(FollowDetails.normalizedNotes(String(repeating: "\u{1F600}", count: 2000)) != nil)
    }

    @Test func patchSendsAllFiveKeys() throws {
        let full = try JSONEncoder().encode(SupabaseFlightService.DetailsPatch(
            details: FollowDetails(seatClass: .premiumEconomy, seat: "12A", reason: .business, bookingCode: "ABC123", notes: "n")))
        let a = try #require(try JSONSerialization.jsonObject(with: full) as? [String: Any])
        #expect(Set(a.keys) == ["seat_class", "seat", "reason", "booking_code", "notes"])
        #expect(a["seat_class"] as? String == "premium_economy" && a["booking_code"] as? String == "ABC123")
        let empty = try JSONEncoder().encode(SupabaseFlightService.DetailsPatch(details: .empty))
        let b = try #require(try JSONSerialization.jsonObject(with: empty) as? [String: Any])
        #expect(Set(b.keys) == ["seat_class", "seat", "reason", "booking_code", "notes"])
        #expect(b.values.allSatisfy { $0 is NSNull })
    }

    @Test func titles() {
        #expect(SeatClass.allCases.map(\.title) == ["Economy", "Premium Economy", "Business", "First"])
        #expect(TripReason.allCases.map(\.title) == ["Personal", "Business"])
        #expect(Alliance.allCases.map(\.title) == ["Star Alliance", "oneworld", "SkyTeam"])
    }

    @Test func fakeFollowDetailsRoundTrip() async throws {
        let service = FakeFlightService(now: FakeSeed.reference)
        let flight = try #require(try await service.followed().first)
        #expect(try await service.followDetails(flight.id) == .empty)
        let saved = FollowDetails(seatClass: .business, seat: "2A", reason: .business, bookingCode: "ABC123", notes: "Aisle")
        try await service.saveFollowDetails(flight.id, saved)
        #expect(try await service.followDetails(flight.id) == saved)
        try await service.unfollow(flight.id)
        #expect(try await service.followDetails(flight.id) == nil)
    }

    @Test func fakeFollowDetailsHonourNextError() async throws {
        let service = FakeFlightService(now: FakeSeed.reference)
        let flight = try #require(try await service.followed().first)
        await service.setNextError(.offline)
        await #expect(throws: APIError.offline) { try await service.saveFollowDetails(flight.id, .empty) }
    }

    @Test func decodesDetailsRow() throws {
        let json = #"[{"seat_class":"premium_economy","seat":"12A","reason":null,"booking_code":"ABC123","notes":null}]"#
        let d = try #require(try SupabaseFlightService.decodeDetails(Data(json.utf8)))
        #expect(d == FollowDetails(seatClass: .premiumEconomy, seat: "12A", bookingCode: "ABC123"))
        #expect(try SupabaseFlightService.decodeDetails(Data("[]".utf8)) == nil)
    }
}
