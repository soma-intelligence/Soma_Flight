import Foundation

/// Pure helpers behind the airport sheet: counts, filters, wording. Kept out of the views so
/// they can be unit tested.
enum AirportFacts {
    /// Boards and stats refresh every 5 minutes, weather every 15.
    static let boardTTL: Duration = .seconds(300)
    static let weatherTTL: Duration = .seconds(900)

    struct Counts: Equatable {
        var departures: Int
        var airlines: Int
        var airportsServed: Int
        var countries: Int
    }

    /// Today's numbers from both boards: departures, distinct operators, distinct far ends and
    /// their countries (from `lookup`, else guessed from the ICAO prefix).
    static func counts(departures: [Flight], arrivals: [Flight], lookup: (String) -> Airport?) -> Counts {
        let all = departures + arrivals
        let ends = Set(departures.map(\.destinationIcao) + arrivals.map(\.originIcao))
        let countries = Set(ends.map { lookup($0)?.country ?? country(icao: $0) })
        return Counts(departures: departures.count,
                      airlines: Set(all.compactMap { $0.operator ?? String($0.ident.prefix(2)) }).count,
                      airportsServed: ends.count, countries: countries.count)
    }

    /// Rough ICAO prefix to ISO region, for airports missing from the lookup.
    static func country(icao: String) -> String {
        switch icao.first {
        case "K": "US"
        case "C": "CA"
        case "P": icao.hasPrefix("PH") || icao.hasPrefix("PA") ? "US" : String(icao.prefix(2))
        default: icao.hasPrefix("MM") ? "MX" : String(icao.prefix(2))
        }
    }

    /// "🇺🇸" from "US".
    static func flag(_ region: String) -> String {
        region.uppercased().unicodeScalars.compactMap { UnicodeScalar(127_397 + $0.value) }.map(String.init).joined()
    }

    static func countryName(_ region: String) -> String {
        Locale(identifier: "en_US").localizedString(forRegionCode: region) ?? region
    }

    /// Short airline code for display: IATA where known, else the ICAO operator.
    static func airlineCode(_ icao: String) -> String {
        let known = ["AAL": "AA", "UAL": "UA", "DAL": "DL", "SWA": "WN", "ASA": "AS", "JBU": "B6",
                     "AFR": "AF", "BAW": "BA", "NKS": "NK", "FFT": "F9"]
        return known[icao] ?? icao
    }

    /// "Friday, October 23" and "Fri 23"; set `timeZone` on a copy before use.
    static let longDay = Date.FormatStyle(locale: Locale(identifier: "en_US")).weekday(.wide).month(.wide).day()
    static let shortDay = Date.FormatStyle(locale: Locale(identifier: "en_US")).weekday(.abbreviated).day()

    static func scheduled(_ f: Flight, _ kind: BoardKind) -> Date? {
        kind == .arrivals ? f.scheduledIn : f.scheduledOut
    }

    /// Best known gate time: actual, else estimated, else scheduled.
    static func best(_ f: Flight, _ kind: BoardKind) -> Date? {
        kind == .arrivals ? (f.actualIn ?? f.actualOn ?? f.estimatedIn ?? f.scheduledIn)
            : (f.actualOut ?? f.estimatedOut ?? f.scheduledOut)
    }

    // MARK: Board filters

    struct Filter: Hashable {
        /// Local start of day, or nil for every day on the board.
        var day: Date?
        /// Operator (ICAO), or nil for all.
        var airline: String?
        /// The far end (ICAO), or nil for all.
        var place: String?
    }

    static func calendar(_ tz: TimeZone) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = tz
        return c
    }

    /// Local days that hold at least one scheduled flight, ascending.
    static func days(_ flights: [Flight], _ kind: BoardKind, tz: TimeZone) -> [Date] {
        let cal = calendar(tz)
        return Set(flights.compactMap { scheduled($0, kind).map { cal.startOfDay(for: $0) } }).sorted()
    }

    static func apply(_ filter: Filter, to flights: [Flight], kind: BoardKind, tz: TimeZone) -> [Flight] {
        let cal = calendar(tz)
        return flights.filter { f in
            if let day = filter.day, !(scheduled(f, kind).map { cal.isDate($0, inSameDayAs: day) } ?? false) { return false }
            if let a = filter.airline, f.operator != a { return false }
            if let p = filter.place, (kind == .arrivals ? f.originIcao : f.destinationIcao) != p { return false }
            return true
        }
        .sorted { (scheduled($0, kind) ?? .distantFuture, $0.ident) < (scheduled($1, kind) ?? .distantFuture, $1.ident) }
    }

    /// Rows still worth showing by default: anything not yet gone, plus the last half hour.
    static func current(_ flights: [Flight], kind: BoardKind, now: Date) -> [Flight] {
        let cutoff = now.addingTimeInterval(-30 * 60)
        return flights.filter { (best($0, kind) ?? .distantFuture) >= cutoff }
    }

    /// Index of the first row scheduled at or after `now`: where the "now" divider goes.
    static func nowIndex(_ flights: [Flight], kind: BoardKind, now: Date) -> Int? {
        flights.firstIndex { (scheduled($0, kind) ?? .distantFuture) >= now }
    }

    // MARK: Issues wording (our own)

    static func worst(_ a: Severity, _ b: Severity) -> Severity {
        a == .major || b == .major ? .major : (a == .moderate || b == .moderate ? .moderate : .normal)
    }

    static func issuesTitle(_ s: Severity) -> String {
        s == .major ? "Heavy delays today" : "Delays are building"
    }

    static func delayLine(_ s: DelayStats, verb: String) -> String {
        let avg = Format.minutes(Int(s.avgDelayMinutes.rounded()))
        var line = "\(verb) \(avg) late on average, \(s.delayed15) of \(s.total) flights held up"
        if s.canceled > 0 { line += ", \(s.canceled) canceled" }
        return line + "."
    }

    static func weatherLine(_ w: Weather) -> String {
        let temp = w.tempC.map { ", \(Int($0.rounded()))°C" } ?? ""
        return "\(Sky(metar: w.metarRaw).description)\(temp). \(w.category.summary)"
    }
}
