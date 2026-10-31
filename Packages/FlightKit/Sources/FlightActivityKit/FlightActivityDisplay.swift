import Foundation

/// What the Live Activity shows, worked out from the static attributes and the latest state. The views
/// only lay it out; the wording and the delay rule match the app's flight card.
public struct FlightActivityDisplay: Sendable, Hashable {
    public var attributes: FlightActivityAttributes
    public var state: FlightActivityAttributes.ContentState
    /// "6:25 PM" rather than "18:25": the app's clock setting, read by the extension from the App Group.
    public var twelveHour: Bool
    /// When the card is drawn. With it, a flight in the air moves on by time from its last state (the
    /// extension passes the render time, so a card with no news since take-off still advances); nil keeps
    /// the state's own progress.
    public var now: Date?

    public init(_ attributes: FlightActivityAttributes, _ state: FlightActivityAttributes.ContentState,
                twelveHour: Bool = false, now: Date? = nil) {
        self.attributes = attributes; self.state = state; self.twelveHour = twelveHour; self.now = now
    }

    public var isAirborne: Bool { [.departed, .enRoute].contains(state.status) }
    /// Past the take-off: delays are measured on the arrival, and the island shows the arrival time.
    public var isPastDeparture: Bool { [.departed, .enRoute, .landed, .arrived, .diverted].contains(state.status) }

    public var departureDelay: Duration? { Self.delay(attributes.scheduledOut, state.estimatedOut) }
    public var arrivalDelay: Duration? { Self.delay(attributes.scheduledIn, state.estimatedIn) }

    private static func delay(_ scheduled: Date?, _ best: Date?) -> Duration? {
        guard let scheduled, let best else { return nil }
        return .seconds(best.timeIntervalSince(scheduled))
    }

    /// The flight card's rule: departure delay before take-off, arrival delay after.
    public var level: DelayLevel {
        let delay: Duration? = switch state.status {
        case .landed, .arrived, .enRoute: arrivalDelay ?? departureDelay
        default: departureDelay
        }
        return DelayLevel.for(delay: delay, status: state.status)
    }

    /// "On Time", "25m Late", "In the Air", "In the Air, 1h 5m Late", "Landed", "Canceled".
    public var statusText: String {
        switch state.status {
        case .canceled: return "Canceled"
        case .diverted: return "Diverted"
        case .landed: return "Landed"
        case .arrived: return "Arrived"
        case .departed, .enRoute:
            if let late = lateMinutes(arrivalDelay ?? departureDelay) { return "In the Air, \(late) Late" }
            return "In the Air"
        case .scheduled, .unknown:
            if let late = lateMinutes(departureDelay) { return "\(late) Late" }
            return state.estimatedOut == nil ? "Scheduled" : "On Time"
        }
    }

    /// Short form for the island's compact trailing side when there is no time to show.
    public var shortStatus: String {
        switch state.status {
        case .canceled: "Canceled"
        case .diverted: "Diverted"
        case .landed: "Landed"
        case .arrived: "Arrived"
        default: "--:--"
        }
    }

    private func lateMinutes(_ d: Duration?) -> String? {
        guard let d else { return nil }
        let m = DelayLevel.wholeMinutes(d)
        return m >= 15 ? Self.duration(minutes: m) : nil
    }

    /// "2h 37m", "50m", "2h".
    public static func duration(minutes total: Int) -> String {
        let m = abs(total)
        let h = m / 60, r = m % 60
        if h == 0 { return "\(r)m" }
        return r == 0 ? "\(h)h" : "\(h)h \(r)m"
    }

    /// "AA 2178", "B6 717", "EJM 444": airline code, space, number.
    public static func ident(_ raw: String) -> String {
        let chars = Array(raw)
        guard chars.count > 2 else { return raw }
        let split = chars[2].isLetter ? 3 : 2
        guard split < chars.count else { return raw }
        return String(chars[..<split]) + " " + String(chars[split...])
    }

    public var ident: String { Self.ident(attributes.ident) }

    public var originZone: TimeZone { attributes.originTimeZone.flatMap(TimeZone.init(identifier:)) ?? .current }
    public var destinationZone: TimeZone { attributes.destinationTimeZone.flatMap(TimeZone.init(identifier:)) ?? .current }

