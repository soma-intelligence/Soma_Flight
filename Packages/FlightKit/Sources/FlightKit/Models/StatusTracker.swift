import Foundation

extension DistanceUnit: Codable {}

/// Plan 38: a frequent flyer programme the traveller types in by hand, and the goals they want to reach.
/// No airline login and no tier rules bundled: the app only counts the history against the traveller's
/// own numbers. Kept on the device (`StatusPrograms`).
public struct StatusProgram: Codable, Sendable, Hashable, Identifiable {
    /// The flights that count: an alliance's members, or airlines picked one by one (ICAO codes).
    public enum Airlines: Codable, Sendable, Hashable {
        case alliance(Alliance)
        case airlines([String])
    }

    public enum Period: String, Codable, Sendable, Hashable, CaseIterable {
        /// January 1 to today.
        case calendarYear
        /// The 12 months up to today.
        case rolling12Months

        public var title: String {
            switch self {
            case .calendarYear: "This calendar year"
            case .rolling12Months: "Last 12 months"
            }
        }
    }

    public var id: UUID
    /// What the traveller calls it: "Flying Blue Gold".
    public var name: String
    public var airlines: Airlines
    public var period: Period
    /// Segments to fly; nil when the programme does not count them.
    public var segmentGoal: Int?
    /// Distance to fly in `distanceUnit`; nil when the programme does not count it.
    public var distanceGoal: Int?
    /// The unit the distance goal was typed in.
    public var distanceUnit: DistanceUnit

    public init(id: UUID = UUID(), name: String, airlines: Airlines, period: Period = .calendarYear,
                segmentGoal: Int? = nil, distanceGoal: Int? = nil, distanceUnit: DistanceUnit = .km) {
        self.id = id; self.name = name; self.airlines = airlines; self.period = period
        self.segmentGoal = segmentGoal; self.distanceGoal = distanceGoal; self.distanceUnit = distanceUnit
    }

    /// True when it names something, counts some airlines and has at least one goal.
    public var isValid: Bool {
        let named = !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let some: Bool = switch airlines {
        case .alliance: true
        case .airlines(let codes): !codes.isEmpty
        }
        return named && some && ((segmentGoal ?? 0) > 0 || (distanceGoal ?? 0) > 0)
    }
}

/// How far a programme has come over its period.
public struct StatusProgress: Sendable, Hashable {
    public var segments: Int
    public var distanceKm: Int
    /// The period's first moment.
    public var since: Date
}

public enum StatusTracker {
    /// The ICAO code of the airline that flew `f`: its airline (name or code) when the reference list knows
    /// it, else the flight number's designator.
    static func airline(of f: PastFlight, reference: ReferenceData) -> String? {
        if let a = f.airline, let hit = reference.airline(a) { return hit.id }
        return reference.airline(ident: f.ident)?.id
    }

    /// True when `f` was flown with one of the programme's airlines. Canceled flights never count.
    public static func qualifies(_ f: PastFlight, _ program: StatusProgram, reference: ReferenceData = .bundled()) -> Bool {
        guard f.status != .canceled, let code = airline(of: f, reference: reference) else { return false }
        switch program.airlines {
        case .alliance(let a): return reference.airline(code)?.alliance == a
        case .airlines(let codes): return codes.contains { $0.uppercased() == code }
        }
    }

    /// The start of the programme's period on `now`: January 1 in `calendar`'s zone, or 12 months back.
    public static func periodStart(_ period: StatusProgram.Period, now: Date, calendar: Calendar = .current) -> Date {
        switch period {
        case .calendarYear:
            return calendar.dateInterval(of: .year, for: now)?.start ?? now
        case .rolling12Months:
            return calendar.date(byAdding: .month, value: -12, to: now) ?? now
        }
    }

    /// Segments and distance flown with the programme's airlines from the period's start up to `now`.
    public static func progress(_ program: StatusProgram, flights: [PastFlight], now: Date,
                                calendar: Calendar = .current, reference: ReferenceData = .bundled()) -> StatusProgress {
        let since = periodStart(program.period, now: now, calendar: calendar)
        let counted = flights.filter { $0.date >= since && $0.date <= now && qualifies($0, program, reference: reference) }
        return StatusProgress(segments: counted.count, distanceKm: counted.reduce(0) { $0 + $1.distanceKm }, since: since)
    }

    /// `value` in `from` as kilometres.
    public static func km(_ value: Int, from unit: DistanceUnit) -> Double {
        unit == .km ? Double(value) : Double(value) * TravelFacts.kmPerMile
    }

    /// `km` in `unit`, rounded to a whole number.
    public static func distance(_ km: Double, in unit: DistanceUnit) -> Int {
        Int((unit == .km ? km : km / TravelFacts.kmPerMile).rounded())
    }

    /// Share of a goal reached, 0 to 1.
    public static func share(_ done: Double, of goal: Double) -> Double {
        goal > 0 ? min(max(done / goal, 0), 1) : 0
    }
}

/// The tracker's words.
enum StatusFacts {
    static let title = "Status"

    /// "18 of 30 segments".
    static func segments(_ done: Int, of goal: Int) -> String {
        String(localized: "\(grouped(done)) of \(grouped(goal)) segments", bundle: .main)
    }

    /// "41,200 of 50,000 mi", in the app's unit whatever the goal was typed in.
    static func distance(_ p: StatusProgress, goal: Int, goalUnit: DistanceUnit, in unit: DistanceUnit) -> String {
        let done = StatusTracker.distance(Double(p.distanceKm), in: unit)
        let target = StatusTracker.distance(StatusTracker.km(goal, from: goalUnit), in: unit)
        return String(localized: "\(grouped(done)) of \(grouped(target)) \(unit.rawValue)", bundle: .main)
    }

    /// "Star Alliance · This calendar year", "Air France, KLM · Last 12 months".
    static func scope(_ program: StatusProgram, reference: ReferenceData = .bundled()) -> String {
        let who: String = switch program.airlines {
        case .alliance(let a): a.title
        case .airlines(let codes): codes.map { reference.airline($0)?.name ?? $0 }.joined(separator: ", ")
        }
        return "\(who) \u{00B7} \(String(localized: String.LocalizationValue(program.period.title), bundle: .main))"
    }

    static let caveat = "Counted from your flights in Soma Flight. Your programme's own rules and partner flights may count differently."

    static func grouped(_ n: Int) -> String {
        n.formatted(.number.grouping(.automatic).locale(Locale(identifier: "en_US")))
    }
}
