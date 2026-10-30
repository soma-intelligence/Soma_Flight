import Foundation

/// What a widget shows for one flight at one moment of its timeline. The wording follows the app: the
/// countdown column of My Flights, the status words of the Live Activity (`FlightActivityDisplay`, which
/// this wraps) and the flight sheet's time colours (late in red, early or on time in green).
public struct FlightWidgetDisplay: Sendable, Hashable {
    public var flight: WidgetFlight
    /// The moment drawn: the timeline entry's date.
    public var date: Date
    public var twelveHour: Bool

    public init(_ flight: WidgetFlight, at date: Date, twelveHour: Bool = false) {
        self.flight = flight; self.date = date; self.twelveHour = twelveHour
    }

    /// The Live Activity's display of the same flight, with the progress at `date`.
    public var activity: FlightActivityDisplay {
        let attributes = FlightActivityAttributes(
            flightId: flight.id, ident: flight.ident, originIata: flight.origin.code,
            destinationIata: flight.destination.code, scheduledOut: flight.scheduledOut,
            scheduledIn: flight.scheduledIn, originTimeZone: flight.origin.timeZone,
            destinationTimeZone: flight.destination.timeZone)
        let state = FlightActivityAttributes.ContentState(
            status: flight.status, gateOrigin: flight.gateOrigin, gateDestination: flight.gateDestination,
            estimatedOut: flight.bestOut, estimatedIn: flight.bestIn, progress: flight.progress(at: date))
        return FlightActivityDisplay(attributes, state, twelveHour: twelveHour)
    }

    /// "AF 84".
    public var ident: String { FlightActivityDisplay.ident(flight.ident) }
    /// "CDG → SFO".
    public var routeCodes: String { "\(flight.origin.code) → \(flight.destination.code)" }
    /// "Paris to San Francisco", as My Flights writes a route.
    public var routeCities: String { "\(flight.origin.name) to \(flight.destination.name)" }

    /// Past the take-off as last seen: the arrival leads (time, gate, delay).
    public var isPastDeparture: Bool { activity.isPastDeparture }
    public var isAirborne: Bool { flight.isAirborne }
    /// Progress at `date`, 0...1.
    public var progress: Double { activity.progress }
    public var level: DelayLevel { activity.level }

    // MARK: Countdown

    /// My Flights' countdown column at `date`: time to the gate departure ("1" "DAY", "5" "HRS", "40"
    /// "MIN"), time left in the air ("2h" "LEFT", "40m" "LEFT"), or a word alone ("LANDED", "CANCELED",
    /// "DIVERTED", "DEPARTING" past its departure time while still at the gate, "ARRIVING" past its
    /// arrival time while still in the air, "SCHEDULED" / "IN AIR" when the time is unknown). Whole units,
    /// rounded down.
    public var countdown: (value: String, unit: String) {
        switch flight.status {
        case .canceled: return ("", "CANCELED")
        case .diverted: return ("", "DIVERTED")
        case .landed, .arrived: return ("", "LANDED")
        case .departed, .enRoute:
            guard let end = flight.bestIn else { return ("", "IN AIR") }
            let m = Int(end.timeIntervalSince(date) / 60)
            guard m >= 1 else { return ("", "ARRIVING") }
            return (m >= 60 ? "\(m / 60)h" : "\(m)m", "LEFT")
        case .scheduled, .unknown:
            guard let out = flight.bestOut else { return ("", "SCHEDULED") }
            let s = out.timeIntervalSince(date)
            guard s >= 60 else { return ("", "DEPARTING") }
            if s >= 86_400 {
                let d = Int(s / 86_400)
                return ("\(d)", d == 1 ? "DAY" : "DAYS")
            }
            if s >= 3600 {
                let h = Int(s / 3600)
                return ("\(h)", h == 1 ? "HR" : "HRS")
            }
            return ("\(Int(s / 60))", "MIN")
        }
    }

    /// The countdown in one short token for the round lock screen widget: "3d", "5h", "40m", "2h"; nil
    /// when the countdown is a word alone.
    public var shortCountdown: String? {
        let c = countdown
        guard !c.value.isEmpty else { return nil }
        switch c.unit {
        case "DAY", "DAYS": return "\(c.value)d"
        case "HR", "HRS": return "\(c.value)h"
        case "MIN": return "\(c.value)m"
        default: return c.value
        }
    }