    /// "18:25", or "6:25 PM" with `twelveHour`, local time at the airport. English only, like the rest of
    /// v1: AM and PM are not localized.
    public static func clock(_ date: Date?, _ tz: TimeZone, twelveHour: Bool = false) -> String {
        guard let date else { return "--:--" }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        let c = cal.dateComponents([.hour, .minute], from: date)
        let h = c.hour ?? 0, m = c.minute ?? 0
        guard twelveHour else { return String(format: "%02d:%02d", h, m) }
        return String(format: "%d:%02d %@", h % 12 == 0 ? 12 : h % 12, m, h < 12 ? "AM" : "PM")
    }

    public var departureTime: String { Self.clock(state.estimatedOut, originZone, twelveHour: twelveHour) }
    public var arrivalTime: String { Self.clock(state.estimatedIn, destinationZone, twelveHour: twelveHour) }
    /// The schedule, when the best time moved off it by a minute or more (shown struck through).
    public var scheduledDeparture: String? { moved(attributes.scheduledOut, state.estimatedOut, originZone) }
    public var scheduledArrival: String? { moved(attributes.scheduledIn, state.estimatedIn, destinationZone) }

    private func moved(_ scheduled: Date?, _ best: Date?, _ tz: TimeZone) -> String? {
        guard let scheduled, let best, abs(best.timeIntervalSince(scheduled)) >= 60 else { return nil }
        return Self.clock(scheduled, tz, twelveHour: twelveHour)
    }

    /// "+1" when the flight lands on a later local date than it leaves ("-1" across the date line the
    /// other way), nil on the same day or when a time is missing.
    public var arrivalDayMark: String? {
        guard let out = state.estimatedOut, let inn = state.estimatedIn else { return nil }
        func day(_ d: Date, _ tz: TimeZone) -> DateComponents {
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = tz
            return cal.dateComponents([.year, .month, .day], from: d)
        }
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = .gmt
        guard let a = utc.date(from: day(out, originZone)), let b = utc.date(from: day(inn, destinationZone)),
              let diff = utc.dateComponents([.day], from: a, to: b).day, diff != 0 else { return nil }
        return diff > 0 ? "+\(diff)" : "\(diff)"
    }

    /// What VoiceOver reads for an end of the trip: "Departs SFO 13:08, scheduled 12:18, gate F11".
    public func spokenEnd(departure: Bool) -> String {
        let code = departure ? attributes.originIata : attributes.destinationIata
        let time = departure ? departureTime : arrivalTime
        var parts = ["\(departure ? "Departs" : "Arrives") \(code) \(time)"]
        if !departure, let mark = arrivalDayMark { parts[0] += " (\(mark) day)" }
        if let s = departure ? scheduledDeparture : scheduledArrival { parts.append("scheduled \(s)") }
        let gate = departure ? state.gateOrigin : state.gateDestination
        if let gate { parts.append("gate \(gate)") }
        return parts.joined(separator: ", ")
    }

    /// What VoiceOver reads for the island's compact and minimal forms.
    public var spokenSummary: String {
        "\(ident), \(statusText), progress \(Int((progress * 100).rounded())) percent"
    }

    public var originGate: String { "Gate \(state.gateOrigin ?? "--")" }
    public var destinationGate: String { "Gate \(state.gateDestination ?? "--")" }

    /// The time the island's compact side shows: departure before take-off, arrival after.
    public var compactTime: String {
        if state.isFinal || state.status == .diverted { return shortStatus }
        return isPastDeparture ? arrivalTime : departureTime
    }

    /// Progress drawn on the bar: the state's, kept at 0 before take-off and 1 once down. In the air with
    /// `now`, the share of the best times elapsed when that is further on (never back, never past 1).
    public var progress: Double {
        switch state.status {
        case .landed, .arrived: return 1
        case .scheduled, .unknown, .canceled: return 0
        default: break
        }
        guard isAirborne, let now, let out = state.estimatedOut, let inn = state.estimatedIn, inn > out else {
            return state.progress
        }
        return max(state.progress, min(1, max(0, now.timeIntervalSince(out) / inn.timeIntervalSince(out))))
    }
}
