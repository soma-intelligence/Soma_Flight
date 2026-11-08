import Foundation
@testable import FlightKit
import Testing

/// The "Your 3rd flight on F-GSQA" line on the flight sheet: counting the traveller's flights on a tail.
@Suite struct TailVisitsTests {
    static let today = FlightJSON.parse("2026-11-08T09:00:00Z")!

    static func past(_ daysAgo: Int, _ reg: String?, ident: String = "AF1", status: PastFlightStatus = .completed) -> PastFlight {
        PastFlight(date: today.addingTimeInterval(-Double(daysAgo) * 86_400), ident: ident, originIcao: "LFPG",
                   destinationIcao: "EGLL", registration: reg, distanceKm: 350, status: status)
    }

    static func flight(_ reg: String?, ident: String = "AF1006") -> Flight {
        Flight(providerId: "p", ident: ident, originIcao: "LFPG", destinationIcao: "LIRF", scheduledOut: today,
               registration: reg, status: .scheduled)
    }

    @Test func countsEarlierFlightsOnTheTailPlusToday() {
        let history = [Self.past(300, "F-GSQA"), Self.past(40, "f-gsqa "), Self.past(10, "F-HTYM")]
        #expect(TailVisits.ordinal(Self.flight("F-GSQA"), past: history) == 3)
    }

    @Test func nothingForANewOrUnknownTail() {
        let history = [Self.past(300, "F-GSQA")]
        #expect(TailVisits.ordinal(Self.flight("F-HPJA"), past: history) == nil)
        #expect(TailVisits.ordinal(Self.flight(nil), past: history) == nil)
        #expect(TailVisits.ordinal(Self.flight("  "), past: history) == nil)
        #expect(TailVisits.ordinal(Self.flight("F-GSQA"), past: []) == nil)
    }

    @Test func canceledAndLaterFlightsDoNotCount() {
        let history = [Self.past(300, "F-GSQA", status: .canceled), Self.past(-20, "F-GSQA"), Self.past(50, "F-GSQA")]
        #expect(TailVisits.ordinal(Self.flight("F-GSQA"), past: history) == 2)
    }

    @Test func theFlightsOwnRowIsSkipped() {
        // Landed and archived: the history already holds today's flight.
        let own = Self.past(0, "F-GSQA", ident: "AF1006")
        let history = [own, Self.past(90, "F-GSQA")]
        #expect(TailVisits.ordinal(Self.flight("F-GSQA"), past: history) == 2)
        // A Passport flight opened in the sheet: same id, and only the flights before it count.
        let older = Self.past(400, "F-GSQA")
        #expect(TailVisits.ordinal(Self.past(90, "F-GSQA").asFlight, past: [older] + history) == 2)
    }

    @Test func englishOrdinals() {
        let en = Locale(identifier: "en")
        let words = [1, 2, 3, 4, 11, 12, 13, 21, 22, 23, 101].map { TailVisitFacts.ordinal($0, locale: en) }
        #expect(words == ["1st", "2nd", "3rd", "4th", "11th", "12th", "13th", "21st", "22nd", "23rd", "101st"])
        #expect(TailVisitFacts.badge(3, registration: "f-gsqa", locale: en) == "Your 3rd flight on F-GSQA")
        #expect(TailVisitFacts.ordinal(3, locale: Locale(identifier: "fr")) == "3e")
    }

    @Test func theCatalogHasTheFrenchLine() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Apps/Shared/Localizable.xcstrings")
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        let strings = json["strings"] as! [String: Any]
        let entry = strings["Your %@ flight on %@"] as? [String: Any]
        let fr = ((entry?["localizations"] as? [String: Any])?["fr"] as? [String: Any])?["stringUnit"] as? [String: Any]
        #expect(fr?["value"] as? String == "Ton %1$@ vol sur %2$@")
    }

    @MainActor @Test func theDetailStoreFindsTheTailInTheFakeHistory() async throws {
        let flights = FakeFlightService()
        let followed = try #require(try await flights.followed().first { $0.registration == "N37522" })
        let store = FlightDetailStore(id: followed.id, flights: flights, airports: FakeAirportService(),
                                      history: FakeHistoryService())
        await store.load()
        await store.loadExtras()
        #expect((store.tailVisit ?? 0) >= 2)
    }
}