    // MARK: Times

    /// How a time is coloured on the flight sheet: late in red, early or on time in green, plain while
    /// only the schedule is known.
    public enum Tone: Sendable, Hashable { case neutral, onTime, late }

    public static func tone(_ minutes: Int?) -> Tone {
        guard let minutes else { return .neutral }
        return minutes >= 1 ? .late : .onTime
    }

    public var departureTone: Tone { Self.tone(flight.departureDelayMinutes) }
    public var arrivalTone: Tone { Self.tone(flight.arrivalDelayMinutes) }

    public var departureTime: String { activity.departureTime }
    public var arrivalTime: String { activity.arrivalTime }
    /// The schedule, struck through beside the time, once the best time moved off it.
    public var scheduledDeparture: String? { activity.scheduledDeparture }
    public var scheduledArrival: String? { activity.scheduledArrival }
    /// "+1" when it lands on a later local date.
    public var arrivalDayMark: String? { activity.arrivalDayMark }

    /// The time that leads: the departure before take-off, the arrival after.
    public var headlineTime: String { isPastDeparture ? arrivalTime : departureTime }
    public var headlineTone: Tone { isPastDeparture ? arrivalTone : departureTone }

    /// The flight sheet's word for a time's offset: "25m Late", "1h 5m Late", "4m Early", "On Time"; nil
    /// while only the schedule is known.
    public static func offsetWord(_ minutes: Int?) -> String? {
        guard let minutes else { return nil }
        if minutes >= 1 { return "\(FlightActivityDisplay.duration(minutes: minutes)) Late" }
        if minutes <= -1 { return "\(FlightActivityDisplay.duration(minutes: -minutes)) Early" }
        return "On Time"
    }

    /// "Fri, Oct 30": the day it leaves, in the origin's zone.
    public var day: String? {
        guard let out = flight.bestOut ?? flight.scheduledOut else { return nil }
        var style = Date.FormatStyle(locale: Locale(identifier: "en_US_POSIX"), timeZone: flight.origin.zone)
        style = style.weekday(.abbreviated).month(.abbreviated).day()
        return out.formatted(style)
    }

    // MARK: Gate

    /// The gate that matters now: the departure gate before take-off, the arrival gate after.
    public var gate: String? { isPastDeparture ? flight.gateDestination : flight.gateOrigin }
    public var terminal: String? { isPastDeparture ? flight.terminalDestination : flight.terminalOrigin }

    // MARK: Lines

    /// What happened to the flight, in words, for the line under the route: "Departs 18:25 · 25m Late",
    /// "Arrives 14:05 · 2h left", "Landed 14:05", "Canceled".
    public var statusLine: String {
        switch flight.status {
        case .canceled: return "Canceled"
        case .diverted: return "Diverted"
        case .landed, .arrived:
            return "Landed \(arrivalTime)"
        case .departed, .enRoute:
            let c = countdown
            let left = c.value.isEmpty ? c.unit.capitalized : "\(c.value) left"
            return "Arrives \(arrivalTime) · \(left)"
        case .scheduled, .unknown:
            let word = Self.offsetWord(flight.departureDelayMinutes) ?? "Scheduled"
            return "Departs \(departureTime) · \(word)"
        }
    }

    /// The lock screen's one line: "AF 84 · Gate G91 · 25m late". The gate shows once known; the last
    /// part is the delay that matters now, or how the flight ended.
    public var inlineText: String {
        var parts = [ident]
        if let gate { parts.append("Gate \(gate)") }
        let tail: String? = switch flight.status {
        case .canceled: "Canceled"
        case .diverted: "Diverted"
        case .landed, .arrived: "Landed"
        default: Self.offsetWord(isPastDeparture ? flight.arrivalDelayMinutes : flight.departureDelayMinutes)?.lowercased()
        }
        if let tail { parts.append(tail) }
        return parts.joined(separator: " · ")
    }

    /// What VoiceOver reads for the whole widget.
    public var spokenSummary: String {
        let c = countdown
        let count = c.value.isEmpty ? c.unit.capitalized : "\(c.value) \(c.unit.lowercased())"
        return "\(ident), \(routeCities), \(count), \(statusLine.replacingOccurrences(of: " · ", with: ", "))"
    }
}
