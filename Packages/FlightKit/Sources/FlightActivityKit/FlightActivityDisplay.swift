import Foundation

/// What the Live Activity shows, worked out from the static attributes and the latest state. The views
/// only lay it out; the wording and the delay rule match the app's flight card.
public struct FlightActivityDisplay: Sendable, Hashable {
    public var attributes: FlightActivityAttributes
    public var state: FlightActivityAttributes.ContentState

    public init(_ attributes: FlightActivityAttributes, _ state: FlightActivityAttributes.ContentState) {
        self.attributes = attributes; self.state = state
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

    /// "18:25", local time at the airport. 24 hour like the app's default: the extension cannot read the
    /// app's clock setting (no shared defaults).
    public static func clock(_ date: Date?, _ tz: TimeZone) -> String {
        guard let date else { return "--:--" }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        let c = cal.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    public var departureTime: String { Self.clock(state.estimatedOut, originZone) }
    public var arrivalTime: String { Self.clock(state.estimatedIn, destinationZone) }
    /// The schedule, when the best time moved off it by a minute or more (shown struck through).
    public var scheduledDeparture: String? { moved(attributes.scheduledOut, state.estimatedOut, originZone) }
    public var scheduledArrival: String? { moved(attributes.scheduledIn, state.estimatedIn, destinationZone) }

    private func moved(_ scheduled: Date?, _ best: Date?, _ tz: TimeZone) -> String? {
        guard let scheduled, let best, abs(best.timeIntervalSince(scheduled)) >= 60 else { return nil }
        return Self.clock(scheduled, tz)
    }

    public var originGate: String { "Gate \(state.gateOrigin ?? "--")" }
    public var destinationGate: String { "Gate \(state.gateDestination ?? "--")" }

    /// The time the island's compact side shows: departure before take-off, arrival after.
    public var compactTime: String {
        if state.isFinal || state.status == .diverted { return shortStatus }
        return isPastDeparture ? arrivalTime : departureTime
    }

    /// Progress drawn on the bar: the state's, kept at 0 before take-off and 1 once down.
    public var progress: Double {
        switch state.status {
        case .landed, .arrived: 1
        case .scheduled, .unknown, .canceled: 0
        default: state.progress
        }
    }
}
