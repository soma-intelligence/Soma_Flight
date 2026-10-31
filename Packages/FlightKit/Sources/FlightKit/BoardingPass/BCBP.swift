import Foundation

/// A boarding pass barcode read as IATA Bar Coded Boarding Pass data (Resolution 792, format "M"): the
/// string every airline prints in the PDF417, Aztec or QR code of a paper, mobile or Wallet boarding pass.
///
/// The layout is fixed width. A 23 character header (format code, number of legs, passenger name,
/// e-ticket flag) is followed, for each leg, by 37 mandatory characters and a variable block whose size
/// the leg gives in two hex digits. The first leg's variable block opens with the version marker `>` and
/// the conditional items shared by every leg (among them the date the pass was issued); every leg's block
/// then carries its own conditional items and free airline data. Security data (`^`) may close the string.
///
/// Pure: no clock, no I/O. `day(near:)` turns the leg's day of the year into a date.
public struct BCBP: Sendable, Hashable {
    /// "M": the only format in use.
    public var formatCode: Character
    /// As printed: "DESMARAIS/LUC MR", family name first, padded fields trimmed.
    public var passengerName: String
    /// True for an electronic ticket ("E").
    public var electronicTicket: Bool
    public var legs: [Leg]
    /// The last digit of the year the pass was issued, when the pass says.
    public var issueYearDigit: Int?
    /// The day of that year it was issued (1 to 366), when the pass says.
    public var issueDayOfYear: Int?
    /// The version of the conditional items (the digit after `>`).
    public var version: Int?
    /// The airline that issued the pass ("AF"), when the pass says.
    public var issuingAirline: String?
    /// The airline's signature over the data, when present (`^` section).
    public var securityData: String?

    /// One flight of the pass.
    public struct Leg: Sendable, Hashable {
        /// Booking reference of the operating carrier ("ABC123").
        public var pnr: String
        /// IATA airport codes.
        public var from: String
        public var to: String
        /// Operating carrier, IATA designator ("AF", "B6").
        public var carrier: String
        /// Flight number without leading zeros, with its operational suffix when any ("84", "1234A").
        public var flightNumber: String
        /// Day of the year the flight leaves, local time at `from` (1 to 366).
        public var dayOfYear: Int
        /// Booking class letter ("J").
        public var compartment: Character?
        /// Seat without leading zeros ("23A"); nil when blank. May be a word such as "INF" or "GATE".
        public var seat: String?
        /// Check-in sequence number without leading zeros ("12"); nil when blank.
        public var sequence: String?
        /// Passenger status code ("1": checked in).
        public var passengerStatus: Character?
        /// Marketing carrier when it differs from the one operating ("DL"), from the conditional items.
        public var marketingCarrier: String?
        /// Frequent flyer airline and number, from the conditional items.
        public var frequentFlyerAirline: String?
        public var frequentFlyerNumber: String?
        /// Three digit airline code and ticket number ("057", "2401234567").
        public var airlineNumericCode: String?
        public var documentNumber: String?
        /// Free baggage allowance as printed ("2PC", "20K").
        public var baggageAllowance: String?
        /// "Y" when the passenger may use a fast track lane.
        public var fastTrack: Bool?
        /// Whatever the airline keeps after the standard items; airlines often put the boarding group here.
        public var airlineData: String?

        /// The day the flight leaves, in the year that brings it closest to `near` (the leg gives no year).
        /// `BCBP.day(of:near:)` uses the pass's issue date as well when it has one.
        public func day(near: Date, timeZone: TimeZone = .gmt) -> DateComponents? {
            BCBP.day(of: dayOfYear, near: near, timeZone: timeZone, issue: nil)
        }
    }

    /// Why a string is not a boarding pass barcode.
    public enum ParseError: Error, Equatable, Sendable {
        /// Not "M" format data at all (a URL, a QR code for something else).
        case notBoardingPass
        /// The string ends inside a mandatory field.
        case tooShort(field: String)
        /// A field holds something it cannot hold ("ZZ" as a leg count, letters as a date).
        case badField(String)
    }

    // MARK: Parsing

