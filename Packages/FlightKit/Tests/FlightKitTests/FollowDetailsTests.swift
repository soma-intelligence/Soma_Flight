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
