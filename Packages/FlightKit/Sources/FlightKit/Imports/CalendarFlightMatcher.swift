import Foundation
import FlightImportKit

/// A calendar event as the matcher reads it: plain values, so the rules are tested without EventKit.
public struct CalendarEventSnapshot: Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var location: String
    public var notes: String
    public var url: URL?
    public var start: Date
    public var end: Date
    public var isAllDay: Bool
    /// The event's own zone; nil for a floating event (read in the device's zone).
    public var timeZone: TimeZone?
    public var calendarId: String
    public var calendarTitle: String

    public init(id: String, title: String, location: String = "", notes: String = "", url: URL? = nil, start: Date,
                end: Date, isAllDay: Bool = false, timeZone: TimeZone? = nil, calendarId: String = "cal",
                calendarTitle: String = "Calendar") {
        self.id = id; self.title = title; self.location = location; self.notes = notes; self.url = url
        self.start = start; self.end = end; self.isAllDay = isAllDay; self.timeZone = timeZone
        self.calendarId = calendarId; self.calendarTitle = calendarTitle
    }
}

/// Finds the flights among calendar events: the ones airlines, booking sites and mail apps add ("Flight
/// to Paris (AF 84)"), and the ones people write themselves ("AF 84", "SFO → CDG", "Vol AF84 CDG-SFO").
/// An event counts when it names a flight number with a sign it is a flight (the word, a plane, an
/// airport pair or an airport as its place), or an airport pair with the word. The app's own synced
/// events are skipped. Pure.
public enum CalendarFlightMatcher {
    public enum Strength: Int, Sendable, Hashable, Comparable {
        /// A sign it is a flight but a part missing (no airports, or no number).
        case likely
        /// A flight number and both airports.
        case strong

        public static func < (a: Strength, b: Strength) -> Bool { a.rawValue < b.rawValue }
    }

    public struct Match: Sendable, Hashable, Identifiable {
        public var event: CalendarEventSnapshot
        public var flight: ImportedFlight
        public var strength: Strength
        public var id: String { event.id }
    }

    /// The flights in `events`, in start order.
    /// - Parameters:
    ///   - ownCalendarId: the calendar Settings > Calendar writes to, skipped whole.
    ///   - isAirport: whether three capitals name an airport.
    ///   - airport: an airport by code, for the zone the departure day is read in.
    public static func matches(_ events: [CalendarEventSnapshot], ownCalendarId: String? = nil,
                               isAirport: (String) -> Bool, airport: (String) -> Airport? = { _ in nil },
                               deviceZone: TimeZone = .current) -> [Match] {
        events.sorted { $0.start < $1.start }.compactMap { e in
            isOwn(e, ownCalendarId: ownCalendarId) ? nil
                : match(e, isAirport: isAirport, airport: airport, deviceZone: deviceZone)
        }
    }

    /// An event Soma Flight wrote (Settings > Calendar): its link, its notes' last line, or its calendar.
    public static func isOwn(_ e: CalendarEventSnapshot, ownCalendarId: String?) -> Bool {
        if let own = ownCalendarId, e.calendarId == own { return true }
        if e.url?.scheme?.lowercased() == "somaflight" { return true }
        return e.notes.contains("Kept up to date by Soma Flight.")
    }

    nonisolated(unsafe) static let flightWord =
        /(?i)(?:^|[^a-z])(flight|flights|vol|flug|vuelo|volo|voo|boarding|embarquement|départ|depart|departure)(?:[^a-z]|$)|✈|🛫|🛬/
    nonisolated(unsafe) static let routeArrow =
        /([A-Z]{3})\s*(?:→|->|=>|–|\u{2014}|-|>|›|»|✈︎?|\/|\s(?i:to|à|a|nach|para)\s)\s*([A-Z]{3})(?:[^A-Za-z0-9]|$)/

