import Foundation
import FlightImportKit

/// Reads a date or a time of day out of folded search words, in English and French ("friday", "12 dec",
/// "3 4", "18h30", "6 30 pm", "soir").
enum DateWords {
    /// How far ahead a typed date may be: past it the search treats the words as something else.
    static let maxDaysAhead = 330

    // MARK: Days

    /// The first date span in `words`, and the indices it covers. A bare day and month ("3 4") reads
    /// day first unless `monthFirst`; a date with no year is the next one on or after today, at most
    /// `limit` days ahead.
    static func day(_ words: [Substring], now: Date, tz: TimeZone, monthFirst: Bool,
                    limit: Int = maxDaysAhead) -> (day: LocalDay, used: Range<Int>)? {
        let today = LocalDay(now, in: tz)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        let weekday = cal.component(.weekday, from: now)
        // Explicit dates before weekdays ("fri 12 dec" is 12 dec), and named ones before bare numbers, so
        // "af 8 12 dec" reads 12 dec and not "8 12". A weekday written just before a date belongs to it.
        func withWeekday(_ r: (day: LocalDay, used: Range<Int>)) -> (day: LocalDay, used: Range<Int>) {
            let lo = r.used.lowerBound
            return lo > 0 && weekdays[String(words[lo - 1])] != nil ? (r.day, (lo - 1)..<r.used.upperBound) : r
        }
        for i in words.indices {
            if let r = explicit(words, i, today: today, limit: limit) { return withWeekday(r) }
        }
        for i in words.indices {
            if let r = numeric(words, i, today: today, monthFirst: monthFirst, limit: limit) { return withWeekday(r) }
        }
        for i in words.indices {
            if let r = weekdayDay(words, i, today: today, weekday: weekday) { return r }
        }
        return nil
    }

    /// Relative words ("tomorrow") and a day with a month name ("12 dec", "dec 12 2026").
    private static func explicit(_ w: [Substring], _ i: Int, today: LocalDay, limit: Int) -> (day: LocalDay, used: Range<Int>)? {
        func at(_ k: Int) -> Substring? { k < w.count ? w[k] : nil }
        func offset(_ days: Int, _ n: Int) -> (day: LocalDay, used: Range<Int>)? {
            guard let d = add(days, to: today) else { return nil }
            return (d, i..<(i + n))
        }
        switch w[i] {
        case "today", "aujourdhui": return offset(0, 1)
        case "aujourd" where at(i + 1) == "hui": return offset(0, 2)
        case "tomorrow", "demain": return offset(1, 1)
        case "day" where at(i + 1) == "after" && at(i + 2) == "tomorrow": return offset(2, 3)
        case "apres" where at(i + 1) == "demain": return offset(2, 2)
        default: break
        }
        // "12 dec [2026]", "dec 12 [2026]".
        if let d = dayNumber(w[i]), let m = at(i + 1).flatMap({ months[String($0)] }) {
            return dated(day: d, month: m, year: at(i + 2).flatMap(year), at: i, span: 2, today: today, limit: limit)
        }
        if let m = months[String(w[i])], let d = at(i + 1).flatMap(dayNumber) {
            return dated(day: d, month: m, year: at(i + 2).flatMap(year), at: i, span: 2, today: today, limit: limit)
        }
        return nil
    }

    /// "next friday", "friday", "vendredi prochain".
    private static func weekdayDay(_ w: [Substring], _ i: Int, today: LocalDay, weekday: Int) -> (day: LocalDay, used: Range<Int>)? {
        func at(_ k: Int) -> Substring? { k < w.count ? w[k] : nil }
        var skip = 0, extra = 7
        var name = w[i]
        if w[i] == "next", let n = at(i + 1) { name = n; skip = 1; extra = 14 }
        guard let target = weekdays[String(name)] else { return nil }
        var n = skip + 1
        if skip == 0, at(i + 1) == "prochain" { n = 2; extra = 14 }
        // Today's weekday means next week.
        let delta = (target - weekday + 7) % 7
        guard let d = add((delta == 0 ? 7 : delta) + (extra - 7), to: today) else { return nil }
        return (d, i..<(i + n))
    }

