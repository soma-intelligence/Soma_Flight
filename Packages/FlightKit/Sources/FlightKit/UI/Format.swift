import Foundation

/// Small display formatters shared by the components.
enum Format {
    /// "18:25" in `tz`.
    static func clock(_ date: Date, _ tz: TimeZone) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        let c = cal.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    /// "2h 37m", "50m", "2h".
    static func minutes(_ total: Int) -> String {
        let m = abs(total)
        let h = m / 60, r = m % 60
        if h == 0 { return "\(r)m" }
        return r == 0 ? "\(h)h" : "\(h)h \(r)m"
    }

    static func minutes(_ d: Duration) -> Int { Int((Double(d.components.seconds) / 60).rounded()) }

    /// "AA 2178", "B6 717", "EJM 444": airline code, space, number.
    static func ident(_ raw: String) -> String {
        let chars = Array(raw)
        guard chars.count > 2 else { return raw }
        let split = chars[2].isLetter ? 3 : 2
        guard split < chars.count else { return raw }
        return String(chars[..<split]) + " " + String(chars[split...])
    }

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
