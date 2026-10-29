import Foundation
import FlightCore

/// Wording for the full Passport page, over figures the Rust core computed (`PassportDetail`). Nothing
/// here counts flights or adds distances: it formats, converts units and builds the passport's
/// machine readable strip.
enum PassportFacts {
    // MARK: Machine readable strip

    /// The characters an MRZ line may hold.
    static let mrzAlphabet = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789<")
    static let mrzWidth = 44

    /// Two lines of exactly 44 characters from `[A-Z0-9<]`, drawn under the passport card.
    /// Line 1: `P<SOMAFLIGHT<<` then the name (accents folded, letters only, spaces and hyphens as `<`,
    /// `TRAVELLER` when there is none). Line 2: the scope (`ALLTIME` or the year), the flight count and the
    /// issue date `YYMMDD`. Both padded with `<` and cut at 44.
    static func mrz(name: String?, year: Int?, flights: Int, issued: Date, timeZone: TimeZone = .current) -> [String] {
        let cleaned = mrzName(name ?? "")
        let line1 = "P<SOMAFLIGHT<<" + (cleaned.isEmpty ? "TRAVELLER" : cleaned)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let d = calendar.dateComponents([.year, .month, .day], from: issued)
        let date = String(format: "%02d%02d%02d", (d.year ?? 0) % 100, d.month ?? 0, d.day ?? 0)
        let scope = year.map { String($0) } ?? "ALLTIME"
        let line2 = "\(scope)<<FLIGHTS\(max(flights, 0))<<ISSUED\(date)"
        return [padded(line1), padded(line2)]
    }

    /// "José-María  de la Peña" gives "JOSE<MARIA<DE<LA<PENA".
    static func mrzName(_ name: String) -> String {
        let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US"))
            .uppercased()
        var out = ""
        for ch in folded {
            if ch.isASCII, ch.isLetter {
                out.append(ch)
            } else if ch == " " || ch == "-" || ch == "'" || ch == "." {
                if !out.isEmpty, out.last != "<" { out.append("<") }
            }
        }
        while out.last == "<" { out.removeLast() }
        return out
    }

    private static func padded(_ line: String) -> String {
        let kept = String(line.filter { mrzAlphabet.contains($0) }.prefix(mrzWidth))
        return kept + String(repeating: "<", count: mrzWidth - kept.count)
    }

    // MARK: Multiples

    /// "7.0", "0.7", "0.06": one decimal from 0.1 up, two below.
    static func multiple(_ value: Double) -> String {
        String(format: value >= 0.1 || value == 0 ? "%.1f" : "%.2f", value)
    }

    /// The three distance comparisons, from the core's ratios: "7.0x" around the Earth and so on.
    static func ratios(_ d: PassportDetail) -> [(symbol: String, value: String, label: String, fill: Double)] {
        [("globe.americas.fill", multiple(d.earthRatio) + "x", "around the Earth", d.earthRatio),
         ("moon.fill", multiple(d.moonRatio) + "x", "to the Moon", d.moonRatio),
         ("sun.max.fill", multiple(d.sunRatio) + "x", "around the Sun", d.sunRatio)]
    }

    // MARK: Time

    /// Flight time in days, weeks, months (30.44 days) and years (365.25 days), worded as `multiple`.
    static func timeUnits(minutes: UInt64) -> [(label: String, value: String)] {
        let days = Double(minutes) / 1440
        return [("Days", multiple(days)), ("Weeks", multiple(days / 7)),
                ("Months", multiple(days / 30.44)), ("Years", multiple(days / 365.25))]
    }

    /// "359h 8m" split so the units can be set smaller: [("359", "h"), ("8", "m")].
    static func hoursMinutes(_ minutes: UInt64) -> [(number: String, unit: String)] {
        let h = minutes / 60, m = minutes % 60
        if h == 0 { return [("\(m)", "m")] }
        return [("\(h)", "h"), ("\(m)", "m")]
    }

    // MARK: Counts and flights

    /// "1,234" in the app's number style.
    static func count<T: BinaryInteger>(_ n: T) -> String {
        Int(n).formatted(.number.grouping(.automatic).locale(Locale(identifier: "en_US")))
    }

    /// Shortest and longest only mean something with two flights or more; one flight is both.
    static func showsExtremes(_ d: PassportDetail) -> Bool { d.flights >= 2 }

    /// "AC 413" from "AC413" (the designator and the number apart).
    static func spacedIdent(_ ident: String) -> String {
        let code = TravelFacts.airlineCode(ident: ident)
        guard code.count < ident.count else { return ident }
        return code + " " + ident.dropFirst(code.count)
    }

    /// "30 Sep 2021" in the time zone given (the origin airport's when known).
    static func shortDate(_ seconds: Int64, timeZone: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.timeZone = timeZone
        f.dateFormat = "d MMM yyyy"
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(seconds)))
    }

    /// Bar labels and counts for the "Flights per" chart, as the core counted them.
    enum Period: String, CaseIterable, Identifiable {
        case year = "Year", month = "Month", weekday = "Weekday"
        var id: String { rawValue }
    }

    static let monthNames = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
    static let weekdayNames = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

    static func bars(_ d: PassportDetail, _ period: Period) -> [(label: String, count: Int)] {
        switch period {
        case .year: d.perYear.sorted { $0.year < $1.year }.map { (String($0.year), Int($0.flights)) }
        case .month: zip(monthNames, d.perMonth).map { ($0, Int($1)) }
        case .weekday: zip(weekdayNames, d.perWeekday).map { ($0, Int($1)) }
        }
    }

    /// Grid lines for a bar chart whose tallest bar is `max`: a step of 1, 2, 5, 10, 20, 50... giving three
    /// or four lines above zero, the top line at or over the tallest bar.
    static func ticks(max: Int) -> (values: [Int], top: Int) {
        let target = Swift.max(max, 1)
        var step = 1
        let ladder = [1, 2, 5]
        var i = 0
        while (target + step - 1) / step > 4 {
            i += 1
            step = ladder[i % 3] * Int(pow(10, Double(i / 3)))
        }
        let top = Swift.max(step, (target + step - 1) / step * step)
        return (Array(stride(from: 0, through: top, by: step)), top)
    }

    // MARK: Map

    /// Routes as airport pairs (the core's `routesByFlights` keys, `ORIG-DEST` in ICAO), each pair once
    /// whatever its direction, most flown first; pairs whose airports are unknown are left out.
    static func routes(_ d: PassportDetail, lookup: (String) -> Airport?) -> [(Airport, Airport)] {
        var seen = Set<String>()
        var out: [(Airport, Airport)] = []
        for t in d.routesByFlights {
            let parts = t.key.split(separator: "-").map(String.init)
            guard parts.count == 2, let a = lookup(parts[0]), let b = lookup(parts[1]) else { continue }
            let key = [a.id, b.id].sorted().joined(separator: "-")
            if seen.insert(key).inserted { out.append((a, b)) }
        }
        return out
    }

    /// The airports the core counted, most visited first, known to the directory.
    static func airports(_ d: PassportDetail, lookup: (String) -> Airport?) -> [Airport] {
        d.airports.compactMap { lookup($0.icao) }
    }
}
