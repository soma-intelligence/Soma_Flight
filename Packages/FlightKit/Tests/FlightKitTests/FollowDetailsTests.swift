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

    @Test func patchSendsAllSixKeys() throws {
        let keys: Set<String> = ["seat_class", "seat", "reason", "booking_code", "notes", "seat_position"]
        let full = try JSONEncoder().encode(SupabaseFlightService.DetailsPatch(
            details: FollowDetails(seatClass: .premiumEconomy, seat: "12A", reason: .business, bookingCode: "ABC123", notes: "n",
                                   seatPosition: .window)))
        let a = try #require(try JSONSerialization.jsonObject(with: full) as? [String: Any])
        #expect(Set(a.keys) == keys)
        #expect(a["seat_class"] as? String == "premium_economy" && a["booking_code"] as? String == "ABC123")
        #expect(a["seat_position"] as? String == "window")
        let crew = try JSONEncoder().encode(SupabaseFlightService.DetailsPatch(
            details: FollowDetails(seatClass: .private, reason: .crew, seatPosition: .jumpseat)))
        let c = try #require(try JSONSerialization.jsonObject(with: crew) as? [String: Any])
        #expect(c["seat_class"] as? String == "private" && c["reason"] as? String == "crew")
        #expect(c["seat_position"] as? String == "jumpseat")
        let empty = try JSONEncoder().encode(SupabaseFlightService.DetailsPatch(details: .empty))
        let b = try #require(try JSONSerialization.jsonObject(with: empty) as? [String: Any])
        #expect(Set(b.keys) == keys)
        #expect(b.values.allSatisfy { $0 is NSNull })
    }

    @Test func titles() {
        #expect(SeatClass.allCases.map(\.title) == ["Economy", "Premium Economy", "Business", "First", "Private"])
        #expect(TripReason.allCases.map(\.title) == ["Personal", "Business", "Crew"])
        #expect(SeatPosition.allCases.map(\.title) == ["Aisle", "Middle", "Window", "Pilot", "Captain", "Jumpseat"])
        #expect(SeatPosition.allCases.filter(\.isCockpit) == [.pilot, .captain, .jumpseat])
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
        let cockpit = #"[{"seat_class":"private","seat":null,"reason":"crew","booking_code":null,"notes":null,"seat_position":"captain"}]"#
        #expect(try SupabaseFlightService.decodeDetails(Data(cockpit.utf8))
                == FollowDetails(seatClass: .private, reason: .crew, seatPosition: .captain))
    }

    /// The position the traveller picked reaches the core, and wins over the seat's layout there.
    @Test func pickedPositionReachesTheCore() {
        let base = PastFlight(date: Date(timeIntervalSince1970: 1_750_000_000), ident: "AF1", originIcao: "LFPG",
                              destinationIcao: "KJFK", aircraftType: "A320", seat: "14A", distanceKm: 5800,
                              seatClass: .private, reason: .crew, seatPosition: .aisle)
        let core = base.coreFlight
        #expect(core.seatPosition == .aisle && core.seatClass == .private && core.reason == .crew)
        #expect(PastFlight(date: base.date, ident: "AF1", originIcao: "LFPG", destinationIcao: "KJFK", distanceKm: 1)
            .coreFlight.seatPosition == nil)
    }

    @Test func seatLineUsesThePositionWithoutASeat() {
        #expect(DetailFacts.seatLine(FollowDetails(seatClass: .business, seat: "23A", seatPosition: .window)) == "23A · Business")
        #expect(DetailFacts.seatLine(FollowDetails(seatClass: .private, seatPosition: .captain)) == "Captain · Private")
        #expect(DetailFacts.seatLine(FollowDetails(seatPosition: .jumpseat)) == "Jumpseat")
    }
}
