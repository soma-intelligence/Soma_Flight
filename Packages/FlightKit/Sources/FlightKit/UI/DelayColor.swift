import SwiftUI

/// How late a flight is, bucketed the way the board and charts colour it.
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
        let minutes = Format.minutes(delay)
        if minutes >= 45 { return .veryLate }
        if minutes >= 15 { return .late }
        return .onTime
    }
}

public extension DelayLevel {
    var color: Color {
        switch self {
        case .onTime: Theme.onTime
        case .late: Theme.late
        case .veryLate: Theme.veryLate
        case .canceled: Theme.canceled
        case .diverted: Theme.diverted
        }
    }
}

public extension APIError {
    /// User-facing copy for the error banner.
    var message: String {
        switch self {
        case .providerUnavailable, .decoding: "Flight data is temporarily unavailable. Showing the last update."
        case .notFound: "No flight found. Check the number and date."
        case .rateLimited: "Too many searches. Try again in a few minutes."
        case .planLimit: "Free accounts follow up to 3 flights at a time."
        case .unauthorized: "Please sign in again."
        case .offline: "You're offline. Showing the last update."
        case .localData: "The flights saved on this device couldn't be cleared. Try again."
        }
    }
}
