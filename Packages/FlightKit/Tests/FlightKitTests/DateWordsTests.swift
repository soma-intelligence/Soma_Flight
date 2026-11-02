import Foundation
import Testing
import FlightImportKit
@testable import FlightKit

/// Dates and times of day read out of typed search words, in English and French.
@Suite struct DateWordsTests {
    let paris = TimeZone(identifier: "Europe/Paris")!
    /// Sunday 2026-11-01, noon in Paris.
    var now: Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = paris
        return cal.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 12))!
    }

    private func day(_ text: String, monthFirst: Bool = false, now: Date? = nil, tz: TimeZone? = nil) -> (day: LocalDay, used: Range<Int>)? {
        DateWords.day(SearchText.words(SearchText.fold(text)), now: now ?? self.now, tz: tz ?? paris, monthFirst: monthFirst)
    }

    private func moment(_ y: Int, _ m: Int, _ dd: Int, _ h: Int, _ min: Int, in zone: TimeZone) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        return cal.date(from: DateComponents(year: y, month: m, day: dd, hour: h, minute: min))!
    }

    private func time(_ text: String) -> (minutes: Int, used: Range<Int>)? {
        DateWords.timeOfDay(SearchText.words(SearchText.fold(text)))
    }

    private func d(_ y: Int, _ m: Int, _ dd: Int) -> LocalDay { LocalDay(year: y, month: m, day: dd) }

    @Test func relativeDays() {
        #expect(day("today")?.day == d(2026, 11, 1))
        #expect(day("aujourd'hui")?.day == d(2026, 11, 1))
        #expect(day("aujourd hui")?.day == d(2026, 11, 1))
        #expect(day("tomorrow")?.day == d(2026, 11, 2))
        #expect(day("demain")?.day == d(2026, 11, 2))
        #expect(day("day after tomorrow")?.day == d(2026, 11, 3))
        #expect(day("day after tomorrow")?.used == 0..<3)
        #expect(day("après-demain")?.day == d(2026, 11, 3))
        #expect(day("apres demain")?.used == 0..<2)
    }

    @Test func weekdays() {
        #expect(day("friday")?.day == d(2026, 11, 6))
        #expect(day("vendredi")?.day == d(2026, 11, 6))
        #expect(day("next friday")?.day == d(2026, 11, 13))
        #expect(day("next friday")?.used == 0..<2)
        #expect(day("vendredi prochain")?.day == d(2026, 11, 13))
        #expect(day("vendredi prochain")?.used == 0..<2)
        // Today's weekday means next week.
        #expect(day("sunday")?.day == d(2026, 11, 8))
        #expect(day("lun")?.day == d(2026, 11, 2))
    }

    @Test func namedMonths() {
        for text in ["12 dec", "dec 12", "12 decembre", "12 december", "le 12 déc", "12th dec"] {
            #expect(day(text)?.day == d(2026, 12, 12), "\(text)")
        }
        #expect(day("1 jan")?.day == d(2027, 1, 1))
        #expect(day("12 dec 2026")?.day == d(2026, 12, 12))
        #expect(day("12 dec 2026")?.used == 0..<3)
    }

    @Test func numericDates() {
        #expect(day("12/12")?.day == d(2026, 12, 12))
        #expect(day("3 4")?.day == d(2027, 4, 3))
        #expect(day("3 4", monthFirst: true)?.day == d(2027, 3, 4))
        #expect(day("2026-12-12")?.day == d(2026, 12, 12))
        #expect(day("2026-12-12")?.used == 0..<3)
        #expect(day("12/12/2026")?.day == d(2026, 12, 12))
        // A month over 12 can only be the day.
        #expect(day("12 25", monthFirst: false)?.day == d(2026, 12, 25))
        #expect(day("31 31") == nil)
    }

    @Test func rollsForwardAndStopsAtTheLimit() {
        #expect(day("15 sep")?.day == d(2027, 9, 15))
        #expect(day("15 oct") == nil)
        #expect(DateWords.maxDaysAhead == 330)
        #expect(day("1 nov")?.day == d(2026, 11, 1))
        #expect(day("31 oct 2026") == nil)
    }

    @Test func findsTheDateAnywhere() {
        let r = day("paris 12 dec london")
        #expect(r?.day == d(2026, 12, 12))
        #expect(r?.used == 1..<3)
        #expect(day("paris london") == nil)
        #expect(day("af 84 tomorrow")?.used == 2..<3)
    }

    @Test func partsOfTheDay() {
        #expect(time("morning")?.minutes == 480)
        #expect(time("matin")?.minutes == 480)
        #expect(time("midday")?.minutes == 720)
        #expect(time("midi")?.minutes == 720)
        #expect(time("afternoon")?.minutes == 900)
        #expect(time("après-midi")?.minutes == 900)
        #expect(time("apres midi")?.used == 0..<2)
        #expect(time("evening")?.minutes == 1140)
        #expect(time("soir")?.minutes == 1140)
        #expect(time("night")?.minutes == 1320)
        #expect(time("nuit")?.minutes == 1320)
    }

    @Test func clockTimes() {
        #expect(time("18h")?.minutes == 1080)
        #expect(time("18h30")?.minutes == 1110)
        #expect(time("6pm")?.minutes == 1080)
        #expect(time("6 pm")?.minutes == 1080)
        #expect(time("6 30 pm")?.minutes == 1110)
        #expect(time("6 30 pm")?.used == 0..<3)
        #expect(time("6:30pm")?.minutes == 1110)
        #expect(time("12am")?.minutes == 0)
        #expect(time("12pm")?.minutes == 720)
        #expect(time("25h") == nil)
        #expect(time("13pm") == nil)
        #expect(time("paris 18h30 london")?.used == 1..<2)
        #expect(time("paris london") == nil)
    }

    @Test func aWeekdayBeforeADateBelongsToIt() {
        for text in ["fri 12 dec", "vendredi 12 decembre", "sat 12 dec"] {
            let r = day(text)
            #expect(r?.day == d(2026, 12, 12), "\(text)")
            #expect(r?.used == 0..<3, "\(text)")
        }
        #expect(day("paris fri 12 dec london")?.used == 1..<4)
        #expect(day("fri 12/12")?.used == 0..<3)
        #expect(day("friday")?.used == 0..<1)
    }

    @Test func todayFollowsTheZoneNotUTC() {
        // 00:30 on 1 Nov in Paris is still 31 Oct in UTC.
        let early = moment(2026, 11, 1, 0, 30, in: paris)
        #expect(day("today", now: early)?.day == d(2026, 11, 1))
        #expect(day("tomorrow", now: early)?.day == d(2026, 11, 2))
        // The same instant in New York is the evening of 31 Oct.
        let ny = TimeZone(identifier: "America/New_York")!
        #expect(day("today", now: early, tz: ny)?.day == d(2026, 10, 31))
        #expect(day("tomorrow", now: early, tz: ny)?.day == d(2026, 11, 1))
        // 31 Oct 2026 is a Saturday there, so "sunday" is the next day.
        #expect(day("sunday", now: early, tz: ny)?.day == d(2026, 11, 1))
    }

    @Test func theLimitIsExact() {
        #expect(day("27 sep 2027")?.day == d(2027, 9, 27))
        #expect(day("28 sep 2027") == nil)
        #expect(day("27 sep")?.day == d(2027, 9, 27))
        #expect(day("28 sep") == nil)
    }

    @Test func monthFirstWithAYear() {
        #expect(day("12 12 2026", monthFirst: true)?.day == d(2026, 12, 12))
        #expect(day("2026 12 12", monthFirst: true)?.day == d(2026, 12, 12))
        #expect(day("3 4 2027", monthFirst: true)?.day == d(2027, 3, 4))
        #expect(day("3 4 2027")?.day == d(2027, 4, 3))
    }

    @Test func nextAddsAWeek() {
        #expect(day("next sunday")?.day == d(2026, 11, 15))
        #expect(day("dimanche prochain")?.day == d(2026, 11, 15))
    }
}
