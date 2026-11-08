import Foundation

/// The Schengen short-stay rule for visitors: at most 90 days in any 180-day period (Regulation (EU) 2016/399,
/// article 6). Every day spent in the area counts, the day of entry and the day of exit included, and the 180
/// days are the ones ending on the day being checked. Worked out from the history's flights alone: a trip by
/// land or sea is not seen.
///
/// Members: the 29 states that apply the rule today, from `connection_rules.json` (`schengen`, Bulgaria and
/// Romania included since 1 January 2025; Ireland and Cyprus are not in it). Monaco, San Marino and the Vatican
/// have no border with the area and count as inside it; Andorra does not. Svalbard (ENSB) is Norwegian but
/// outside the area.
public enum Schengen {
    public static let maxDays = 90
    public static let windowDays = 180

    /// The states whose days count.
    public static let members: Set<String> = ConnectionRules.bundled.schengen.union(["MC", "SM", "VA"])
    /// Airports in a member state that are outside the area.
    static let outsideAirports: Set<String> = ["ENSB"]

    /// A calendar date with no time or zone, as a day count; what the rule counts in.
    public struct Day: Hashable, Comparable, Sendable, CustomStringConvertible {
        public let number: Int

        public init(number: Int) { self.number = number }

        public init(year: Int, month: Int, day: Int) {
            let c = DateComponents(year: year, month: month, day: day)
            number = Int(Self.utc.date(from: c)!.timeIntervalSince1970 / 86_400)
        }

        /// The local date of `date` in `zone`.
        public init(_ date: Date, in zone: TimeZone) {
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = zone
            let c = cal.dateComponents([.year, .month, .day], from: date)
            self.init(year: c.year!, month: c.month!, day: c.day!)
        }

        /// Midnight UTC of the day: format it in UTC.
        public var date: Date { Date(timeIntervalSince1970: TimeInterval(number) * 86_400) }

        public static func + (d: Day, n: Int) -> Day { Day(number: d.number + n) }
        public static func - (d: Day, n: Int) -> Day { Day(number: d.number - n) }
        public static func < (a: Day, b: Day) -> Bool { a.number < b.number }

        public var description: String {
            let c = Self.utc.dateComponents([.year, .month, .day], from: date)
            return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
        }

        static let utc: Calendar = {
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = .gmt
            return cal
        }()
    }

    /// Days in the area, first to last, both included; `exit` nil while the traveller is still there.
    public struct Stay: Hashable, Sendable {
        public var entry: Day
        public var exit: Day?

        public init(entry: Day, exit: Day?) { self.entry = entry; self.exit = exit }
    }

    /// Where the count stands on one day.
    public struct Summary: Equatable, Sendable {
        /// The day checked, the last of the window.
        public var day: Day
        /// The first day of the 180-day window.
        public var windowStart: Day
        /// Days in the area within the window (an open stay counts up to `day`).
        public var used: Int
        /// True while the last flight went into the area and none came out.
        public var inside: Bool
        /// The last day the traveller may be in the area staying on from `day` (or arriving on `day` when
        /// outside it) without passing 90 days in any window; nil when the limit is already passed.
        public var stayUntil: Day?
        public var stays: [Stay]

        public var remaining: Int { max(0, Schengen.maxDays - used) }
        public var isOver: Bool { used > Schengen.maxDays }
    }

    /// One border crossing seen in the history.
    struct Crossing: Equatable {
        var day: Day
        var entering: Bool
    }

    /// The stays the flights show, oldest first. Canceled flights are skipped. A flight into the area starts a
    /// stay on its arrival date at the destination; one out of it ends the stay on its departure date at the
    /// origin. A flight inside the area while no stay is open (the traveller came by land) starts one on its
    /// departure date; a flight out with no stay open (came by land) counts its departure day alone.
    /// - Parameter airport: the bundled airports, for the arrival's local date and missing countries.
    public static func stays(_ flights: [PastFlight], airport: (String) -> Airport? = { _ in nil }) -> [Stay] {
        var out: [Stay] = []
        var open: Day?
        for f in flights.filter({ $0.status != .canceled }).sorted(by: { $0.date < $1.date }) {
            let fromIn = inArea(f.originIcao, country: f.originCountry ?? airport(f.originIcao)?.country)
            let toIn = inArea(f.destinationIcao, country: f.destinationCountry ?? airport(f.destinationIcao)?.country)
            let originZone = f.originTz.flatMap(TimeZone.init(identifier:)) ?? airport(f.originIcao)?.timeZone ?? .gmt
            let departs = Day(f.date, in: originZone)
            switch (fromIn, toIn) {
            case (false, true):
                if open == nil {
                    let minutes = f.blockMinutes ?? f.airMinutes ?? 0
                    let zone = airport(f.destinationIcao)?.timeZone ?? originZone
                    open = Day(f.date.addingTimeInterval(TimeInterval(minutes * 60)), in: zone)
                }
            case (true, false):
                out.append(Stay(entry: open ?? departs, exit: departs))
                open = nil
            case (true, true):
                if open == nil { open = departs }
            case (false, false):
                break
            }
        }
        if let open { out.append(Stay(entry: open, exit: nil)) }
        return out
    }

