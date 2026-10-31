import Foundation

/// When to leave for the airport, and how that time was reached: from the trip itself (a drive, the
/// security queue, the bag drop, the boarding call) when every part is known, else the fixed rule of
/// 3 hours before an international flight and 2 before a domestic one.
public struct LeaveTime: Sendable, Equatable {
    /// The parts of a computed time, in the order the traveller meets them backwards from the gate.
    public struct Breakdown: Sendable, Equatable {
        /// When boarding starts: the scheduled departure less `boardingLead`.
        public var boardingAt: Date
        /// 40 minutes for a wide-body, 30 for a narrow-body.
        public var boardingLead: TimeInterval
        public var wideBody: Bool
        /// The bag drop margin: 45 minutes international, 30 domestic.
        public var bagDrop: TimeInterval
        /// The security queue, in minutes, in the lane the traveller uses.
        public var securityMinutes: Int
        /// True when the PreCheck lane's figure is used.
        public var precheck: Bool
        /// True when a live source measured the queue; otherwise it is an estimate.
        public var securityIsLive: Bool
        /// The driving time from where the traveller was when it was measured.
        public var drive: TimeInterval
        /// When the drive and the queue were measured.
        public var measuredAt: Date
    }

    public var leaveAt: Date
    /// The departure the time aims at: the schedule for a computed time, the latest estimate for the fixed rule.
    public var departure: Date
    public var international: Bool
    /// The parts of a computed time; nil when the fixed rule gave it.
    public var breakdown: Breakdown?

    public var isComputed: Bool { breakdown != nil }

    public init(leaveAt: Date, departure: Date, international: Bool, breakdown: Breakdown? = nil) {
        self.leaveAt = leaveAt; self.departure = departure; self.international = international
        self.breakdown = breakdown
    }
}

/// What the device measured for one flight, in the foreground only: the drive to the departure airport
/// and the security queue there, both lanes. Kept so the leave reminder can use it later without asking
/// for the location again.
public struct LeaveTimeMeasure: Codable, Sendable, Equatable {
    public var drive: TimeInterval
    /// The shortest standard queue for the flight's terminal; nil when the airport gives none.
    public var standardMinutes: Int?
    /// The shortest PreCheck queue; nil when no checkpoint has PreCheck lanes.
    public var precheckMinutes: Int?
    public var securityIsLive: Bool
    public var measuredAt: Date

    public init(drive: TimeInterval, standardMinutes: Int?, precheckMinutes: Int?, securityIsLive: Bool,
                measuredAt: Date) {
        self.drive = drive; self.standardMinutes = standardMinutes; self.precheckMinutes = precheckMinutes
        self.securityIsLive = securityIsLive; self.measuredAt = measuredAt
    }

    /// The two figures from a security answer, for the flight's terminal (`SecurityWaitFacts.shortest`).
    public init(drive: TimeInterval, wait: SecurityWait, terminal: String?, measuredAt: Date) {
        let pick = SecurityWaitFacts.shortest(wait, terminal: terminal)
        self.init(drive: drive, standardMinutes: pick.standard?.standardMinutes,
                  precheckMinutes: pick.precheck?.precheckMinutes, securityIsLive: wait.isLive, measuredAt: measuredAt)
    }
}

/// The leave time of a flight, from its schedule, its airports, its aircraft and what was measured. Pure,
/// so the rules are tested without MapKit or a location.
public enum LeaveTimePlanner {
    public static let boardingLeadWideBody: TimeInterval = 40 * 60
    public static let boardingLeadNarrowBody: TimeInterval = 30 * 60
    /// Whether bags go in the hold is not known (a boarding pass does not say), so the margin always counts.
    public static let bagDropInternational: TimeInterval = 45 * 60
    public static let bagDropDomestic: TimeInterval = 30 * 60

    /// The leave time of `flight`, nil once it has left the gate, is canceled or diverted, or has no
    /// scheduled departure (the same flights `ReminderPlanner` leaves alone).
    ///
    /// Computed when the origin, the aircraft type and a measure with a queue in the chosen lane are all
    /// known: the traveller aims to stand at the gate when boarding starts, so the time is the scheduled
    /// departure less the boarding lead, the bag drop, the queue and the drive. The schedule, not an
    /// estimate, because a delay can be cut back and the gate closes on the airline's clock. With PreCheck on
    /// and no PreCheck figure, the standard queue counts. Anything missing gives the fixed rule from the
    /// latest estimate, as the leave reminder always did.
    public static func plan(for flight: Flight, origin: Airport?, destination: Airport?, aircraft: AircraftType?,
                            measure: LeaveTimeMeasure?, precheck: Bool) -> LeaveTime? {
        guard flight.actualOut == nil, flight.status == .scheduled || flight.status == .unknown,
              let scheduled = flight.scheduledOut else { return nil }
        let international = ReminderPlanner.isInternational(origin: origin, destination: destination)
        if origin != nil, let aircraft, let measure, let queue = queue(measure, precheck: precheck) {
            let wide = aircraft.family.isWidebody
            let lead = wide ? boardingLeadWideBody : boardingLeadNarrowBody
            let bags = international ? bagDropInternational : bagDropDomestic
            let boarding = scheduled.addingTimeInterval(-lead)
            let leave = boarding.addingTimeInterval(-(bags + TimeInterval(queue.minutes * 60) + measure.drive))
            return LeaveTime(leaveAt: leave, departure: scheduled, international: international,
                             breakdown: .init(boardingAt: boarding, boardingLead: lead, wideBody: wide, bagDrop: bags,
                                              securityMinutes: queue.minutes, precheck: queue.precheck,
                                              securityIsLive: measure.securityIsLive, drive: measure.drive,
                                              measuredAt: measure.measuredAt))
        }
        return fixed(flight, scheduled: scheduled, international: international)
    }

    /// The fixed rule: 3 hours before an international departure, 2 before a domestic one, from the latest estimate.
    static func fixed(_ flight: Flight, scheduled: Date, international: Bool) -> LeaveTime {
        let departure = flight.estimatedOut ?? scheduled
        let lead = international ? ReminderPlanner.internationalLead : ReminderPlanner.domesticLead
        return LeaveTime(leaveAt: departure.addingTimeInterval(-lead), departure: departure, international: international)
    }

    /// The queue in the lane the traveller uses: PreCheck when on and known, else standard.
    static func queue(_ m: LeaveTimeMeasure, precheck: Bool) -> (minutes: Int, precheck: Bool)? {
        if precheck, let p = m.precheckMinutes { return (p, true) }
        return m.standardMinutes.map { ($0, false) }
    }
}
