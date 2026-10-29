import Foundation

/// How late a flight is, bucketed the way the board and charts colour it. Lives here so the Live
/// Activity (widget extension) and the app colour a flight the same way; FlightKit re-exports it.
public enum DelayLevel: String, Sendable, Hashable, CaseIterable {
    case onTime, late, veryLate, canceled, diverted

    /// On time under 15 min, late 15 to 44 min, very late 45 min or more.
    /// Canceled and diverted win over any delay.
    public static func `for`(delay: Duration?, status: FlightStatus) -> DelayLevel {
        switch status {
        case .canceled: return .canceled
        case .diverted: return .diverted
        default: break
        }
        guard let delay else { return .onTime }
        let minutes = wholeMinutes(delay)
        if minutes >= 45 { return .veryLate }
        if minutes >= 15 { return .late }
        return .onTime
    }

    /// Whole minutes, truncated toward zero (14m 30s is 14, on time). `Format.minutes` is the same rule.
    public static func wholeMinutes(_ d: Duration) -> Int { Int(d.components.seconds / 60) }
}
