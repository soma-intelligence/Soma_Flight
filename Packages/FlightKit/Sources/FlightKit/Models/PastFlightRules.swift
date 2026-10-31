import Foundation

/// The shape of a past flight the traveller writes (by hand or by import). The same rules as the
/// `past_flights_client_shape_check` constraint of migration 20261030000013, so the app never sends a
/// row the server refuses: one refused row would fail a whole import batch.
public enum PastFlightRules {
    /// What can be wrong with a flight about to be written, one per field.
    public enum Problem: Sendable, Hashable {
        case date, origin, destination, sameAirports, ident, airline, aircraftType, registration, seat, notes

        /// The line shown under the field.
        public var message: String {
            switch self {
            case .date: "Pick a day that has already come."
            case .origin: "Pick the airport you left from."
            case .destination: "Pick the airport you flew to."
            case .sameAirports: "The flight has to land somewhere else."
            case .ident: "A flight number reads like UA990 or AF84."
            case .airline: "That airline name is too long."
            case .aircraftType: "An aircraft type is its ICAO code, like B738 or A20N."
            case .registration: "A registration reads like N47280 or F-GZNB."
            case .seat: DetailFacts.seatError
            case .notes: "Notes hold up to 2,000 characters."
            }
        }
    }

    /// The first scheduled airline flights flew in 1919; nothing before is a flight to log.
    public static let earliest = Date(timeIntervalSince1970: -1_609_459_200) // 1919-01-01T00:00:00Z

    /// How far ahead of now a date may be. A day picked by the traveller is stored at noon local time at
    /// the origin (`noon`), which is always less than 12 hours ahead when the day is the traveller's today
    /// there, and more than 12 hours ahead from the next day on. The server allows a day.
    public static let futureSlack: TimeInterval = 12 * 3600

    public static let maxAirline = 80

    /// A trimmed, upper-cased airport code of three or four letters and digits (IATA or ICAO), nil otherwise.
    public static func airportCode(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return t.wholeMatch(of: /[A-Z0-9]{3,4}/) != nil ? t : nil
    }

    /// A flight number without spaces, upper cased ("ua 990" gives "UA990"): two or three characters of
    /// airline code, one to five digits, an optional suffix letter. `.some(nil)` for empty input, nil
    /// when invalid.
    public static func ident(_ s: String) -> String?? {
        let t = s.filter { !$0.isWhitespace }.uppercased()
        if t.isEmpty { return .some(nil) }
        return t.wholeMatch(of: /[A-Z0-9]{2,3}[0-9]{1,5}[A-Z]?/) != nil ? .some(t) : nil
    }

    /// An ICAO aircraft type designator ("B738"), upper cased. `.some(nil)` for empty input, nil when invalid.
    public static func aircraftType(_ s: String) -> String?? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if t.isEmpty { return .some(nil) }
        return t.wholeMatch(of: /[A-Z0-9]{2,4}/) != nil ? .some(t) : nil
    }

    /// A registration ("F-GZNB"), upper cased. `.some(nil)` for empty input, nil when invalid.
    public static func registration(_ s: String) -> String?? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if t.isEmpty { return .some(nil) }
        return t.wholeMatch(of: /[A-Z0-9-]{2,10}/) != nil ? .some(t) : nil
    }

    /// An airline as typed (a code or a name), trimmed. `.some(nil)` for empty input, nil when longer than
    /// 80 characters (Unicode scalars, as Postgres counts them).
    public static func airline(_ s: String) -> String?? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return .some(nil) }
        return t.unicodeScalars.count <= maxAirline ? .some(t) : nil
    }

    /// True when `date` is neither before 1919 nor in the future (see `futureSlack`).
    public static func allows(date: Date, now: Date) -> Bool {
        date >= earliest && date <= now.addingTimeInterval(futureSlack)
    }

    /// Noon on the given day in `timeZone`: how a day without a time is stored, so it reads as that day in
    /// the origin's zone (where the Passport buckets it) whatever zone the phone is in. Nil for a day that
    /// does not exist (February 30).
    public static func noon(year: Int, month: Int, day: Int, in timeZone: TimeZone) -> Date? {
        at(year: year, month: month, day: day, hour: 12, minute: 0, in: timeZone)
    }

    /// The local time on the given day in `timeZone`; nil when the day or the time does not exist.
    public static func at(year: Int, month: Int, day: Int, hour: Int, minute: Int, in timeZone: TimeZone) -> Date? {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let parts = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)
        guard (0..<24).contains(hour), (0..<60).contains(minute), let date = cal.date(from: parts) else { return nil }
        let back = cal.dateComponents([.year, .month, .day], from: date)
        return back.year == year && back.month == month && back.day == day ? date : nil
    }

    /// `YYYY-MM-DD` of `date` in `timeZone`.
    public static func dayKey(_ date: Date, in timeZone: TimeZone) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// Every rule `flight` breaks, in field order; empty when it can be written.
    public static func problems(_ f: PastFlight, now: Date) -> [Problem] {
        var out: [Problem] = []
        if !allows(date: f.date, now: now) { out.append(.date) }
        let origin = airportCode(f.originIcao), destination = airportCode(f.destinationIcao)
        if origin == nil { out.append(.origin) }
        if destination == nil { out.append(.destination) }
        if let origin, origin == destination { out.append(.sameAirports) }
        if !f.ident.isEmpty, ident(f.ident) != .some(f.ident) { out.append(.ident) }
        if let a = f.airline, airline(a) != .some(a) { out.append(.airline) }
        if let t = f.aircraftType, aircraftType(t) != .some(t) { out.append(.aircraftType) }
        if let r = f.registration, registration(r) != .some(r) { out.append(.registration) }
        if let s = f.seat, FollowDetails.normalizedSeat(s) != .some(s) { out.append(.seat) }
        if let n = f.notes, n.unicodeScalars.count > FollowDetails.maxNotes { out.append(.notes) }
        return out
    }

    /// The key two flights share when they are the same trip: the departure day at the origin and the
    /// route, codes as ICAO when `airport` knows them.
    public static func tripKey(_ f: PastFlight, airport: (String) -> Airport?) -> String {
        let o = airport(f.originIcao), d = airport(f.destinationIcao)
        let zone = f.originTz.flatMap(TimeZone.init(identifier:)) ?? o?.timeZone ?? .gmt
        let from = o?.id ?? f.originIcao.uppercased(), to = d?.id ?? f.destinationIcao.uppercased()
        return "\(dayKey(f.date, in: zone)) \(from) \(to)"
    }
}
