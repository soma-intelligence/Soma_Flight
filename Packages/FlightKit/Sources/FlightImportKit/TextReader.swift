import Foundation
#if canImport(PDFKit)
import PDFKit
#endif

/// The text of a PDF (an e-ticket), read on the device; nil when it has none (a scan).
public enum PDFText {
    public static func text(_ data: Data) -> String? {
        #if canImport(PDFKit)
        guard let doc = PDFDocument(data: data), let s = doc.string, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return s
        #else
        return nil
        #endif
    }
}

/// Reads flights out of the text of a confirmation: each flight number starts a leg, and the leg's
/// airports, day, times and seat are looked for around it. The day sits before the number in some
/// layouts ("Sun 14 Mar · AF 84") and after it in others ("AF 84 · 14 Mar 2027"): the text before the
/// first number decides which for the whole email.
public struct TextReader {
    /// When the email was sent; a day written without its year is read as the first one on or after
    /// about a month before it.
    var reference: Date
    var isAirport: (String) -> Bool

    func flights(in raw: String) -> [ImportedFlight] {
        let text = raw.replacingOccurrences(of: "\r", with: "\n").replacingOccurrences(of: "\u{00A0}", with: " ")
        let numbers = FlightNumberText.all(in: text)
        guard !numbers.isEmpty else { return [] }
        let booking = Self.bookingReference(in: text)
        let before = text[..<numbers[0].range.lowerBound].suffix(Self.window)
        let dayFirstLayout = !dates(in: String(before)).isEmpty

        var out: [ImportedFlight] = []
        for (i, n) in numbers.enumerated() {
            let segmentEnd = i + 1 < numbers.count ? numbers[i + 1].range.lowerBound : text.endIndex
            let after = String(text[n.range.upperBound..<segmentEnd].prefix(Self.segmentLimit))
            let previousEnd = i > 0 ? numbers[i - 1].range.upperBound : text.startIndex
            let lead = String(text[previousEnd..<n.range.lowerBound].suffix(Self.window))

            let day: LocalDay?
            if dayFirstLayout {
                day = dates(in: lead).last ?? dates(in: after).first
            } else {
                day = dates(in: after).first ?? dates(in: lead).last
            }
            guard let day else { continue }
            let codes = airports(in: after).count >= 2 ? airports(in: after) : airports(in: lead + "\n" + after)
            guard codes.count >= 2 else { continue }
            var f = ImportedFlight(airline: n.airline, number: n.number, origin: codes[0], destination: codes[1], day: day,
                                   evidence: ["\u{201C}\(Self.line(around: n.range, in: text))\u{201D}"])
            let times = Self.times(in: after)
            f.departureTime = times.first
            f.arrivalTime = times.dropFirst().first
            f.seat = Self.seat(in: after) ?? (numbers.count == 1 ? Self.seat(in: text) : nil)
            f.cabin = Self.cabin(in: after) ?? (numbers.count == 1 ? Self.cabin(in: text) : nil)
            f.bookingReference = booking
            if after.range(of: "cancel", options: .caseInsensitive) != nil,
               after.range(of: "cancellation polic", options: .caseInsensitive) == nil { f.canceled = true }
            out.append(f)
        }
        return out
    }

    static let window = 160
    static let segmentLimit = 700

    /// The line the flight number sits on, cut to 80 characters, for the evidence.
    static func line(around range: Range<String.Index>, in text: String) -> String {
        let start = text[..<range.lowerBound].lastIndex(of: "\n").map { text.index(after: $0) } ?? text.startIndex
        let end = text[range.upperBound...].firstIndex(of: "\n") ?? text.endIndex
        let s = text[start..<end].trimmingCharacters(in: .whitespaces)
        return s.count > 80 ? String(s.prefix(79)) + "\u{2026}" : s
    }

    // MARK: Airports

