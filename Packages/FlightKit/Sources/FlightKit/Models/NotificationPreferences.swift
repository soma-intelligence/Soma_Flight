import Foundation

/// The alert categories a user wants, one row of `notification_preferences`. Everything is on until the
/// user turns something off, and an account with no row reads as `.allOn`.
public struct NotificationPreferences: Codable, Sendable, Hashable {
    /// Delays, back on time, schedule changes and a late inbound aircraft.
    public var delays: Bool
    /// Gate assigned, gate changes and terminal changes.
    public var gates: Bool
    /// Gate out, take-off, landing and arrival at the gate.
    public var takeoffLanding: Bool
    /// The baggage belt.
    public var baggage: Bool
    /// Cancellations, reinstated flights and diversions.
    public var cancellations: Bool
    /// The device's own reminders: check-in, the morning of the flight, leaving for the airport.
    public var reminders: Bool

    public init(delays: Bool = true, gates: Bool = true, takeoffLanding: Bool = true, baggage: Bool = true,
                cancellations: Bool = true, reminders: Bool = true) {
        self.delays = delays; self.gates = gates; self.takeoffLanding = takeoffLanding
        self.baggage = baggage; self.cancellations = cancellations; self.reminders = reminders
    }

    public static let allOn = NotificationPreferences()

    /// One toggle of the Notifications screen.
    public enum Category: String, CaseIterable, Sendable, Identifiable {
        case delays, gates, takeoffLanding, baggage, cancellations, reminders
        public var id: String { rawValue }

        public var keyPath: WritableKeyPath<NotificationPreferences, Bool> {
            switch self {
            case .delays: \.delays
            case .gates: \.gates
            case .takeoffLanding: \.takeoffLanding
            case .baggage: \.baggage
            case .cancellations: \.cancellations
            case .reminders: \.reminders
            }
        }

        /// The row's title.
        public var title: String {
            switch self {
            case .delays: "Delays"
            case .gates: "Gates and Terminals"
            case .takeoffLanding: "Take-off and Landing"
            case .baggage: "Baggage"
            case .cancellations: "Cancellations and Diversions"
            case .reminders: "Reminders"
            }
        }

        /// What the row sends, in the grey line under the title.
        public var detail: String {
            switch self {
            case .delays: "New delays, back on time, schedule changes, a late inbound plane"
            case .gates: "Your gate, gate changes and terminal changes"
            case .takeoffLanding: "Left the gate, took off, landed, arrived at the gate"
            case .baggage: "The belt your bags come out on"
            case .cancellations: "Canceled, back on the schedule, diverted"
            case .reminders: "Check-in opens, the morning of the flight, time to leave"
            }
        }

        public var icon: String {
            switch self {
            case .delays: "clock.badge.exclamationmark"
            case .gates: "door.left.hand.open"
            case .takeoffLanding: "airplane.departure"
            case .baggage: "suitcase.rolling.fill"
            case .cancellations: "xmark.circle"
            case .reminders: "alarm"
            }
        }
    }

    public subscript(_ c: Category) -> Bool {
        get { self[keyPath: c.keyPath] }
        set { self[keyPath: c.keyPath] = newValue }
    }
}
