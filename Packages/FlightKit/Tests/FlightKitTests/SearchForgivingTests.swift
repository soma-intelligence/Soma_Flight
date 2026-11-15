import Foundation
import Testing
import FlightImportKit
@testable import FlightKit

/// The search reads what people actually type: city codes (NYC, LON), nicknames (Roissy, SF, NY),
/// relative dates ("in 2 days", "next week"), and offers few rows, the likeliest first.
@Suite struct SearchForgivingTests {
    let paris = TimeZone(identifier: "Europe/Paris")!
    let suggester = SearchSuggester.bundled()
    /// Sunday 2026-11-01, noon in Paris.
    var now: Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = paris
        return cal.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 12))!
    }

    private func parse(_ text: String) -> SearchIntent {
        SearchIntent.parse(text, now: now, tz: paris, monthFirst: false, suggester: suggester)
    }

    private func d(_ y: Int, _ m: Int, _ dd: Int) -> LocalDay { LocalDay(year: y, month: m, day: dd) }

    // MARK: Places

    @Test func cityCodesNameEveryAirport() {
        let nyc = parse("NYC")
        #expect(Set(nyc.origins).isSuperset(of: ["KJFK", "KLGA", "KEWR"]))
        #expect(nyc.leftover.isEmpty)
        let lon = parse("LON PAR")
        #expect(Set(lon.origins).isSuperset(of: ["EGLL", "EGKK"]))
        #expect(lon.destinations.contains("LFPG"))
        #expect(parse("tyo").origins.contains("RJTT"))
    }

    @Test func cityCodesNeverHideARealAirport() {
        // Every alias of three letters that is also a real airport's code stays that airport.
        for (code, _) in SearchSuggester.placeAliases where code.count == 3 {
            if let real = suggester.airport(code: code) {
                Issue.record("\(code) is \(real.id), a real airport")
            }
        }
    }

    @Test func nicknames() {
        #expect(parse("roissy").origins == ["LFPG"])
        #expect(parse("san fran").origins == ["KSFO"])
        let sf = parse("sf lax")
        #expect(sf.airline == nil)
        #expect(sf.origins == ["KSFO"])
        #expect(sf.destinations == ["KLAX"])
        let ny = parse("frankfurt ny")
        #expect(ny.airline == nil)
        #expect(ny.origins.contains("EDDF"))
        #expect(ny.destinations.contains("KJFK"))
        #expect(parse("vegas").origins == ["KLAS"])
    }

    @Test func cityCodeWithDate() {
        let i = parse("paris nyc next week")
        #expect(i.origins == ["LFPG", "LFPO"])
        #expect(i.destinations.contains("KJFK"))
        #expect(!i.destinations.contains("EDLV"))
        #expect(i.day == d(2026, 11, 2))
        #expect(i.leftover.isEmpty)
    }

    @Test func flightNumbersStillWin() {
        #expect(parse("la 800").ident == "LA800")
        #expect(parse("sf 123").ident == "SF123")
    }

    // MARK: Dates

    @Test func relativeDays() {
        let a = parse("in 2 days")
        #expect(a.ident == nil)
        #expect(a.day == d(2026, 11, 3))
        #expect(a.leftover.isEmpty)
        #expect(parse("dans 3 jours").day == d(2026, 11, 4))
        #expect(parse("in 1 day").day == d(2026, 11, 2))
        #expect(parse("in 2 weeks").day == d(2026, 11, 15))
        #expect(parse("dans 2 semaines").day == d(2026, 11, 15))
    }

    @Test func weeks() {
        #expect(parse("next week").day == d(2026, 11, 2))
        let fr = parse("la semaine prochaine")
        #expect(fr.day == d(2026, 11, 2))
        #expect(fr.leftover.isEmpty)
        // Sunday: the weekend is today.
        #expect(parse("this weekend").day == d(2026, 11, 1))
        #expect(parse("ce week end").day == d(2026, 11, 1))
    }

    @Test func routeAndRelativeDay() {
        let i = parse("lax tokyo in 3 days")
        #expect(i.origins == ["KLAX"])
        #expect(i.destinations.contains("RJTT"))
        #expect(i.day == d(2026, 11, 4))
    }

    // MARK: Suggestions

    @Test func fewSuggestions() {
        for text in ["LA", "bos", "sf", "air france", "paris", "a", "new", "orly"] {
            let s = suggester.suggest(text)
            #expect(s.count <= SearchSuggestions.maxRows, "\(text): \(s.count) rows")
        }
    }

    @Test func cityCodeSuggestsItsAirports() {
        let s = suggester.suggest("nyc")
        let ids = s.items(.airports).compactMap { if case .airport(let a) = $0 { a.id } else { nil } }
        #expect(ids.first == "KJFK")
        #expect(ids.contains("KLGA"))
        let la = suggester.suggest("LA")
        let top = la.all.first
        #expect(top == .airport(suggester.airport(code: "LAX")!))
    }

    @Test func theUsersAirportsComeFirst() {
        let known = [KnownFlight(ident: "AF84", origin: "LFPO", destination: "KSFO", date: now, followed: true)]
        let s = suggester.suggest("paris", known: known)
        let ids = s.items(.airports).compactMap { if case .airport(let a) = $0 { a.id } else { nil } }
        #expect(ids.first == "LFPO")
    }

    // MARK: Whole queries

    @Test func aWholeQueryIsComplete() {
        #expect(parse("lax tokyo demain").isComplete)
        #expect(parse("AF 84").isComplete)
        #expect(parse("paris nyc next week").isComplete)
        #expect(!parse("paris").isComplete)
        #expect(!parse("AF").isComplete)
        #expect(!parse("paris zzqx").isComplete)
        #expect(!parse("demain").isComplete)
    }

    @Test func summaryNamesEachPiece() {
        let s = SearchSummary.text(parse("lax tokyo in 3 days 6pm"), clock: .h24)
        #expect(s == "Los Angeles \u{2192} Tokyo \u{00B7} Wed Nov 4 \u{00B7} 18:00")
        #expect(SearchSummary.text(parse("AF 84 demain"), clock: .h24) == "AF 84 \u{00B7} Mon Nov 2")
    }

    @MainActor @Test func returnSearchesAWholeQueryAsTyped() {
        let s = SearchStore(flights: ScriptedFlights(stall: .zero))
        s.text = "paris nyc next week"
        s.textChanged()
        #expect(s.submit() == .searching)
        #expect(s.text == "paris nyc next week")
    }

    // MARK: Calendar

    @Test func pickingADayRewritesOnlyTheDate() {
        let day = d(2026, 12, 20)
        #expect(SearchDayText.setting(day, in: "AF 84 demain", intent: parse("AF 84 demain")) == "AF 84 20 dec")
        #expect(SearchDayText.setting(day, in: "lax tokyo", intent: parse("lax tokyo")) == "lax tokyo 20 dec")
        #expect(SearchDayText.setting(nil, in: "AF 84 demain", intent: parse("AF 84 demain")) == "AF 84")
        #expect(SearchDayText.setting(day, in: "", intent: parse("")) == "20 dec")
        // The written day reads back as the picked one.
        #expect(parse("AF 84 20 dec").day == day)
    }
}