    /// Airport codes in reading order, each once: "(CDG)" first-class, then any three capitals the
    /// airport test accepts.
    func airports(in text: String) -> [String] {
        var out: [String] = []
        for m in text.matches(of: /(?:^|[^A-Za-z0-9])([A-Z]{3})(?![A-Za-z0-9])/) {
            let code = String(m.1)
            guard isAirport(code), !out.contains(code) else { continue }
            out.append(code)
            if out.count == 2 { break }
        }
        return out
    }

    // MARK: Dates

    static let months: [String: Int] = [
        "jan": 1, "january": 1, "janv": 1, "janvier": 1, "januar": 1, "ene": 1, "enero": 1,
        "feb": 2, "february": 2, "fev": 2, "févr": 2, "fevr": 2, "février": 2, "fevrier": 2, "februar": 2, "febrero": 2,
        "mar": 3, "march": 3, "mars": 3, "märz": 3, "marz": 3, "marzo": 3, "mär": 3,
        "apr": 4, "april": 4, "avr": 4, "avril": 4, "abr": 4, "abril": 4,
        "may": 5, "mai": 5, "mayo": 5,
        "jun": 6, "june": 6, "juin": 6, "juni": 6, "junio": 6,
        "jul": 7, "july": 7, "juil": 7, "juillet": 7, "juli": 7, "julio": 7,
        "aug": 8, "august": 8, "août": 8, "aout": 8, "ago": 8, "agosto": 8,
        "sep": 9, "sept": 9, "september": 9, "septembre": 9, "septiembre": 9,
        "oct": 10, "october": 10, "octobre": 10, "okt": 10, "oktober": 10, "octubre": 10,
        "nov": 11, "november": 11, "novembre": 11, "noviembre": 11,
        "dec": 12, "december": 12, "déc": 12, "décembre": 12, "decembre": 12, "dez": 12, "dezember": 12, "dic": 12,
        "diciembre": 12,
    ]

    static func month(_ word: Substring) -> Int? {
        let w = word.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return months[w]
    }

    /// Every day written in `text`, in order: "2027-03-14", "14 Mar 2027", "14. März", "Mar 14, 2027",
    /// "14MAR27", "14/03/2027" (day first unless that cannot be). A day without a year is placed near
    /// the reference date.
    func dates(in text: String) -> [LocalDay] {
        var found: [(String.Index, LocalDay)] = []
        let monthWord = #"([A-Za-zÀ-ÿ]{3,9}\.?)"#
        func add(_ at: String.Index, _ y: Int?, _ m: Int?, _ d: Int?) {
            guard let m, let d else { return }
            let year = y.map { $0 < 100 ? 2000 + $0 : $0 } ?? infer(month: m, day: d)
            let day = LocalDay(year: year, month: m, day: d)
            if day.isValid, (1950...2100).contains(year) { found.append((at, day)) }
        }
        for m in text.matches(of: /([0-9]{4})-([0-9]{2})-([0-9]{2})/) {
            add(m.range.lowerBound, Int(m.1), Int(m.2), Int(m.3))
        }
        // 14 Mar 2027, 14. März 2027, 14 March, Sun 14 Mar
        if let re = try? Regex<(Substring, Substring, Substring, Substring?)>(#"(?:^|[^0-9])([0-9]{1,2})(?:st|nd|rd|th|er)?\.?\s+"# + monthWord + #"(?:,?\s+([0-9]{4}))?(?![A-Za-z])"#) {
            for m in text.matches(of: re) {
                add(m.range.lowerBound, m.3.flatMap { Int($0) }, Self.month(m.2), Int(m.1))
            }
        }
        // Mar 14, 2027, March 14 2027, Sunday, March 14
        if let re = try? Regex<(Substring, Substring, Substring, Substring?)>(#"(?:^|[^A-Za-z])"# + monthWord + #"\s+([0-9]{1,2})(?:st|nd|rd|th)?(?![0-9:])(?:,?\s+([0-9]{4}))?"#) {
            for m in text.matches(of: re) {
                add(m.range.lowerBound, m.3.flatMap { Int($0) }, Self.month(m.1), Int(m.2))
            }
        }
        // 14MAR27, 14MAR
        for m in text.matches(of: /(?:^|[^A-Za-z0-9])([0-9]{2})(JAN|FEB|MAR|APR|MAY|JUN|JUL|AUG|SEP|OCT|NOV|DEC)([0-9]{2})?(?![A-Za-z0-9])/) {
            add(m.range.lowerBound, m.3.flatMap { Int($0) }, Self.month(m.2), Int(m.1))
        }
        // 14/03/2027, 14.03.2027, 03/14/2027
        for m in text.matches(of: /(?:^|[^0-9\/.])([0-9]{1,2})[\/.]([0-9]{1,2})[\/.]([0-9]{4})(?![0-9])/) {
            let a = Int(m.1)!, b = Int(m.2)!
            let (d, mo) = a > 12 || b <= 12 ? (a, b) : (b, a)
            add(m.range.lowerBound, Int(m.3), mo, d)
        }
        return found.sorted { $0.0 < $1.0 }.map(\.1)
    }

