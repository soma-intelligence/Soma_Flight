import Foundation
@testable import FlightKit
import Testing

/// The Schengen 90/180 count from the history's flights: stays, days in the window, the last day of stay.
/// Cases follow the European Commission's short-stay calculator: entry and exit days count, any 180-day
/// window holds 90 days at most.
@Suite struct SchengenTests {
    typealias Day = Schengen.Day

    static func day(_ y: Int, _ m: Int, _ d: Int) -> Day { Day(year: y, month: m, day: d) }

    /// A flight leaving at noon UTC on the day, no block time (it lands the same date).
    static func flight(_ y: Int, _ m: Int, _ d: Int, _ from: String, _ to: String, hour: Int = 12,
                       status: PastFlightStatus = .completed) -> PastFlight {
        var c = DateComponents(year: y, month: m, day: d, hour: hour)
        c.timeZone = .gmt
        let date = Calendar(identifier: .gregorian).date(from: c)!
        return PastFlight(date: date, ident: "XX1", originIcao: "O\(from)", destinationIcao: "D\(to)", distanceKm: 1000,
                          status: status, originTz: "UTC", originCountry: from, destinationCountry: to)
    }

    // MARK: Members

    @Test func theAreaHasTheTwentyNineStatesPlusTheMicrostates() {
        let states = ConnectionRules.bundled.schengen
        #expect(states.count == 29)
        #expect(states.isSuperset(of: ["BG", "RO", "HR", "CH", "NO", "IS", "LI"]))
        #expect(!states.contains("IE") && !states.contains("CY") && !states.contains("GB"))
        #expect(Schengen.members.isSuperset(of: ["MC", "SM", "VA"]))
        #expect(!Schengen.members.contains("AD"))
        #expect(!Schengen.inArea("ENSB", country: "NO"))
        #expect(Schengen.inArea("ENGM", country: "NO"))
    }

    // MARK: Stays

    @Test func neverInTheAreaShowsNothing() {
        let flights = [Self.flight(2026, 1, 5, "US", "GB"), Self.flight(2026, 1, 9, "GB", "IE"), Self.flight(2026, 1, 12, "IE", "US")]
        #expect(Schengen.summary(flights, on: Self.day(2026, 2, 1)) == nil)
    }

    @Test func entryAndExitDaysBothCount() {
        let flights = [Self.flight(2026, 3, 1, "US", "FR"), Self.flight(2026, 3, 10, "DE", "US")]
        let s = Schengen.summary(flights, on: Self.day(2026, 3, 20))!
        #expect(s.stays == [Schengen.Stay(entry: Self.day(2026, 3, 1), exit: Self.day(2026, 3, 10))])
        #expect(s.used == 10)
        #expect(!s.inside)
        #expect(s.remaining == 80)
    }

    @Test func flightsInsideTheAreaKeepOneStay() {
        let flights = [Self.flight(2026, 3, 1, "US", "FR"), Self.flight(2026, 3, 4, "FR", "IT"),
                       Self.flight(2026, 3, 8, "IT", "ES"), Self.flight(2026, 3, 10, "ES", "US")]
        let s = Schengen.summary(flights, on: Self.day(2026, 3, 20))!
        #expect(s.stays.count == 1)
        #expect(s.used == 10)
    }

    @Test func exitAndReentryOnTheSameDayCountsTheDayOnce() {
        let flights = [Self.flight(2026, 1, 10, "US", "FR"), Self.flight(2026, 1, 20, "FR", "GB", hour: 8),
                       Self.flight(2026, 1, 20, "GB", "FR", hour: 18), Self.flight(2026, 1, 25, "FR", "US")]
        let s = Schengen.summary(flights, on: Self.day(2026, 1, 30))!
        #expect(s.stays.count == 2)
        // 10 to 25 January: 16 days, the 20th once.
        #expect(s.used == 16)
    }

    @Test func anOpenStayCountsToTodayAndGivesTheLastDay() {
        let flights = [Self.flight(2026, 10, 1, "US", "PT")]
        let s = Schengen.summary(flights, on: Self.day(2026, 10, 10))!
        #expect(s.inside)
        #expect(s.used == 10)
        #expect(s.stays == [Schengen.Stay(entry: Self.day(2026, 10, 1), exit: nil)])
        // 90 days from 1 October, both ends counted: 29 December.
        #expect(s.stayUntil == Self.day(2026, 12, 29))
    }

    @Test func canceledFlightsAreIgnored() {
        let flights = [Self.flight(2026, 3, 1, "US", "FR", status: .canceled)]
        #expect(Schengen.summary(flights, on: Self.day(2026, 3, 5)) == nil)
    }

    @Test func leavingWithNoFlightInCountsTheDayOfExit() {
        // Came in by train: only the flight out is seen.
        let s = Schengen.summary([Self.flight(2026, 5, 3, "BE", "GB")], on: Self.day(2026, 5, 10))!
        #expect(s.used == 1)
    }

    @Test func theArrivalDateIsTheDestinationsLocalDate() {
        // Leaves San Francisco on 9 January at 18:00, lands in Paris on the 10th.
        var c = DateComponents(year: 2026, month: 1, day: 10, hour: 2)
        c.timeZone = .gmt
        let f = PastFlight(date: Calendar(identifier: .gregorian).date(from: c)!, ident: "AF83", originIcao: "KSFO",
                           destinationIcao: "LFPG", distanceKm: 8_950, blockMinutes: 650, originTz: "America/Los_Angeles",
                           originCountry: "US", destinationCountry: "FR")
        let paris = Airport(id: "LFPG", iata: "CDG", name: "Paris CDG", city: "Paris", country: "FR", lat: 49.0, lon: 2.5,
                            tz: "Europe/Paris")
        let stays = Schengen.stays([f], airport: { $0 == "LFPG" ? paris : nil })
        #expect(stays.first?.entry == Self.day(2026, 1, 10))
    }

