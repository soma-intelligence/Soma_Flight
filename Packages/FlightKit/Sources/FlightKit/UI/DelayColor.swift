import SwiftUI

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
        case .outOfWindow: "Flights can be searched from 10 days back to 2 days ahead. Pick another date."
        case .rateLimited: "Too many searches. Try again in a few minutes."
        case .planLimit: "Free accounts follow up to 3 flights at a time."
        case .unauthorized: "Please sign in again."
        case .offline: "You're offline. Showing the last update."
        case .localData: "The flights saved on this device couldn't be cleared. Try again, or restart the app."
        case .rejected(let why): why
        }
    }
}
