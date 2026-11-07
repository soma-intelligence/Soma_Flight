import Foundation
import Testing
import FlightImportKit
@testable import FlightKit

/// What a free-text Add a flight search means: flight number, airline, places, date and time.
@Suite struct SearchIntentTests {
    let paris = TimeZone(identifier: "Europe/Paris")!
    let suggester = SearchSuggester.bundled()
    /// Sunday 2026-11-01, noon in Paris.
    var now: Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = paris
        return cal.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 12))!
    }

    private func parse(_ text: String, monthFirst: Bool = false) -> SearchIntent {
        SearchIntent.parse(text, now: now, tz: paris, monthFirst: monthFirst, suggester: suggester)
    }

    private func d(_ y: Int, _ m: Int, _ dd: Int) -> LocalDay { LocalDay(year: y, month: m, day: dd) }

    /// The chips' kinds, for order checks.
    private func kinds(_ i: SearchIntent) -> [String] {
        i.chips.map {
            switch $0 {
            case .ident: "ident"
            case .airline: "airline"
            case .place: "place"
            case .day: "day"
            case .time: "time"
            }
        }
    }

    @Test func flightNumberAndRelativeDay() {
        let i = parse("AF 84 demain")
        #expect(i.ident == "AF84")
        #expect(i.day == d(2026, 11, 2))
        #expect(i.chips == [.ident("AF84"), .day(d(2026, 11, 2))])
        #expect(i.leftover.isEmpty)
        #expect(i.isSearchable)
    }

    @Test func citiesAndDate() {
        let i = parse("Paris New York 12 dec")
        #expect(i.origins == ["LFPG", "LFPO"])
        #expect(i.destinations.contains("KJFK"))
        #expect(i.day == d(2026, 12, 12))
        #expect(kinds(i) == ["place", "place", "day"])
    }

    @Test func orderDoesNotMatter() {
        let a = parse("demain paris londres"), b = parse("paris londres demain")
        #expect(a.origins == b.origins)
        #expect(a.destinations == b.destinations)
        #expect(a.day == b.day)
        #expect(a.origins == ["LFPG", "LFPO"])
        #expect(a.destinations.contains("EGLL"))
        #expect(kinds(a) == ["day", "place", "place"])
    }

    @Test func londonIsTheBritishOne() {
        // London, Ontario is a medium airport with the same city name: a city keeps one country.
        let i = parse("paris london")
        #expect(Set(i.destinations) == ["EGLL", "EGKK", "EGLC"])
    }

    @Test func airlineAirportAndWeekday() {
        let i = parse("Air France CDG vendredi")
        #expect(i.airline?.id == "AFR")
        #expect(i.origins == ["LFPG"])
        #expect(i.destinations.isEmpty)
        #expect(i.day == d(2026, 11, 6))
        #expect(kinds(i) == ["airline", "place", "day"])
    }

    @Test func codeAndDayFirstDate() {
        let i = parse("SFO 15/11")
        #expect(i.origins == ["KSFO"])
        #expect(i.ident == nil)
        #expect(i.day == d(2026, 11, 15))
    }

    @Test func airlineAndCity() {
        let i = parse("Lufthansa Munich")
        #expect(i.airline?.id == "DLH")
        #expect(i.origins == ["EDDM"])
        #expect(i.day == nil)
    }

    @Test(arguments: ["paris to london", "paris vers londres", "paris - london", "paris à londres"])
    func connectors(_ text: String) {
        let i = parse(text)
        #expect(i.origins == ["LFPG", "LFPO"])
        #expect(i.destinations.contains("EGLL"))
        #expect(!i.destinations.contains("LFPG"))
        #expect(i.leftover.isEmpty)
    }

    @Test func fromMarksTheOrigin() {
        let i = parse("to london from paris")
        #expect(i.origins == ["LFPG", "LFPO"])
        #expect(i.destinations.contains("EGLL"))
    }

    @Test func typos() {
        let i = parse("zurih geneve")
        #expect(i.origins == ["LSZH"])
        #expect(i.destinations == ["LSGG"])
    }

    @Test func airlineNameBeatsCity() {
        let i = parse("Delta Atlanta")
        #expect(i.airline?.id == "DAL")
        #expect(i.origins.contains("KATL"))
    }

    @Test(arguments: ["paris bruxelles", "paris brussels"])
    func brusselsIsAPlace(_ text: String) {
        let i = parse(text)
        #expect(i.airline == nil)
        #expect(i.destinations == ["EBBR"])
    }

    @Test func shortAirlineNameYieldsToALargeAirport() {
        #expect(parse("kuwait").origins == ["OKKK"])
        #expect(parse("kuwait").airline == nil)
        let i = parse("brussels airlines")
        #expect(i.airline?.id == "BEL")
        #expect(i.origins.isEmpty)
    }

    @Test func smallWordCodesYieldToADate() {
        let i = parse("paris new york le 12 dec")
        #expect(i.ident == nil)
        #expect(i.day == d(2026, 12, 12))
        #expect(i.destinations.contains("KJFK"))
        let j = parse("vol de 12 dec")
        #expect(j.ident == nil)
        #expect(j.day == d(2026, 12, 12))
        #expect(parse("LA 800").ident == "LA800")
    }

    @Test func threeLetterCodeIsAnAirport() {
        let i = parse("DEL")
        #expect(i.origins == ["VIDP"])
        #expect(i.airline == nil)
    }

    @Test func twoLetterCodeIsAnAirline() {
        let i = parse("AF")
        #expect(i.airline?.id == "AFR")
        #expect(i.origins.isEmpty)
    }

    @Test func identForms() {
        #expect(parse("AA 100").ident == "AA100")
        #expect(parse("af84").ident == "AF84")
        #expect(parse("DAL 220").ident == "DAL220")
        #expect(parse("DAL 220").origins.isEmpty)
    }

    @Test func airportCodeYieldsToADate() {
        // CDG is also an airline's ICAO code; with "12 dec" after it, it is the airport.
        let i = parse("CDG 12 dec")
        #expect(i.ident == nil)
        #expect(i.origins == ["LFPG"])
        #expect(i.day == d(2026, 12, 12))
    }

    @Test func airportByName() {
        #expect(parse("heathrow").origins == ["EGLL"])
        #expect(parse("charles de gaulle to heathrow").origins == ["LFPG"])
    }

    @Test func identBeforeNumericDate() {
        // "12 12" would read 12 December; the flight number takes "AF 12" first, the lone "12" is left.
        let i = parse("AF 12 12")
        #expect(i.ident == "AF12")
        #expect(i.day == nil)
        #expect(i.leftover == ["12"])
    }

    @Test func timeBeforeDate() {
        let i = parse("AF 84 6 30 pm")
        #expect(i.timeOfDay == 18 * 60 + 30)
        #expect(i.ident == "AF84")
        #expect(i.day == nil)
    }

    @Test func weekdayWithNumbersHasNoTime() {
        let i = parse("friday 8 30")
        #expect(i.timeOfDay == nil)
        #expect(i.day != nil)
    }

    @Test func weekdayWordsStayWeekdays() {
        // "sun" is also Hailey's code (KSUN) and "mer" a French weekday: neither becomes a place.
        let i = parse("paris sun")
        #expect(i.origins == ["LFPG", "LFPO"])
        #expect(i.destinations.isEmpty)
        #expect(i.day == d(2026, 11, 8))
        let j = parse("12 dec sun")
        #expect(j.origins.isEmpty)
        #expect(j.leftover == ["sun"])
    }

    @Test func leftoverDoesNotBlock() {
        let i = parse("paris blah london")
        #expect(i.leftover == ["blah"])
        #expect(i.origins == ["LFPG", "LFPO"])
        #expect(i.destinations.contains("EGLL"))
        #expect(i.isSearchable)
    }

    @Test func timeAloneIsNotSearchable() {
        let i = parse("18h")
        #expect(i.timeOfDay == 1080)
        #expect(!i.isSearchable)
        #expect(i.chips == [.time(1080)])
    }

    @Test func emptyText() {
        let i = parse("   ")
        #expect(i.chips.isEmpty)
        #expect(!i.isSearchable)
    }

    @Test func removingAChip() {
        let i = parse("AF 84 demain")
        #expect(i.removing(.day(d(2026, 11, 2)), from: "AF 84 demain") == "AF 84")
        #expect(i.removing(.ident("AF84"), from: "AF 84 demain") == "demain")
        let j = parse("Paris New York 12/12")
        guard case .place(let ny)? = j.chips.dropFirst().first else { Issue.record("no second place"); return }
        #expect(j.removing(.place(ny), from: "Paris New York 12/12") == "Paris 12/12")
        #expect(j.removing(.time(5), from: "Paris New York 12/12") == "Paris New York 12/12")
    }

    @Test func lookups() {
        #expect(suggester.airline(named: "delta")?.airline.id == "DAL")
        #expect(suggester.airline(named: "lufthansa")?.airline.id == "DLH")
        #expect(suggester.airline(named: "paris") == nil)
        #expect(suggester.airports(named: "paris")?.airports.map(\.id) == ["LFPG", "LFPO"])
        #expect(suggester.airports(named: "zurih")?.airports.map(\.id) == ["LSZH"])
        #expect(suggester.airports(named: "blah") == nil)
        #expect(suggester.airport(code: "DEL")?.id == "VIDP")
        #expect(suggester.airline(code: "AF")?.id == "AFR")
    }
    // MARK: Forgiving input

    /// A flight number however it is typed: glued, spaced, the airline by name, the number first.
    @Test(arguments: ["af84", "AF 84", "air france 84", "84 af", "Air France 84", "84 air france", "AF84 "])
    func flightNumberAnyForm(_ text: String) {
        let i = parse(text)
        #expect(i.ident == "AF84", "\(text)")
        #expect(i.chips.first == .ident("AF84"), "\(text)")
        #expect(i.leftover.isEmpty, "\(text)")
    }

    /// A number named by an airline that is not on the device's list stays a leftover, never an ident.
    @Test func bareNumberWithoutAirlineIsNoFlight() {
        let i = parse("84")
        #expect(i.ident == nil)
        #expect(!i.isSearchable)
    }

    @Test func twoCitiesNoDay() {
        let i = parse("paris marseille")
        #expect(i.origins == ["LFPG", "LFPO"])
        #expect(i.destinations == ["LFML"])
        #expect(i.day == nil)
        #expect(i.isSearchable)
    }

    @Test func twoCodesAndADay() {
        let i = parse("cdg mrs tomorrow")
        #expect(i.origins == ["LFPG"])
        #expect(i.destinations == ["LFML"])
        #expect(i.day == d(2026, 11, 2))
        #expect(kinds(i) == ["place", "place", "day"])
    }

    @Test func flightNumberByNameWithADay() {
        let i = parse("air france 84 tomorrow")
        #expect(i.ident == "AF84")
        #expect(i.day == d(2026, 11, 2))
    }
}