    /// The year for a day written without one: the first such day on or after 30 days before the reference.
    func infer(month: Int, day: Int) -> Int {
        let ref = LocalDay(reference, in: TimeZone(identifier: "UTC")!)
        let floor = LocalDay(reference.addingTimeInterval(-30 * 86_400), in: TimeZone(identifier: "UTC")!)
        for year in [ref.year - 1, ref.year, ref.year + 1] {
            let candidate = LocalDay(year: year, month: month, day: day)
            if candidate >= floor { return year }
        }
        return ref.year
    }

    // MARK: Times, seats, references

    /// Clock times in order: "10:15", "7:05 PM", "19h05".
    static func times(in text: String) -> [LocalTime] {
        var out: [LocalTime] = []
        for m in text.matches(of: /(?:^|[^0-9:])([0-9]{1,2})[:h]([0-5][0-9])(?![0-9])\s*([AaPp]\.?[Mm]\.?)?/) {
            var h = Int(m.1)!
            if let ampm = m.3?.lowercased() {
                if ampm.hasPrefix("p"), h < 12 { h += 12 }
                if ampm.hasPrefix("a"), h == 12 { h = 0 }
            }
            if let t = LocalTime(hour: h, minute: Int(m.2)!) { out.append(t) }
        }
        return out
    }

    /// "Seat 23A", "Siège : 4C", "Sitzplatz 44C".
    public static func seat(in text: String) -> String? {
        guard let m = text.firstMatch(of: /(?i:seat|siège|siege|sitzplatz|asiento)s?\s*(?:number|no\.?|n°)?\s*:?\s*([0-9]{1,2}[A-K])(?![A-Za-z0-9])/)
        else { return nil }
        return String(m.1).uppercased()
    }

    static func cabin(in text: String) -> String? {
        let lower = text.lowercased()
        for (word, name) in [("premium economy", "Premium Economy"), ("first class", "First"), ("business class", "Business"),
                             ("business", "Business"), ("economy", "Economy"), ("première", "First"), ("affaires", "Business")]
        where lower.contains(word) {
            return name
        }
        return nil
    }

    /// "Booking reference: ABC123", "Confirmation code XYZ9KL", "PNR: Q1W2E3", "Record locator ..." and
    /// their French, German and Spanish forms; six letters and digits with at least one letter.
    public static func bookingReference(in text: String) -> String? {
        let labels = #"(?i:booking\s+(?:reference|ref\.?|code|number)|confirmation\s+(?:code|number|#)|reservation\s+(?:code|number)|record\s+locator|pnr|référence\s+de\s+(?:réservation|dossier)|reference\s+de\s+reservation|numéro\s+de\s+réservation|code\s+de\s+réservation|buchungscode|buchungsnummer|código\s+de\s+reserva|localizador)"#
        guard let re = try? Regex<(Substring, Substring)>(labels + #"\s*[:#]?\s*\n?\s*([A-Z0-9]{6})(?![A-Za-z0-9])"#),
              let m = text.firstMatch(of: re) else { return nil }
        let code = String(m.1)
        return code.contains(where: \.isLetter) ? code : nil
    }
}
