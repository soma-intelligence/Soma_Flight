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

    /// The level's hue for words (status text, a revised time): darker in light mode so it reaches 4.5:1
    /// on the card and the page (A3). Dots, bars and arcs keep `color`.
    var textColor: Color {
        switch self {
        case .onTime: Theme.onTimeText
        case .late: Theme.lateText
        case .veryLate: Theme.veryLateText
        case .canceled: Theme.canceledText
        case .diverted: Theme.divertedText
        }
    }
}

public extension APIError {
    /// User-facing copy for the error banner, written for a screen that still shows content (the last
    /// update stays on screen). Same as `message(hasContent: true)`.
    var message: String { message(hasContent: true) }

    /// User-facing copy for the error banner (E8). With `hasContent` false (nothing on screen: a search, an
    /// airport with no cache, an empty home) the copy never promises "Showing the last update".
    func message(hasContent: Bool) -> String {
        switch self {
        case .providerUnavailable, .decoding:
            hasContent ? "Flight data is temporarily unavailable. Showing the last update."
                : "Flight data is temporarily unavailable. Try again in a moment."
        case .notFound: "No flight found. Check the number and date."
        case .outOfWindow: "Flights can be searched from 10 days back to 2 days ahead. Pick another date."
        case .rateLimited: "Too many searches. Try again in a few minutes."
        case .planLimit: "You can follow up to 3 flights at a time."
        case .unauthorized: "Please sign in again."
        case .offline:
            hasContent ? "You're offline. Showing the last update."
                : "You're offline. Connect to the internet and try again."
        case .localData: "The flights saved on this device couldn't be cleared. Try again, or restart the app."
        case .rejected(let why): why
        }
    }
}