    // MARK: The window

    @Test func theWindowIsTheHundredAndEightyDaysEndingToday() {
        let s = Schengen.summary(stays: [Schengen.Stay(entry: Self.day(2026, 1, 1), exit: Self.day(2026, 1, 1))],
                                 on: Self.day(2026, 6, 29))!
        // 29 June minus 179 days is 1 January: still in.
        #expect(s.windowStart == Self.day(2026, 1, 1))
        #expect(s.used == 1)
        let next = Schengen.summary(stays: s.stays, on: Self.day(2026, 6, 30))!
        #expect(next.windowStart == Self.day(2026, 1, 2))
        #expect(next.used == 0)
    }

    @Test func ninetyDaysUsedLeaveNoDayUntilTheFirstOneDropsOut() {
        // 1 January to 31 March 2026: 90 days (EU calculator: the full allowance).
        let stays = [Schengen.Stay(entry: Self.day(2026, 1, 1), exit: Self.day(2026, 3, 31))]
        let full = Schengen.summary(stays: stays, on: Self.day(2026, 3, 31))!
        #expect(full.used == 90)
        #expect(!full.isOver)
        // The day of exit is still a day in the area, and the last one allowed.
        #expect(full.inside)
        #expect(full.stayUntil == Self.day(2026, 3, 31))
        #expect(Schengen.summary(stays: stays, on: Self.day(2026, 4, 1))?.stayUntil == nil)
        let june29 = Schengen.summary(stays: stays, on: Self.day(2026, 6, 29))!
        #expect(june29.used == 90 && june29.stayUntil == nil)
        // On 30 June 1 January has left the window: arriving that day, one day drops out for every day
        // added until 31 March leaves (27 September), and the 90 days of the new stay end that day.
        let june30 = Schengen.summary(stays: stays, on: Self.day(2026, 6, 30))!
        #expect(june30.used == 89)
        #expect(june30.stayUntil == Self.day(2026, 9, 27))
    }

    @Test func eightyNineDaysLeaveOneMore() {
        let stays = [Schengen.Stay(entry: Self.day(2026, 1, 1), exit: Self.day(2026, 3, 30))]
        let s = Schengen.summary(stays: stays, on: Self.day(2026, 3, 30))!
        #expect(s.used == 89)
        #expect(s.stayUntil == Self.day(2026, 3, 31))
    }

    @Test func splitStaysAddUpAcrossTheWindow() {
        // EU calculator style: 30 days, 30 days, then a third trip that hits the limit.
        let stays = [Schengen.Stay(entry: Self.day(2026, 1, 1), exit: Self.day(2026, 1, 30)),
                     Schengen.Stay(entry: Self.day(2026, 3, 1), exit: Self.day(2026, 3, 30)),
                     Schengen.Stay(entry: Self.day(2026, 5, 1), exit: nil)]
        let s = Schengen.summary(stays: stays, on: Self.day(2026, 5, 1))!
        #expect(s.used == 61)
        // 29 more days: 1 to 30 May makes 90.
        #expect(s.stayUntil == Self.day(2026, 5, 30))
    }

    @Test func anOverstayIsFlagged() {
        let stays = [Schengen.Stay(entry: Self.day(2026, 1, 1), exit: nil)]
        let s = Schengen.summary(stays: stays, on: Self.day(2026, 4, 5))!
        #expect(s.used == 95)
        #expect(s.isOver)
        #expect(s.remaining == 0)
        #expect(s.stayUntil == nil)
        #expect(SchengenFacts.until(s) == "Over the 90 days in this window")
    }

    // MARK: Copy

    @Test func theCopyReadsPlainly() {
        let en = Locale(identifier: "en_US")
        let open = Schengen.summary(stays: [Schengen.Stay(entry: Self.day(2026, 10, 1), exit: nil)], on: Self.day(2026, 10, 10))!
        #expect(SchengenFacts.used(open) == "10 of 90 days used")
        #expect(SchengenFacts.until(open, locale: en) == "You can stay until Dec 29, 2026")
        let away = Schengen.summary(stays: [Schengen.Stay(entry: Self.day(2026, 3, 1), exit: Self.day(2026, 3, 10))],
                                    on: Self.day(2026, 3, 20))!
        #expect(SchengenFacts.until(away, locale: en).hasPrefix("Arriving today, you could stay until "))
        #expect(SchengenFacts.stay(away.stays[0], through: away.day, locale: en) == "Mar 1, 2026 to Mar 10, 2026 · 10 days")
        #expect(SchengenFacts.stay(open.stays[0], through: open.day, locale: en) == "Since Oct 1, 2026 · 10 days")
        let all = [SchengenFacts.title, SchengenFacts.caveat, SchengenFacts.used(open), SchengenFacts.until(open, locale: en),
                   SchengenFacts.window(open, locale: en)]
        #expect(all.allSatisfy { !$0.contains("\u{2014}") })
    }

    // MARK: Store

    @MainActor @Test func theFakeHistoryShowsTheCountInPassport() async {
        let store = PassportStore(history: FakeHistoryService())
        await store.load()
        // The seed has a Paris stay from 14 to 21 September 2026.
        let s = store.schengen(on: FlightJSON.parse("2026-10-23T12:00:00Z")!, in: .gmt)
        #expect(s != nil)
        #expect((s?.used ?? 0) > 0)
        #expect(s?.inside == false)
    }
}
