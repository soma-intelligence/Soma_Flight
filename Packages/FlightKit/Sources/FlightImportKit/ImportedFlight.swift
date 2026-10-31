import Foundation

/// A day as printed on a ticket or a calendar: local to the airport it belongs to, no zone.
public struct LocalDay: Codable, Sendable, Hashable, Comparable, CustomStringConvertible {
    public var year: Int
    public var month: Int
    public var day: Int

    public init(year: Int, month: Int, day: Int) {
        self.year = year; self.month = month; self.day = day
    }

    /// The day `date` falls on in `zone`.
    public init(_ date: Date, in zone: TimeZone) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        let c = cal.dateComponents([.year, .month, .day], from: date)
        self.init(year: c.year ?? 1970, month: c.month ?? 1, day: c.day ?? 1)
    }

    /// True when the day exists (no 31 April).
    public var isValid: Bool {
        guard (1...12).contains(month), day >= 1 else { return false }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        guard let first = cal.date(from: DateComponents(year: year, month: month, day: 1)),
              let range = cal.range(of: .day, in: .month, for: first) else { return false }
        return range.contains(day)
    }

    /// `YYYY-MM-DD`.
    public var description: String { String(format: "%04d-%02d-%02d", year, month, day) }

    /// Days from `self` to `other` (positive when `other` is later).
    public func days(to other: LocalDay) -> Int {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        guard let a = cal.date(from: DateComponents(year: year, month: month, day: day)),
              let b = cal.date(from: DateComponents(year: other.year, month: other.month, day: other.day)) else { return 0 }
        return Int((b.timeIntervalSince(a) / 86_400).rounded())
    }

    public static func < (a: LocalDay, b: LocalDay) -> Bool {
        (a.year, a.month, a.day) < (b.year, b.month, b.day)
    }
}

/// A wall clock time, local to an airport.
public struct LocalTime: Codable, Sendable, Hashable, CustomStringConvertible {
    public var hour: Int
    public var minute: Int

    public init?(hour: Int, minute: Int) {
        guard (0..<24).contains(hour), (0..<60).contains(minute) else { return nil }
        self.hour = hour; self.minute = minute
    }

    /// "HH:mm".
    public var description: String { String(format: "%02d:%02d", hour, minute) }
}

/// One flight read from something the traveller brought in (an export file, a calendar event, a
/// confirmation email), as written there: codes as found, days and times local to the airports. The app
/// turns it into a past flight or a flight to follow once it knows the airports (`FlightImportPlan`).
public struct ImportedFlight: Codable, Sendable, Hashable {
    /// The airline as written: an IATA ("AF") or ICAO ("AFR") code, or a name.
    public var airline: String?
    /// The flight number without the airline ("84"); leading zeros kept as written.
    public var number: String?
    /// The airports as written, IATA or ICAO; nil when the source does not say.
    public var origin: String?
    public var destination: String?
    /// The departure day, local at the origin.
    public var day: LocalDay
    public var departureTime: LocalTime?
    /// The arrival day and time, local at the destination, when the source gives them.
    public var arrivalDay: LocalDay?
    public var arrivalTime: LocalTime?
    /// The departure instant when the source gives one with its zone (a calendar event); it wins over
    /// `day` and `departureTime`, which are then its local reading.
    public var departure: Date?
    /// An aircraft as written: a designator ("B789") or a name ("Boeing 787-9").
    public var aircraft: String?
    public var registration: String?
    public var seat: String?
    /// The cabin as written ("ECONOMY", "Premium Economy", "Business").
    public var cabin: String?
    /// The seat's position as written ("WINDOW").
    public var seatPosition: String?
    /// Why the traveller flew, as written ("LEISURE", "BUSINESS").
    public var reason: String?
    public var notes: String?
    public var bookingReference: String?
    /// Minutes the flight reached the gate after (or, negative, before) its schedule, when the source says.
    public var delayMinutes: Int?
    public var canceled: Bool
    /// The airport the flight landed at instead, when it was diverted.
    public var divertedTo: String?
    /// What the flight was read from, for the screen: "Title “AF 84 SFO → CDG”".
    public var evidence: [String]