    static func match(_ e: CalendarEventSnapshot, isAirport: (String) -> Bool, airport: (String) -> Airport?,
                      deviceZone: TimeZone) -> Match? {
        let notes = String(e.notes.prefix(4000))
        let fields: [(name: String, text: String)] = [("title", e.title), ("place", e.location), ("notes", notes)]
        let hasWord = fields.contains { $0.text.firstMatch(of: flightWord) != nil }

        var evidence: [String] = []
        // The flight number: the title's first, else the place's, else the notes'.
        var number: (airline: String, number: String, field: String)?
        for f in fields {
            if let n = FlightNumberText.all(in: f.text).first {
                number = (n.airline, n.number, f.name)
                break
            }
        }
        // The airports: an arrowed pair first ("SFO → CDG"), else two bracketed codes, else the place's code.
        var route: (from: String, to: String, field: String)?
        for f in fields {
            if let pair = arrowedPair(f.text, isAirport: isAirport) ?? bracketedPair(f.text, isAirport: isAirport) {
                route = (pair.0, pair.1, f.name)
                break
            }
        }
        let placeCode = route == nil ? singleCode(e.location, isAirport: isAirport) : nil

        if let number {
            // A number in the notes alone is too weak without the word or a route ("Room B2 12").
            let sign = hasWord || route != nil || placeCode != nil
            guard sign, number.field != "notes" || hasWord || route != nil else { return nil }
        } else {
            guard hasWord, route != nil else { return nil }
        }

        let originZone = (route?.from ?? placeCode).flatMap(airport)?.timeZone
        let zone = e.isAllDay ? deviceZone : (originZone ?? e.timeZone ?? deviceZone)
        var flight = ImportedFlight(airline: number?.airline, number: number?.number, origin: route?.from ?? placeCode,
                                    destination: route?.to, day: LocalDay(e.start, in: zone))
        if !e.isAllDay {
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = zone
            let c = cal.dateComponents([.hour, .minute], from: e.start)
            flight.departureTime = LocalTime(hour: c.hour ?? 0, minute: c.minute ?? 0)
            flight.departure = e.start
            let arrivalZone = route.flatMap { airport($0.to)?.timeZone } ?? zone
            flight.arrivalDay = LocalDay(e.end, in: arrivalZone)
            var arrivalCal = Calendar(identifier: .gregorian)
            arrivalCal.timeZone = arrivalZone
            let a = arrivalCal.dateComponents([.hour, .minute], from: e.end)
            flight.arrivalTime = LocalTime(hour: a.hour ?? 0, minute: a.minute ?? 0)
        }
        if let ref = TextReader.bookingReference(in: notes) { flight.bookingReference = ref }
        if let seat = TextReader.seat(in: notes + "\n" + e.title) { flight.seat = seat }

        evidence.append("\u{201C}\(clip(e.title))\u{201D} in \(e.calendarTitle)")
        if let number { evidence.append("Flight number \(number.airline) \(number.number) in the \(number.field)") }
        if let route { evidence.append("Route \(route.from) \u{2192} \(route.to) in the \(route.field)") }
        else if let placeCode { evidence.append("Airport \(placeCode) as the place") }
        flight.evidence = evidence
        let strength: Strength = number != nil && route != nil ? .strong : .likely
        return Match(event: e, flight: flight, strength: strength)
    }

    static func clip(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.count > 60 ? String(t.prefix(59)) + "\u{2026}" : t
    }

    /// "SFO → CDG", "SFO-CDG", "SFO to CDG", "CDG/SFO".
    static func arrowedPair(_ text: String, isAirport: (String) -> Bool) -> (String, String)? {
        for m in text.matches(of: routeArrow) {
            let a = String(m.1), b = String(m.2)
            if a != b, isAirport(a), isAirport(b) { return (a, b) }
        }
        return nil
    }

    /// "San Francisco (SFO) to Paris (CDG)": the first two bracketed codes.
    static func bracketedPair(_ text: String, isAirport: (String) -> Bool) -> (String, String)? {
        let codes = text.matches(of: /\(([A-Z]{3})\)/).map { String($0.1) }.filter(isAirport)
        guard codes.count >= 2, codes[0] != codes[1] else { return nil }
        return (codes[0], codes[1])
    }

    /// "San Francisco SFO", "SFO Terminal 2", "(SFO)": the one code in a place.
    static func singleCode(_ text: String, isAirport: (String) -> Bool) -> String? {
        let codes = text.matches(of: /(?:^|[^A-Za-z0-9])([A-Z]{3})(?![A-Za-z0-9])/).map { String($0.1) }.filter(isAirport)
        return Set(codes).count == 1 ? codes[0] : nil
    }
}
