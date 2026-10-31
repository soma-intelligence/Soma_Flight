import Foundation

/// One followed flight as a calendar event: what Soma Flight writes, and what it reads back to tell
/// whether the event needs rewriting. Plain values, so the rules are tested without EventKit.
public struct CalendarEventDraft: Sendable, Equatable {
    /// "AF 84 Paris to San Francisco", "Canceled: AF 84 Paris to San Francisco".
    public var title: String
    /// The departure airport: "Paris Charles de Gaulle (CDG)".
    public var location: String
    /// The departure airport's position, for the event's map; nil when the airport is unknown.
    public var latitude: Double?
    public var longitude: Double?
    public var notes: String
    /// `somaflight://flight/<id>`: opens the flight in the app.
    public var url: URL
    /// Gate departure and gate arrival, the best known of each.
    public var start: Date
    public var end: Date
    /// The departure airport's zone: the event shows its start on that clock.
    public var timeZone: TimeZone

    public init(title: String, location: String, latitude: Double? = nil, longitude: Double? = nil, notes: String,
                url: URL, start: Date, end: Date, timeZone: TimeZone) {
        self.title = title; self.location = location; self.latitude = latitude; self.longitude = longitude
        self.notes = notes; self.url = url; self.start = start; self.end = end; self.timeZone = timeZone
    }
}

/// Builds a flight's event: departure to arrival on the best known times, the departure airport as the
/// place, and the terminal, gate, seat and booking code in the notes when known. Pure.
public enum CalendarEventBuilder {
    /// How long an event lasts when the flight has no arrival time.
    static let fallbackLength: TimeInterval = 3600

    /// The event for `flight`, nil without any departure time (nothing to place on a day).
    /// - Parameters:
    ///   - origin, destination: the planned airports, for the cities, the place and the two clocks.
    ///   - details: what the traveller noted (seat, booking code); nil when unknown.
    public static func draft(for flight: Flight, origin: Airport?, destination: Airport?, details: FollowDetails?,
                             clock: TimeStyle = .h24) -> CalendarEventDraft? {
        guard let start = flight.actualOut ?? flight.estimatedOut ?? flight.scheduledOut else { return nil }
        var end = flight.actualIn ?? flight.estimatedIn ?? flight.scheduledIn ?? flight.actualOn ?? flight.estimatedOn
            ?? flight.scheduledOn ?? start.addingTimeInterval(fallbackLength)
        if end <= start { end = start.addingTimeInterval(fallbackLength) }
        let originTz = origin?.timeZone ?? .gmt
        return CalendarEventDraft(title: title(flight, origin: origin, destination: destination),
                                  location: location(flight, origin: origin),
                                  latitude: origin?.lat, longitude: origin?.lon,
                                  notes: notes(flight, origin: origin, destination: destination, details: details,
                                               start: start, end: end, clock: clock),
                                  url: FlightLink.url(for: flight.id), start: start, end: end, timeZone: originTz)
    }

    /// "AF 84 Paris to San Francisco", led by "Canceled: " or "Diverted: " when the flight is.
    static func title(_ f: Flight, origin: Airport?, destination: Airport?) -> String {
        let from = city(origin) ?? f.originCode, to = city(destination) ?? f.destinationCode
        let base = "\(Format.ident(f.ident)) \(from) to \(to)"
        switch f.status {
        case .canceled: return "Canceled: \(base)"
        case .diverted: return "Diverted: \(base)"
        default: return base
        }
    }

    /// "Paris Charles de Gaulle (CDG)", or the code alone for an airport the app does not know.
    static func location(_ f: Flight, origin: Airport?) -> String {
        guard let origin, !origin.name.isEmpty else { return f.originCode }
        return "\(origin.name) (\(f.originCode))"
    }

    /// One line per fact, the ones not known left out:
    ///
    ///     Departs CDG at 10:15 Paris time, terminal 2E, gate K41.
    ///     Arrives SFO at 12:40 San Francisco time, terminal I.
    ///     Seat 32A. Booking code ABC123.
    ///     Kept up to date by Soma Flight.
    static func notes(_ f: Flight, origin: Airport?, destination: Airport?, details: FollowDetails?,
                      start: Date, end: Date, clock: TimeStyle) -> String {
        var lines: [String] = []
        if f.status == .canceled { lines.append("This flight is canceled.") }
        if f.status == .diverted { lines.append("This flight was diverted.") }
        lines.append(side("Departs", f.originCode, start, origin, terminal: f.terminalOrigin, gate: f.gateOrigin,
                          clock: clock))
        lines.append(side("Arrives", f.destinationCode, end, destination, terminal: f.terminalDestination,
                          gate: f.gateDestination, clock: clock))
        var booking: [String] = []
        if let seat = details?.seat, !seat.isEmpty { booking.append("Seat \(seat).") }
        if let code = details?.bookingCode, !code.isEmpty { booking.append("Booking code \(code).") }
        if !booking.isEmpty { lines.append(booking.joined(separator: " ")) }
        lines.append("Kept up to date by Soma Flight.")
        return lines.joined(separator: "\n")
    }

    private static func side(_ verb: String, _ code: String, _ at: Date, _ airport: Airport?, terminal: String?,
                             gate: String?, clock: TimeStyle) -> String {
        var s = "\(verb) \(code) at \(Format.clock(at, airport?.timeZone ?? .gmt, clock))"
        s += airport.flatMap { city($0) }.map { " \($0) time" } ?? " UTC"
        if let t = terminal, !t.isEmpty { s += ", terminal \(t)" }
        if let g = gate, !g.isEmpty { s += ", gate \(g)" }
        return s + "."
    }

    private static func city(_ a: Airport?) -> String? {
        guard let c = a?.city.trimmingCharacters(in: .whitespaces), !c.isEmpty else { return nil }
        return c
    }
}
