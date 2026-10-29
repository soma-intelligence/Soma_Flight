import Foundation

/// Small display formatters shared by the components.
enum Format {
    /// "18:25" in `tz`, or "6:25 PM" for `.h12`. Screens pass `Units.clock` from the environment.
    static func clock(_ date: Date, _ tz: TimeZone, _ style: TimeStyle = .h24) -> String {
        FlightActivityDisplay.clock(date, tz, twelveHour: style == .h12)
    }

    /// "2h 37m", "50m", "2h".
    static func minutes(_ total: Int) -> String { FlightActivityDisplay.duration(minutes: total) }

    /// Whole minutes, truncated toward zero. `DelayLevel` uses the same value, so a label and its
    /// colour always agree (14m 30s is "14m", on time).
    static func minutes(_ d: Duration) -> Int { DelayLevel.wholeMinutes(d) }

    /// "AA 2178", "B6 717", "EJM 444": airline code, space, number.
    static func ident(_ raw: String) -> String { FlightActivityDisplay.ident(raw) }

    static func ago(_ date: Date, now: Date) -> String {
        let m = max(0, Int(now.timeIntervalSince(date) / 60))
        if m < 1 { return "just now" }
        if m < 60 { return "\(m) min ago" }
        let h = m / 60
        if h < 24 { return "\(h) hr ago" }
        return "\(h / 24) d ago"
    }
}

extension Flight {
    var originCode: String { originIata ?? originIcao }
    var destinationCode: String { destinationIata ?? destinationIcao }

    /// The level that colours this flight: departure delay before take-off, arrival delay after.
    var level: DelayLevel {
        let delay: Duration? = switch status {
        case .landed, .arrived, .enRoute: arrivalDelay ?? departureDelay
        default: departureDelay
        }
        return DelayLevel.for(delay: delay, status: status)
    }
}