    private static func numeric(_ w: [Substring], _ i: Int, today: LocalDay, monthFirst: Bool, limit: Int) -> (day: LocalDay, used: Range<Int>)? {
        func num(_ k: Int) -> Int? { k < w.count && w[k].count <= 4 ? Int(w[k]) : nil }
        guard let a = num(i), let b = num(i + 1) else { return nil }
        // "2026 12 12".
        if w[i].count == 4, let y = year(w[i]), let c = num(i + 2), w[i + 2].count <= 2 {
            return dated(day: c, month: b, year: y, at: i, span: 3, today: today, limit: limit)
        }
        guard w[i].count <= 2, w[i + 1].count <= 2 else { return nil }
        // "12 12 2026", then "12 12".
        let y = i + 2 < w.count ? year(w[i + 2]) : nil
        var (d, m) = monthFirst ? (b, a) : (a, b)
        if m > 12, d <= 12 { swap(&d, &m) }
        return dated(day: d, month: m, year: y, at: i, span: y == nil ? 2 : 3, today: today, limit: limit)
    }

    /// The day, or nil when it does not exist, is past or is over `limit` days away.
    private static func dated(day: Int, month: Int, year: Int?, at i: Int, span: Int, today: LocalDay, limit: Int) -> (day: LocalDay, used: Range<Int>)? {
        let found: LocalDay?
        if let year {
            found = LocalDay(year: year, month: month, day: day)
        } else {
            found = [today.year, today.year + 1].map { LocalDay(year: $0, month: month, day: day) }
                .first { $0.isValid && $0 >= today }
        }
        guard let found, found.isValid, (0...limit).contains(today.days(to: found)) else { return nil }
        // A year written after the date is part of it.
        return (found, i..<(i + span + (year != nil && span == 2 ? 1 : 0)))
    }

    /// True when `words` hold a calendar date `day` refuses for being over `maxDaysAhead` away ("15 oct"
    /// read on 1 November), so the search can say why it looks nowhere.
    static func isBeyondReach(_ words: [Substring], now: Date, tz: TimeZone, monthFirst: Bool) -> Bool {
        guard day(words, now: now, tz: tz, monthFirst: monthFirst) == nil,
              let far = day(words, now: now, tz: tz, monthFirst: monthFirst, limit: .max) else { return false }
        return LocalDay(now, in: tz).days(to: far.day) > maxDaysAhead
    }

    private static func add(_ days: Int, to day: LocalDay) -> LocalDay? {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        guard let d = cal.date(from: DateComponents(year: day.year, month: day.month, day: day.day)),
              let n = cal.date(byAdding: .day, value: days, to: d) else { return nil }
        return LocalDay(n, in: cal.timeZone)
    }

    /// 1 to 31, with an ordinal tail ("12th", "1er").
    private static func dayNumber(_ s: Substring) -> Int? {
        let digits = s.prefix { $0.isASCII && $0.isNumber }
        guard (1...2).contains(digits.count), let n = Int(digits), (1...31).contains(n) else { return nil }
        return ["", "st", "nd", "rd", "th", "er", "e"].contains(String(s.dropFirst(digits.count))) ? n : nil
    }

    private static func year(_ s: Substring) -> Int? {
        guard s.count == 4, let y = Int(s), (2000...2100).contains(y) else { return nil }
        return y
    }

    // MARK: Times

    /// The first time of day in `words` as minutes after midnight, and the indices it covers: a part of
    /// the day ("morning", "soir") or a clock time ("18h30", "6pm", "6 30 pm").
    static func timeOfDay(_ words: [Substring]) -> (minutes: Int, used: Range<Int>)? {
        for i in words.indices {
            if let r = part(words, i) ?? clock(words, i) { return r }
        }
        return nil
    }

