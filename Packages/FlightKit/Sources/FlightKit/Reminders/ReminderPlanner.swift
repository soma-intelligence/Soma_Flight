import Foundation

/// One of the device's own reminders. The server never sends these: they need no provider data beyond
/// the followed flight, and they must fire offline.
public enum ReminderKind: String, Sendable, CaseIterable {
    /// 24 hours before the scheduled departure.
    case checkIn = "check-in"
    /// 7:00 at the departure airport on the travel day, a summary of the flight.
    case morning
    /// 3 hours before an international departure, 2 before a domestic one.
    case leave
}

/// A reminder to schedule: where it fires and what it says.
public struct PlannedReminder: Sendable, Equatable {
    /// `reminder.<flight id>.<kind>`, the notification request's identifier.
    public var id: String
    public var flightId: Flight.ID
    public var kind: ReminderKind
    public var fireDate: Date
    public var title: String
    public var body: String
}

/// Which reminders a followed flight gets, from its times and its two airports. Pure, so the rules are
/// tested without a notification center.
public enum ReminderPlanner {
    public static let identifierPrefix = "reminder."
    public static let checkInLead: TimeInterval = 24 * 3600
    public static let internationalLead: TimeInterval = 3 * 3600
    public static let domesticLead: TimeInterval = 2 * 3600
    /// The morning summary's local hour at the departure airport.
    public static let morningHour = 7

    public static func identifier(_ flight: Flight.ID, _ kind: ReminderKind) -> String {
        "\(identifierPrefix)\(flight.uuidString.lowercased()).\(kind.rawValue)"
    }

    /// International when the two airports are in different countries. Unknown airports count as
    /// international, so the reminder errs on the early side.
    public static func isInternational(origin: Airport?, destination: Airport?) -> Bool {
        guard let o = origin?.country, let d = destination?.country, !o.isEmpty, !d.isEmpty else { return true }
        return o != d
    }

    /// The reminders still ahead for `flight` at `now`, soonest first. None once the flight has left
    /// the gate, is canceled or diverted, or has no scheduled departure. Check-in follows the schedule
    /// (airlines open it from there); the morning summary and leaving follow the latest estimate. The
    /// morning summary is skipped when 7:00 is not before the time to leave (an early flight).
    public static func plan(for flight: Flight, origin: Airport?, destination: Airport?, now: Date,
                            clock: TimeStyle = .h24) -> [PlannedReminder] {
        guard flight.actualOut == nil, flight.status == .scheduled || flight.status == .unknown,
              let scheduled = flight.scheduledOut else { return [] }
        let departure = flight.estimatedOut ?? scheduled
        let tz = origin?.timeZone ?? .gmt
        let international = isInternational(origin: origin, destination: destination)
        let leaveAt = departure.addingTimeInterval(-(international ? internationalLead : domesticLead))

        var out: [PlannedReminder] = []
        func add(_ kind: ReminderKind, _ at: Date, _ text: ReminderCopy.Text) {
            guard at > now else { return }
            out.append(PlannedReminder(id: identifier(flight.id, kind), flightId: flight.id, kind: kind,
                                       fireDate: at, title: text.title, body: text.body))
        }
        add(.checkIn, scheduled.addingTimeInterval(-checkInLead),
            ReminderCopy.checkIn(flight, departure: scheduled, tz: tz, clock: clock))
        if origin != nil, let morning = morningOf(departure, in: tz), morning < leaveAt {
            add(.morning, morning, ReminderCopy.morning(flight, departure: departure, tz: tz,
                                                         arrivalTz: destination?.timeZone, clock: clock))
        }
        add(.leave, leaveAt, ReminderCopy.leave(flight, departure: departure, tz: tz, clock: clock,
                                                international: international))
        return out.sorted { $0.fireDate < $1.fireDate }
    }

    /// 7:00 on the local day of `date` in `tz`.
    static func morningOf(_ date: Date, in tz: TimeZone) -> Date? {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        var c = cal.dateComponents([.year, .month, .day], from: date)
        c.hour = morningHour
        c.minute = 0
        return cal.date(from: c)
    }
}
