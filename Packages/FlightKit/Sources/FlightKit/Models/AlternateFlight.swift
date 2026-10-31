import Foundation

/// A direct flight on the same route later the same day, offered when a followed flight is canceled or
/// its connection is at risk. It comes from the airline schedules (`alternate-flights`), so it is not a
/// `flights` row yet: following it looks it up by flight number first.
public struct AlternateFlight: Sendable, Hashable, Identifiable {
    /// The provider's flight id when it has one, else the flight number and departure.
    public var id: String
    public var ident: String
    /// ICAO code of the operating airline, when known.
    public var `operator`: String?
    public var originIata: String
    public var destinationIata: String
    public var scheduledOut: Date
    public var scheduledIn: Date
    public var estimatedOut: Date?
    public var estimatedIn: Date?
    /// `scheduled` unless the flight is already tracked by the backend, which then knows better.
    public var status: FlightStatus
    public var aircraftType: String?

    public init(id: String, ident: String, operator: String? = nil, originIata: String, destinationIata: String,
                scheduledOut: Date, scheduledIn: Date, estimatedOut: Date? = nil, estimatedIn: Date? = nil,
                status: FlightStatus = .scheduled, aircraftType: String? = nil) {
        self.id = id; self.ident = ident; self.operator = `operator`
        self.originIata = originIata; self.destinationIata = destinationIata
        self.scheduledOut = scheduledOut; self.scheduledIn = scheduledIn
        self.estimatedOut = estimatedOut; self.estimatedIn = estimatedIn
        self.status = status; self.aircraftType = aircraftType
    }

    /// Best known departure and arrival.
    public var bestOut: Date { estimatedOut ?? scheduledOut }
    public var bestIn: Date { estimatedIn ?? scheduledIn }
}

/// What to ask `alternate-flights` for, and for which window. Equatable, so the card asks again only when
/// the request really moves (`after` is held to the half hour).
public struct AlternateRequest: Sendable, Hashable {
    /// ICAO codes.
    public var origin: String
    public var destination: String
    /// Display code of the destination ("SFO").
    public var destinationCode: String
    /// Nothing leaving before this.
    public var after: Date
    /// Nothing leaving after this: the end of the local day at the origin, or 12 hours on when the day is
    /// nearly over.
    public var until: Date
    /// True when `until` is the end of the local day.
    public var endsToday: Bool
    /// The flight the card stands in for, left out of the list.
    public var excluding: String

    /// Less than this left in the day stretches the window to `lateWindow`.
    static let shortDay: TimeInterval = 4 * 3600
    static let lateWindow: TimeInterval = 12 * 3600
    static let step: TimeInterval = 30 * 60

    /// The window from `after` (held to the half hour, earlier) to the end of that local day at the origin.
    public init(origin: String, destination: String, destinationCode: String, after: Date, timeZone: TimeZone,
                excluding: String) {
        self.origin = origin; self.destination = destination; self.destinationCode = destinationCode
        self.excluding = excluding
        let held = Date(timeIntervalSince1970: (after.timeIntervalSince1970 / Self.step).rounded(.down) * Self.step)
        self.after = held
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: held)) ?? held
        if endOfDay.timeIntervalSince(held) < Self.shortDay {
            until = held.addingTimeInterval(Self.lateWindow)
            endsToday = false
        } else {
            until = endOfDay
            endsToday = true
        }
    }

    /// Why the card shows, and from when. A connection at risk or missed offers the onward route, from the
    /// moment the first flight's passengers could make a connection (its landing plus the MCT); a canceled
    /// flight offers its own route from now. A connection whose first flight is canceled or diverted offers
    /// nothing: its passengers are not reaching the connection airport. nil when nothing applies.
    /// - Parameters:
    ///   - flight: the flight on screen.
    ///   - connections: its connections with their assessments.
    ///   - timeZone: the zone of an airport by ICAO code.
    public static func make(flight: Flight, connections: [(Connection, ConnectionAssessment)], now: Date,
                            timeZone: (String) -> TimeZone) -> AlternateRequest? {
        for (c, a) in connections where a.verdict >= .atRisk
            && a.broken != .arrivingCanceled && a.broken != .arrivingDiverted {
            let b = c.departing
            let ready = a.arrival.map { $0.addingTimeInterval(TimeInterval(a.mctMinutes * 60)) } ?? now
            return AlternateRequest(origin: b.originIcao, destination: b.destinationIcao,
                                    destinationCode: b.destinationCode, after: max(now, ready),
                                    timeZone: timeZone(b.originIcao), excluding: b.ident)
        }
        if flight.status == .canceled {
            return AlternateRequest(origin: flight.originIcao, destination: flight.destinationIcao,
                                    destinationCode: flight.destinationCode, after: now,
                                    timeZone: timeZone(flight.originIcao), excluding: flight.ident)
        }
        return nil
    }

    /// The flights of `all` this card lists: in the window, not the one it stands in for, by departure.
    public func filter(_ all: [AlternateFlight]) -> [AlternateFlight] {
        let skip = excluding.uppercased()
        return all
            .filter { $0.scheduledOut >= after && $0.scheduledOut <= until && $0.ident.uppercased() != skip }
            .filter { $0.status != .canceled }
            .sorted { $0.bestOut != $1.bestOut ? $0.bestOut < $1.bestOut : $0.ident < $1.ident }
    }
}