    /// The count on `day`; nil when the history never shows the traveller in the area.
    public static func summary(_ flights: [PastFlight], on day: Day,
                               airport: (String) -> Airport? = { _ in nil }) -> Summary? {
        summary(stays: stays(flights, airport: airport), on: day)
    }

    /// The count on `day` for known stays; nil when there are none. Stays after `day` are ignored.
    public static func summary(stays: [Stay], on day: Day) -> Summary? {
        let stays = stays.filter { $0.entry <= day }
        guard !stays.isEmpty else { return nil }
        let inside = stays.last.map { $0.exit == nil || $0.exit! >= day } ?? false
        let present = days(stays, through: day)
        let start = day - (windowDays - 1)
        let used = present.filter { $0 >= start && $0 <= day }.count
        return Summary(day: day, windowStart: start, used: used, inside: inside,
                       stayUntil: lastDay(present: present, from: day), stays: stays)
    }

    /// Every day in the area up to `day`, an open stay running to `day`.
    static func days(_ stays: [Stay], through day: Day) -> Set<Day> {
        var set = Set<Day>()
        for s in stays {
            let last = min(s.exit ?? day, day)
            guard s.entry <= last else { continue }
            for n in s.entry.number...last.number { set.insert(Day(number: n)) }
        }
        return set
    }

    /// The last day of an unbroken stay from `day` that keeps every window at 90 days or under; nil when
    /// `day` itself would pass the limit.
    static func lastDay(present: Set<Day>, from day: Day) -> Day? {
        // Only the days that can still fall in a window from `day` on.
        var present = present.filter { $0 > day - windowDays }
        var last: Day?
        var d = day
        // 90 days in a row fill any window, so the answer is never more than 89 days ahead.
        while d.number <= day.number + maxDays {
            present.insert(d)
            let start = d - (windowDays - 1)
            let used = present.reduce(0) { $0 + ($1 >= start && $1 <= d ? 1 : 0) }
            if used > maxDays { break }
            last = d
            d = d + 1
        }
        return last
    }

    static func inArea(_ icao: String, country: String?) -> Bool {
        guard let country, !outsideAirports.contains(icao.uppercased()) else { return false }
        return members.contains(country.uppercased())
    }
}

/// What the screens say about the 90/180 count.
enum SchengenFacts {
    static let title = "Schengen 90/180"

    /// "12 of 90 days used".
    static func used(_ s: Schengen.Summary) -> String {
        String(localized: "\(s.used) of 90 days used", bundle: .main)
    }

    /// "You can stay until 3 Feb 2027", "If you arrive today, you can stay until …", or the limit passed.
    static func until(_ s: Schengen.Summary, locale: Locale = .current) -> String {
        guard let last = s.stayUntil else {
            return s.isOver ? String(localized: "Over the 90 days in this window", bundle: .main)
                : String(localized: "No days left today", bundle: .main)
        }
        let date = day(last, locale: locale)
        return s.inside
            ? String(localized: "You can stay until \(date)", bundle: .main)
            : String(localized: "Arriving today, you could stay until \(date)", bundle: .main)
    }

    /// "29 Apr 2026 to 25 Oct 2026".
    static func window(_ s: Schengen.Summary, locale: Locale = .current) -> String {
        let a = day(s.windowStart, locale: locale), b = day(s.day, locale: locale)
        return String(localized: "\(a) to \(b)", bundle: .main)
    }

    /// One stay: "14 Sep to 21 Sep 2026 · 8 days", "Since 14 Sep 2026 · 8 days" while open.
    static func stay(_ s: Schengen.Stay, through day: Schengen.Day, locale: Locale = .current) -> String {
        let last = s.exit ?? day
        let n = last.number - s.entry.number + 1
        let length = n == 1 ? String(localized: "1 day", bundle: .main) : String(localized: "\(n) days", bundle: .main)
        if s.exit == nil {
            return "\(String(localized: "Since \(Self.day(s.entry, locale: locale))", bundle: .main)) · \(length)"
        }
        if s.entry == last { return "\(Self.day(s.entry, locale: locale)) · \(length)" }
        return "\(String(localized: "\(Self.day(s.entry, locale: locale)) to \(Self.day(last, locale: locale))", bundle: .main)) · \(length)"
    }

    static let caveat = "Counted from your flights only: trips by land or sea are not seen. The rule is for short stays by visitors from outside the EU. Check with the border authority before you rely on it."

    /// "3 Feb 2027".
    static func day(_ d: Schengen.Day, locale: Locale) -> String {
        var style = Date.FormatStyle(date: .abbreviated, time: .omitted, locale: locale)
        style.timeZone = .gmt
        return d.date.formatted(style)
    }
}
