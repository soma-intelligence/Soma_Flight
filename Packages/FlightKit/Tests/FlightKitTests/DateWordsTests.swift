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

    private func day(_ text: String, monthFirst: Bool = false) -> (day: LocalDay, used: Range<Int>)? {
        DateWords.day(SearchText.words(SearchText.fold(text)), now: now, tz: paris, monthFirst: monthFirst)
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
}
