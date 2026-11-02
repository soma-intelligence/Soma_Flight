import Foundation
import Testing
import FlightImportKit
@testable import FlightKit

/// The search screen's own logic: what a planned row adds, how chips read, and what the empty field offers.
@Suite @MainActor struct SearchViewModelTests {
    nonisolated static let sfo = TimeZone(identifier: "America/Los_Angeles")!
    nonisolated static let paris = TimeZone(identifier: "Europe/Paris")!

    nonisolated static func utc(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .gmt
        return cal.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }

    static let late = ScheduledFlight(ident: "AF84", airline: "AFR", origin: "KSFO", destination: "LFPG",
                                      scheduledOut: utc(20, 23, 30), scheduledIn: utc(21, 10, 15))

    static let sfoAirport = Airport(id: "KSFO", iata: "SFO", name: "San Francisco International", city: "San Francisco",
                                    country: "US", lat: 37.6, lon: -122.4, tz: "America/Los_Angeles")

    @Test func aPlannedFlightKeepsItsOriginDay() {
        let u = UpcomingFlight(Self.late, tz: Self.sfo)
        #expect(u.ident == "AF84")
        // 23:30 UTC is 15:30 in San Francisco on the 20th, already the 21st in Paris.
        #expect(u.day == LocalDay(year: 2026, month: 11, day: 20))
        #expect(LocalDay(Self.late.scheduledOut, in: Self.paris) != u.day)
        #expect(u.origin == "KSFO")
        #expect(u.destination == "LFPG")
        #expect(u.departure == Self.late.scheduledOut)
        #expect(u.id == "AF84 2026-11-20")
    }

    @Test func aPlannedRowAlreadyPlannedReadsAdded() {
        let id = UpcomingFlight(Self.late, tz: Self.sfo).id
        #expect(SearchView.planState(Self.late, origin: Self.sfoAirport, planned: [id]) == .following)
        #expect(SearchView.planState(Self.late, origin: Self.sfoAirport, planned: []) == .idle)
        // The same flight added from another day's search is a different flight.
        #expect(SearchView.planState(Self.late, origin: Self.sfoAirport, planned: ["AF84 2026-11-21"]) == .idle)
        #expect(ResultRow.title(.following) == "Added")
        #expect(ResultRow.title(.idle) == "Add")
        #expect(ResultRow.accessibility(.following, ident: "AF84") == "Added AF 84")
        #expect(ResultRow.accessibility(.idle, ident: "AF84") == "Add AF 84 to My Flights")
    }

    @Test func theEmptyFieldOffersTodayTomorrowAndFrequentRoutes() {
        let paris = Airport(id: "LFPG", iata: "CDG", name: "Charles de Gaulle", city: "Paris", country: "FR",
                            lat: 49, lon: 2.5, tz: "Europe/Paris")
        let frequent: [FrequentItem] = [.airport(paris, count: 3)]
        let start = SearchStart(frequent: frequent)
        #expect(start.days.map(\.title) == ["Today", "Tomorrow"])
        #expect(start.frequent == frequent)
        #expect(SearchStart.appending("today", to: "") == "today")
        #expect(SearchStart.appending("tomorrow", to: "AF84 ") == "AF84 tomorrow")
    }

    @Test func chipsReadAsTheirPieces() {
        let af = Airline(id: "AFR", iata: "AF", name: "Air France", colorPrimary: "#002157")
        let cdg = Airport(id: "LFPG", iata: "CDG", name: "Charles de Gaulle", city: "Paris", country: "FR",
                          lat: 49, lon: 2.5, tz: "Europe/Paris")
        let ory = Airport(id: "LFPO", iata: "ORY", name: "Orly", city: "Paris", country: "FR",
                          lat: 48.7, lon: 2.4, tz: "Europe/Paris")
        #expect(SearchChipText.label(.airline(af), clock: .h24) == "Air France")
        #expect(SearchChipText.label(.place([cdg, ory]), clock: .h24) == "Paris (CDG, ORY)")
        #expect(SearchChipText.label(.place([cdg]), clock: .h24) == "Paris (CDG)")
        #expect(SearchChipText.label(.ident("AF84"), clock: .h24) == "AF 84")
        #expect(SearchChipText.label(.day(LocalDay(year: 2026, month: 11, day: 6)), clock: .h24) == "Fri Nov 6")
        #expect(SearchChipText.label(.time(1140), clock: .h24) == "Evening")
        #expect(SearchChipText.label(.time(480), clock: .h24) == "Morning")
        #expect(SearchChipText.label(.time(720), clock: .h24) == "Midday")
        #expect(SearchChipText.label(.time(900), clock: .h24) == "Afternoon")
        #expect(SearchChipText.label(.time(1320), clock: .h24) == "Night")
        #expect(SearchChipText.label(.time(1110), clock: .h24) == "18:30")
        #expect(SearchChipText.label(.time(1110), clock: .h12) == "6:30 PM")
    }

    @Test func removingAChipTakesItsWordsFromTheText() {
        let s = SearchRoutingTests.store(RecordingFlights())
        s.text = "AF 84 demain"
        s.textChanged()
        let day = try? #require(s.intent.chips.first { if case .day = $0 { true } else { false } })
        guard let day else { return }
        SearchView.remove(day, from: s)
        #expect(s.text == "AF 84")
        #expect(s.intent.day == nil)
        #expect(s.intent.ident == "AF84")
    }
}
