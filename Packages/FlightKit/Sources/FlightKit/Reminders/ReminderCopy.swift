import Foundation

/// The words of the device's own reminders, in one place. Short English like the server's alerts
/// (`supabase/functions/_shared/alert_copy.ts`): the title says what is on, the body gives the time and
/// place. Times are local to their airport, in the user's clock style.
public enum ReminderCopy {
    public struct Text: Sendable, Equatable {
        public var title: String
        public var body: String
    }

    /// "Mont Blanc on the left": a landmark passing the plane in about five minutes (`LandmarkAlerts.lead`).
    public static func landmark(_ p: LandmarkPass) -> Text {
        let side: String
        switch p.side {
        case .left: side = "on the left"
        case .right: side = "on the right"
        case .below: side = "below"
        }
        let place = p.side == .below ? "right below the plane" : "out the \(p.side.rawValue) windows"
        return Text(title: "\(p.landmark.name) \(side)",
                    body: "In about 5 minutes, \(p.landmark.name) should be \(place). Estimated from the schedule.")
    }

    /// "Check-in is open for AF 84".
    public static func checkIn(_ f: Flight, departure: Date, tz: TimeZone, clock: TimeStyle) -> Text {
        let id = Format.ident(f.ident)
        let at = Format.clock(departure, tz, clock)
        return Text(title: "Check-in is open for \(id)",
                    body: "\(id) to \(f.destinationCode) leaves \(f.originCode) tomorrow at \(at). Check in now to get your boarding pass.")
    }

    /// "AF 84 to SFO today": the day's summary, with the delay, terminal and gate when known.
    /// `arrivalTz` is the arrival airport's zone (the departure's when unknown).
    public static func morning(_ f: Flight, departure: Date, tz: TimeZone, arrivalTz: TimeZone?,
                               clock: TimeStyle) -> Text {
        let id = Format.ident(f.ident)
        let at = Format.clock(departure, tz, clock)
        var place = ""
        switch (f.terminalOrigin, f.gateOrigin) {
        case let (t?, g?): place = ", terminal \(t), gate \(g)"
        case let (t?, nil): place = ", terminal \(t)"
        case let (nil, g?): place = ", gate \(g)"
        default: break
        }
        var body = "Departs \(f.originCode) at \(at)\(place)."
        if let late = lateMinutes(f), late > 5 { body = "Running \(Format.minutes(late)) late. " + body }
        if let arrival = f.estimatedIn ?? f.scheduledIn {
            body += " Arrives \(f.destinationCode) at \(Format.clock(arrival, arrivalTz ?? tz, clock))."
        }
        return Text(title: "\(id) to \(f.destinationCode) today", body: body)
    }

    /// "Time to leave for CDG".
    public static func leave(_ f: Flight, departure: Date, tz: TimeZone, clock: TimeStyle, international: Bool) -> Text {
        let id = Format.ident(f.ident)
        let at = Format.clock(departure, tz, clock)
        let lead = international ? "3 hours" : "2 hours"
        let kind = international ? "an international" : "a domestic"
        return Text(title: "Time to leave for \(f.originCode)",
                    body: "\(id) departs at \(at). Aim to be at the airport \(lead) early for \(kind) flight.")
    }

    /// "Time to leave for CDG" for a computed leave time: when boarding starts and what the time allows for.
    public static func leave(_ f: Flight, breakdown b: LeaveTime.Breakdown, tz: TimeZone, clock: TimeStyle) -> Text {
        let id = Format.ident(f.ident)
        let at = Format.clock(b.boardingAt, tz, clock)
        let queue = SecurityWaitFacts.amount(b.securityMinutes, live: b.securityIsLive, capital: false)
        return Text(title: "Time to leave for \(f.originCode)",
                    body: "\(id) boards at \(at). This allows \(Format.minutes(Int(b.drive / 60))) to drive, "
                        + "\(queue) at security and \(Format.minutes(Int(b.bagDrop / 60))) to drop bags.")
    }

    /// "Check your passport for AF 84": the passport is expired by the flight, or expires within six months.
    public static func passport(_ f: Flight, notice: TravelDocumentRules.PassportNotice) -> Text {
        let id = Format.ident(f.ident)
        let text = TravelDocumentRules.passportText(notice)
        return Text(title: "\(text.title) for \(id)", body: text.text)
    }

    /// Whole minutes the departure estimate is past the schedule, nil without both.
    private static func lateMinutes(_ f: Flight) -> Int? {
        guard let est = f.estimatedOut, let sched = f.scheduledOut else { return nil }
        return Int(est.timeIntervalSince(sched) / 60)
    }
}