    /// Reads a BCBP string. Leading and trailing newlines go; everything else counts, since the layout
    /// is fixed width. Conditional items are optional: a block that ends early keeps what it holds.
    public static func parse(_ raw: String) throws(ParseError) -> BCBP {
        let text = raw.trimmingCharacters(in: .newlines)
        var c = Cursor(Array(text))
        guard c.peek == "M" || c.peek == "m" else { throw .notBoardingPass }
        let format = try c.take(1, "format code").first ?? "M"
        guard let count = Int(try c.take(1, "number of legs")), (1...4).contains(count) else {
            throw .badField("number of legs")
        }
        let name = trim(try c.take(20, "passenger name"))
        let eticket = try c.take(1, "electronic ticket indicator")
        guard !name.isEmpty else { throw .badField("passenger name") }

        var pass = BCBP(formatCode: Character(format.uppercased()), passengerName: name,
                        electronicTicket: eticket == "E", legs: [])
        for index in 0..<count {
            var leg = try mandatoryLeg(&c)
            guard let size = Int(try c.take(2, "field size of variable size field"), radix: 16) else {
                throw .badField("field size of variable size field")
            }
            var block = Cursor(c.takeUpTo(size))
            if index == 0, block.peek == ">" {
                _ = block.takeUpTo(1)
                pass.version = Int(block.takeUpTo(1))
                if let unique = Int(block.takeUpTo(2), radix: 16) {
                    var u = Cursor(block.takeUpTo(unique))
                    _ = u.takeUpTo(1) // passenger description
                    _ = u.takeUpTo(1) // source of check-in
                    _ = u.takeUpTo(1) // source of boarding pass issuance
                    let issued = u.takeUpTo(4)
                    if issued.count == 4, let digit = Int(issued.prefix(1)), let doy = Int(issued.dropFirst()),
                       (1...366).contains(doy) {
                        pass.issueYearDigit = digit
                        pass.issueDayOfYear = doy
                    }
                    _ = u.takeUpTo(1) // document type
                    pass.issuingAirline = nonEmpty(u.takeUpTo(3))
                }
            }
            if let repeated = Int(block.takeUpTo(2), radix: 16) {
                var r = Cursor(block.takeUpTo(repeated))
                leg.airlineNumericCode = nonEmpty(r.takeUpTo(3))
                leg.documentNumber = nonEmpty(r.takeUpTo(10))
                _ = r.takeUpTo(1) // selectee indicator
                _ = r.takeUpTo(1) // international document verification
                leg.marketingCarrier = nonEmpty(r.takeUpTo(3))
                leg.frequentFlyerAirline = nonEmpty(r.takeUpTo(3))
                leg.frequentFlyerNumber = nonEmpty(r.takeUpTo(16))
                _ = r.takeUpTo(1) // ID/AD indicator
                leg.baggageAllowance = nonEmpty(r.takeUpTo(3))
                let fast = r.takeUpTo(1)
                leg.fastTrack = fast == "Y" ? true : fast == "N" ? false : nil
            }
            leg.airlineData = nonEmpty(block.rest)
            pass.legs.append(leg)
        }
        if c.peek == "^" {
            _ = c.takeUpTo(1)
            _ = c.takeUpTo(1) // type of security data
            if let length = Int(c.takeUpTo(2), radix: 16) { pass.securityData = nonEmpty(c.takeUpTo(length)) }
        }
        return pass
    }

    private static func mandatoryLeg(_ c: inout Cursor) throws(ParseError) -> Leg {
        let pnr = trim(try c.take(7, "PNR code"))
        let from = trim(try c.take(3, "from city airport code"))
        let to = trim(try c.take(3, "to city airport code"))
        let carrier = trim(try c.take(3, "operating carrier designator"))
        let number = try c.take(5, "flight number")
        let date = trim(try c.take(3, "date of flight"))
        let compartment = try c.take(1, "compartment code")
        let seat = try c.take(4, "seat number")
        let sequence = try c.take(5, "check-in sequence number")
        let status = try c.take(1, "passenger status")

        guard isAirport(from) else { throw .badField("from city airport code") }
        guard isAirport(to) else { throw .badField("to city airport code") }
        guard (2...3).contains(carrier.count), carrier.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else {
            throw .badField("operating carrier designator")
        }
        guard let flight = flightNumber(number) else { throw .badField("flight number") }
        guard let doy = Int(date), (1...366).contains(doy) else { throw .badField("date of flight") }
        let cabin = compartment.first.flatMap { $0 == " " ? nil : Character($0.uppercased()) }
        return Leg(pnr: pnr, from: from.uppercased(), to: to.uppercased(), carrier: carrier.uppercased(),
                   flightNumber: flight, dayOfYear: doy, compartment: cabin,
                   seat: dropLeadingZeros(trim(seat)), sequence: dropLeadingZeros(trim(sequence)),
                   passengerStatus: status.first.flatMap { $0 == " " ? nil : $0 })
    }

    // MARK: Pieces

    private struct Cursor {
        let chars: [Character]
        var index = 0
        init(_ chars: [Character]) { self.chars = chars }
        init(_ text: String) { chars = Array(text) }

        var peek: Character? { index < chars.count ? chars[index] : nil }
        var rest: String { index < chars.count ? String(chars[index...]) : "" }

        /// Exactly `n` characters of a mandatory field, or `tooShort`.
        mutating func take(_ n: Int, _ field: String) throws(ParseError) -> String {
            guard index + n <= chars.count else { throw .tooShort(field: field) }
            defer { index += n }
            return String(chars[index..<index + n])
        }

        /// Up to `n` characters: conditional items may stop early.
        mutating func takeUpTo(_ n: Int) -> String {
            let end = min(chars.count, index + max(n, 0))
            defer { index = end }
            return String(chars[index..<end])
        }
    }

    private static func trim(_ s: String) -> String { s.trimmingCharacters(in: .whitespaces) }