    public init(airline: String? = nil, number: String? = nil, origin: String? = nil, destination: String? = nil,
                day: LocalDay, departureTime: LocalTime? = nil, arrivalDay: LocalDay? = nil,
                arrivalTime: LocalTime? = nil, departure: Date? = nil, aircraft: String? = nil,
                registration: String? = nil, seat: String? = nil, cabin: String? = nil, seatPosition: String? = nil,
                reason: String? = nil, notes: String? = nil, bookingReference: String? = nil, delayMinutes: Int? = nil,
                canceled: Bool = false,
                divertedTo: String? = nil, evidence: [String] = []) {
        self.airline = airline; self.number = number; self.origin = origin; self.destination = destination
        self.day = day; self.departureTime = departureTime; self.arrivalDay = arrivalDay; self.arrivalTime = arrivalTime
        self.departure = departure; self.aircraft = aircraft; self.registration = registration; self.seat = seat
        self.cabin = cabin; self.seatPosition = seatPosition; self.reason = reason; self.notes = notes
        self.bookingReference = bookingReference; self.delayMinutes = delayMinutes; self.canceled = canceled; self.divertedTo = divertedTo
        self.evidence = evidence
    }

    /// The flight number as one word, upper case, leading zeros of the number dropped ("AF0084" gives
    /// "AF84"); nil without both parts.
    public var ident: String? {
        guard let a = airline?.filter({ !$0.isWhitespace }).uppercased(), !a.isEmpty, a.count <= 3,
              let n = number?.filter({ !$0.isWhitespace }).uppercased(), !n.isEmpty else { return nil }
        let digits = n.prefix { $0.isNumber }
        let suffix = n.dropFirst(digits.count)
        let trimmed = digits.drop { $0 == "0" }
        return a + (trimmed.isEmpty ? "0" : String(trimmed)) + suffix
    }
}

/// A flight number in text: "AF 84", "AF0084", "U2 1234", "9W 7". The airline part is two letters, a
/// letter and a digit, or a digit and a letter (IATA), or three letters (ICAO); the number one to four
/// digits and an optional letter.
public enum FlightNumberText {
    /// The airline and number of every flight number in `text`, in order. A three letter (ICAO) airline
    /// only counts written against its number ("AFR84"): "CDG 14" is an airport and a day.
    public static func all(in text: String) -> [(airline: String, number: String, range: Range<String.Index>)] {
        var out: [(String, String, Range<String.Index>)] = []
        for m in text.matches(of: pattern) {
            let airline = String(m.1), number = String(m.2)
            if airline.count == 3, m.1.endIndex < m.2.startIndex { continue }
            if notAirlines.contains(airline) || isAircraft(airline + number) { continue }
            if Int(number.prefix { $0.isNumber }) == 0 { continue }
            out.append((airline, number, m.range))
        }
        return out
    }

    nonisolated(unsafe) static let pattern = /(?:^|[^A-Za-z0-9])([A-Z]{2,3}|[A-Z][0-9]|[0-9][A-Z])[ \u{00A0}]?([0-9]{1,4}[A-Z]?)(?![A-Za-z0-9])/

    /// "A320", "B737", "E190", "A20N": aircraft types, which read like a flight number.
    static func isAircraft(_ token: String) -> Bool {
        token.wholeMatch(of: /A[0-9]{3}[A-Z]?|A[0-9]{2}N|B7[0-9]{2}[A-Z]?|B7[0-9]M|E[0-9]{3}|E[0-9]{2}|CRJ[0-9]+|DH[0-9]+|Q[0-9]{3}/) != nil
    }

    /// Words that look like a flight number but are something else in a booking ("PNR 2", "GATE 12").
    static let notAirlines: Set<String> = [
        "PNR", "GATE", "ROW", "SEAT", "BAG", "BAGS", "PM", "AM", "TO", "VIA", "NO", "NR", "ID", "REF", "TEL", "FAX",
        "BOX", "APT", "STE", "KG", "LB", "LBS", "CM", "MM", "KM", "MI", "TV", "USB", "UTC", "GMT", "PST", "PDT",
        "EST", "EDT", "CET", "BST", "JST", "AND", "THE", "FOR", "ON", "AT", "OF", "IN", "BY", "OR", "IS", "IT",
        "TERMINAL", "T", "HALL", "ZONE", "GROUP", "ADULT", "CHILD", "PAX", "MON", "TUE", "WED", "THU", "FRI",
        "SAT", "SUN", "JAN", "FEB", "MAR", "APR", "MAY", "JUN", "JUL", "AUG", "SEP", "OCT", "NOV", "DEC", "USD",
        "EUR", "GBP", "CAD", "AUD", "JPY", "CHF", "VAT", "TAX", "QTY", "MR", "MRS", "MS", "DR", "UK", "US", "EU",
        "CO", "ST", "RD", "AV", "AVE",
    ]
}
