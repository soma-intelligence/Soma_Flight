import Foundation
import Testing
@testable import FlightKit

@Suite struct ScreenFactsTests {
    @Test func totalsWording() {
        #expect(TravelFacts.flightTime(.seconds((14 * 1440 + 23 * 60 + 5) * 60)) == "14d 23h")
        #expect(TravelFacts.flightTime(.seconds((18 * 60 + 20) * 60)) == "18h 20m")
        #expect(TravelFacts.flightTime(.seconds(45 * 60)) == "45m")
        #expect(TravelFacts.distance(280_017, .km) == "280,017 km")
        #expect(TravelFacts.distance(1_609, .mi) == "1,000 mi")
        #expect(TravelFacts.aroundTheWorld(280_017) == "7.0x around the world")
        #expect(TravelFacts.delayLost(.seconds(11 * 3600 + 59)).value == "11")
        #expect(TravelFacts.delayLost(.seconds(38 * 60)) == ("38", "minutes lost to delays"))
        #expect(TravelFacts.aircraftName("B77W") == "Boeing 777-300ER")
        #expect(TravelFacts.aircraftName("ZZZZ") == "ZZZZ")
        #expect(TravelFacts.airlineCode(ident: "B6417") == "B6")
        #expect(TravelFacts.airlineCode(ident: "EJM444") == "EJM")
    }

    @Test func pastFlightGroups() {
        let d = { (s: String) in ISO8601DateFormatter().date(from: s)! }
        let flights = [
            PastFlight(date: d("2025-03-01T12:00:00Z"), ident: "AF84", originIcao: "LFPG", destinationIcao: "KSFO",
                       airline: "Air France", aircraftType: "A359", distanceKm: 8970),
            PastFlight(date: d("2026-01-01T12:00:00Z"), ident: "UA1", originIcao: "KSFO", destinationIcao: "KAUS",
                       airline: "United", aircraftType: "B739", distanceKm: 2400),
            PastFlight(date: d("2026-02-01T12:00:00Z"), ident: "UA2", originIcao: "KAUS", destinationIcao: "KSFO",
                       airline: "United", aircraftType: "B739", distanceKm: 2400),
        ]
        let byYear = TravelFacts.groups(flights, by: .date, city: { $0 })
        #expect(byYear.map(\.title) == ["2026", "2025"])
        #expect(byYear[0].flights.map(\.ident) == ["UA2", "UA1"])
        let byAirline = TravelFacts.groups(flights, by: .airline, city: { $0 })
        #expect(byAirline.map(\.title) == ["United", "Air France"])
        let byFrom = TravelFacts.groups(flights, by: .from, city: { $0 == "KSFO" ? "San Francisco" : $0 })
        #expect(byFrom.map(\.title) == ["KAUS", "LFPG", "San Francisco"])
    }

    @Test @MainActor func recentSearches() async {
        let defaults = UserDefaults(suiteName: "ScreenFactsTests.\(UUID())")!
        let store = SearchStore(flights: FakeFlightService(), defaults: defaults)
        for q in ["af84", "AUS SFO", "AF84 "] { store.text = q; await store.search() }
        store.text = "zz999"
        await store.search()
        #expect(store.recent == ["AF84", "AUS SFO"])
        #expect(SearchStore(flights: FakeFlightService(), defaults: defaults).recent == ["AF84", "AUS SFO"])
        store.clearRecent()
        #expect(SearchStore(flights: FakeFlightService(), defaults: defaults).recent.isEmpty)
    }

    @Test func detailProgressLine() {
        let now = PreviewData.now
        #expect(DetailFacts.progressLine(PreviewData.enRoute, now: now)?.hasPrefix("Arrives in ") == true)
        #expect(DetailFacts.progressLine(PreviewData.canceled, now: now) == nil)
        #expect(DetailFacts.caption(PreviewData.diverted).hasSuffix("Diverted"))
    }
}