    private static func part(_ w: [Substring], _ i: Int) -> (minutes: Int, used: Range<Int>)? {
        if w[i] == "apres", i + 1 < w.count, w[i + 1] == "midi" { return (900, i..<(i + 2)) }
        let minutes: Int
        switch w[i] {
        case "morning", "matin": minutes = 480
        case "midday", "noon", "midi": minutes = 720
        case "afternoon", "aprem": minutes = 900
        case "evening", "soir": minutes = 1140
        case "night", "nuit": minutes = 1320
        default: return nil
        }
        return (minutes, i..<(i + 1))
    }

    private static func clock(_ w: [Substring], _ i: Int) -> (minutes: Int, used: Range<Int>)? {
        let s = w[i]
        let lead = s.prefix { $0.isASCII && $0.isNumber }
        guard (1...2).contains(lead.count), let hour = Int(lead) else { return nil }
        let rest = s.dropFirst(lead.count)
        // "18h", "18h30".
        if rest.first == "h" {
            let tail = rest.dropFirst()
            let minute = tail.isEmpty ? 0 : (tail.count == 2 ? Int(tail) : nil)
            guard let minute, hour < 24, minute < 60 else { return nil }
            return (hour * 60 + minute, i..<(i + 1))
        }
        // "6pm", "6 pm", "6 30pm", "6 30 pm" (the colon folded to a space).
        func meridiem(_ h: Int, _ minute: Int, _ mark: Substring, _ used: Range<Int>) -> (minutes: Int, used: Range<Int>)? {
            guard (1...12).contains(h), minute < 60, mark == "am" || mark == "pm" else { return nil }
            return ((h % 12 + (mark == "pm" ? 12 : 0)) * 60 + minute, used)
        }
        if !rest.isEmpty { return meridiem(hour, 0, rest, i..<(i + 1)) }
        guard i + 1 < w.count else { return nil }
        if let r = meridiem(hour, 0, w[i + 1], i..<(i + 2)) { return r }
        let next = w[i + 1]
        let m = next.prefix { $0.isASCII && $0.isNumber }
        guard m.count == 2, let minute = Int(m) else { return nil }
        let tail = next.dropFirst(2)
        if !tail.isEmpty { return meridiem(hour, minute, tail, i..<(i + 2)) }
        return i + 2 < w.count ? meridiem(hour, minute, w[i + 2], i..<(i + 3)) : nil
    }

    /// True for a weekday or month name on its own ("sun", "mer", "dec"): never an airport code.
    static func isCalendarWord(_ w: Substring) -> Bool {
        weekdays[String(w)] != nil || months[String(w)] != nil
    }

    // MARK: Tables

    /// Folded month names and short forms, English and French, to 1...12.
    private static let months: [String: Int] = {
        let names: [[String]] = [
            ["january", "jan", "janvier", "janv"], ["february", "feb", "fevrier", "fev", "fevr"],
            ["march", "mar", "mars"], ["april", "apr", "avril", "avr"], ["may", "mai"],
            ["june", "jun", "juin"], ["july", "jul", "juillet", "juil"], ["august", "aug", "aout"],
            ["september", "sep", "sept", "septembre"], ["october", "oct", "octobre"],
            ["november", "nov", "novembre"], ["december", "dec", "decembre"],
        ]
        return Dictionary(uniqueKeysWithValues: names.enumerated().flatMap { n, forms in forms.map { ($0, n + 1) } })
    }()

    /// Folded weekday names and short forms to `Calendar`'s weekday, Sunday 1.
    private static let weekdays: [String: Int] = {
        let names: [[String]] = [
            ["sunday", "sun", "dimanche", "dim"], ["monday", "mon", "lundi", "lun"],
            ["tuesday", "tue", "tues", "mardi", "mar"], ["wednesday", "wed", "mercredi", "mer"],
            ["thursday", "thu", "thur", "thurs", "jeudi", "jeu"], ["friday", "fri", "vendredi", "ven"],
            ["saturday", "sat", "samedi", "sam"],
        ]
        return Dictionary(uniqueKeysWithValues: names.enumerated().flatMap { n, forms in forms.map { ($0, n + 1) } })
    }()
}