    private static func nonEmpty(_ s: String) -> String? {
        let t = trim(s)
        return t.isEmpty ? nil : t
    }

    private static func isAirport(_ s: String) -> Bool {
        s.count == 3 && s.allSatisfy { $0.isASCII && $0.isLetter }
    }

    /// "0084 " as "84", "1234A" as "1234A"; nil without digits.
    static func flightNumber(_ field: String) -> String? {
        let t = trim(field).uppercased()
        guard let m = t.wholeMatch(of: /([0-9]{1,4})([A-Z]?)/), let n = Int(m.1) else { return nil }
        return String(n) + String(m.2)
    }

    /// "023A" as "23A", "0012" as "12", "000" as "0"; a word such as "INF" stays as it is.
    private static func dropLeadingZeros(_ s: String) -> String? {
        guard !s.isEmpty else { return nil }
        guard let m = s.uppercased().wholeMatch(of: /0*([0-9]+[A-Z]?)/) else { return s.uppercased() }
        return String(m.1)
    }

    /// The day `leg` leaves: from the issue date when the pass carries one, else the year closest to `near`.
    public func day(of leg: Leg, near: Date, timeZone: TimeZone = .gmt) -> DateComponents? {
        let issue = issueYearDigit.flatMap { d in issueDayOfYear.map { (yearDigit: d, dayOfYear: $0) } }
        return Self.day(of: leg.dayOfYear, near: near, timeZone: timeZone, issue: issue)
    }

    /// The date of day `doy`. With the issue date (last digit of its year and its day), the first such day on
    /// or after the issue, in the issue year closest to `near`; without it, the year that brings the day
    /// closest to `near` (that year, the one before or the one after).
    static func day(of doy: Int, near: Date, timeZone: TimeZone, issue: (yearDigit: Int, dayOfYear: Int)?) -> DateComponents? {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let year = cal.component(.year, from: near)
        func date(_ y: Int, _ d: Int) -> Date? {
            guard let jan1 = cal.date(from: DateComponents(year: y, month: 1, day: 1)),
                  let date = cal.date(byAdding: .day, value: d - 1, to: jan1),
                  cal.component(.year, from: date) == y else { return nil }
            return date
        }
        let found: Date?
        if let issue {
            // The issue year ending in that digit nearest `near`: from five years back to four ahead.
            let issueYear = ((year - 5)...(year + 4)).first { (($0 % 10) + 10) % 10 == issue.yearDigit } ?? year
            let issued = date(issueYear, issue.dayOfYear)
            found = [issueYear, issueYear + 1].compactMap { date($0, doy) }
                .first { d in issued.map { d >= $0.addingTimeInterval(-86_400) } ?? true }
        } else {
            found = [year - 1, year, year + 1].compactMap { date($0, doy) }
                .min { abs($0.timeIntervalSince(near)) < abs($1.timeIntervalSince(near)) }
        }
        return found.map { cal.dateComponents([.year, .month, .day], from: $0) }
    }

    // MARK: Writing

    /// A BCBP string for one leg with the shared conditional items (issue date, issuer) and the leg's
    /// marketing carrier and baggage allowance: what the fakes and tests scan.
    public static func encode(passengerName: String, pnr: String, from: String, to: String, carrier: String,
                              flightNumber: String, dayOfYear: Int, compartment: Character, seat: String,
                              sequence: Int, issueYearDigit: Int? = nil, issueDayOfYear: Int? = nil,
                              baggageAllowance: String? = nil, airlineData: String = "") -> String {
        func pad(_ s: String, _ n: Int) -> String { String((s + String(repeating: " ", count: n)).prefix(n)) }
        func hex(_ n: Int) -> String { String(format: "%02X", n) }
        let number = flightNumber.prefix { $0.isNumber }
        let suffix = flightNumber.drop { $0.isNumber }
        let seatDigits = seat.prefix { $0.isNumber }
        let seatLetter = seat.drop { $0.isNumber }
        var out = "M1" + pad(passengerName.uppercased(), 20) + "E" + pad(pnr, 7) + from + to + pad(carrier, 3)
        out += String(format: "%04d", Int(number) ?? 0) + pad(String(suffix), 1)
        out += String(format: "%03d", dayOfYear) + String(compartment)
        out += String(format: "%03d", Int(seatDigits) ?? 0) + pad(String(seatLetter), 1)
        out += String(format: "%04d", sequence) + " " + "1"
        var unique = "0WW"
        if let d = issueYearDigit, let doy = issueDayOfYear { unique += "\(d)" + String(format: "%03d", doy) } else { unique += "    " }
        unique += "B" + pad(carrier, 3)
        let repeated = "   " + "          " + "0" + "0" + pad(carrier, 3) + "   " + pad("", 16) + " "
            + pad(baggageAllowance ?? "", 3) + "N"
        let variable = ">6" + hex(unique.count) + unique + hex(repeated.count) + repeated + airlineData
        return out + hex(variable.count) + variable
    }
}
