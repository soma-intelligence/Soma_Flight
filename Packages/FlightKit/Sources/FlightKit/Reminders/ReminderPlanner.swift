import Foundation

/// One of the device's own reminders. The server never sends these: they need no provider data beyond
/// the followed flight, and they must fire offline.
public enum ReminderKind: String, Sendable, CaseIterable {
    /// 24 hours before the scheduled departure.
    case checkIn = "check-in"
    /// 7:00 at the departure airport on the travel day, a summary of the flight.
    case morning
    /// When to leave for the airport: computed from the drive, the security queue, the bag drop and
    /// boarding when the device measured them (`LeaveTimePlanner`), else 3 hours before an international
    /// departure and 2 before a domestic one.
    case leave
    /// Before an international flight when the passport (Settings > Travel Documents) is expired by the
    /// departure day or expires within six months of it: 30 days ahead, else 7, else the next 9:00 at the
    /// departure airport when the flight is more than a day away.
    case passport
    /// A landmark passing the plane in flight (`LandmarkAlerts`), when the user turned them on. Several a
    /// flight, each with its own identifier.
    case landmark
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
    /// How far ahead the passport reminder fires, the first still in the future.
    public static let passportLeads: [TimeInterval] = [30 * 86400, 7 * 86400]
    /// The local hour of the passport reminder when both leads have passed.
    public static let passportHour = 9

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
    /// `leave` is the flight's computed leave time (`LeaveTimePlanner`); nil or a fixed one keeps the
    /// fixed rule and its words. `passportExpires` is the passport's expiry day ("yyyy-MM-dd") from the
    /// travel documents; nil plans no passport reminder.
    public static func plan(for flight: Flight, origin: Airport?, destination: Airport?, now: Date,
                            clock: TimeStyle = .h24, leave: LeaveTime? = nil,
                            passportExpires: String? = nil) -> [PlannedReminder] {
        guard flight.actualOut == nil, flight.status == .scheduled || flight.status == .unknown,
              let scheduled = flight.scheduledOut else { return [] }
        let departure = flight.estimatedOut ?? scheduled
        let tz = origin?.timeZone ?? .gmt
        let international = isInternational(origin: origin, destination: destination)
        let computed = leave?.breakdown
        let leaveAt = (computed != nil ? leave?.leaveAt : nil)
            ?? departure.addingTimeInterval(-(international ? internationalLead : domesticLead))

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
        if let computed {
            add(.leave, leaveAt, ReminderCopy.leave(flight, breakdown: computed, tz: tz, clock: clock))
        } else {
            add(.leave, leaveAt, ReminderCopy.leave(flight, departure: departure, tz: tz, clock: clock,
                                                    international: international))
        }
        if international, origin != nil, destination != nil,
           let notice = TravelDocumentRules.passportNotice(expires: passportExpires, departure: scheduled,
                                                           international: true),
           let at = passportFireDate(departure: scheduled, tz: tz, now: now) {
            add(.passport, at, ReminderCopy.passport(flight, notice: notice))
        }
        return out.sorted { $0.fireDate < $1.fireDate }
    }

    /// When the passport reminder fires: 30 days before the departure, else 7, else 9:00 at the departure
    /// airport the next morning (today's when still ahead) if that is at least a day before the departure.
    static func passportFireDate(departure: Date, tz: TimeZone, now: Date) -> Date? {
        if let lead = passportLeads.first(where: { departure.addingTimeInterval(-$0) > now }) {
            return departure.addingTimeInterval(-lead)
        }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        guard var nine = cal.date(bySettingHour: passportHour, minute: 0, second: 0, of: now) else { return nil }
        if nine <= now { nine = cal.date(byAdding: .day, value: 1, to: nine) ?? nine }
        return nine.addingTimeInterval(86400) <= departure ? nine : nil
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
