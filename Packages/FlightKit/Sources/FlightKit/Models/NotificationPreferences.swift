import Foundation

/// The alert categories a user wants, one row of `notification_preferences`. Everything is on until the
/// user turns something off, and an account with no row reads as `.allOn`.
public struct NotificationPreferences: Codable, Sendable, Hashable {
    /// Delays, back on time, schedule changes, a late inbound aircraft and FAA programs (ground stops,
    /// ground delay programs, closures) at either airport.
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
    /// Boarding started and boarding time changes (sent only when a source gives a boarding time).
    public var boarding: Bool
    /// The airline swapped the aircraft type or the registration before departure.
    public var aircraft: Bool
    /// FAA programs (ground stops, ground delay programs, closures) at the airports you follow.
    public var favoriteAirports: Bool

    public init(delays: Bool = true, gates: Bool = true, takeoffLanding: Bool = true, baggage: Bool = true,
                cancellations: Bool = true, reminders: Bool = true, boarding: Bool = true,
                aircraft: Bool = true, favoriteAirports: Bool = true) {
        self.delays = delays; self.gates = gates; self.takeoffLanding = takeoffLanding
        self.baggage = baggage; self.cancellations = cancellations; self.reminders = reminders
        self.boarding = boarding; self.aircraft = aircraft; self.favoriteAirports = favoriteAirports
    }

    /// A column the server does not have yet (the migration is not applied) reads as on.
    public init(from decoder: Decoder) throws {
        enum Key: String, CodingKey {
            case delays, gates, takeoffLanding, baggage, cancellations, reminders, boarding, aircraft, favoriteAirports
        }
        let c = try decoder.container(keyedBy: Key.self)
        func flag(_ k: Key) throws -> Bool { try c.decodeIfPresent(Bool.self, forKey: k) ?? true }
        self.init(delays: try flag(.delays), gates: try flag(.gates), takeoffLanding: try flag(.takeoffLanding),
                  baggage: try flag(.baggage), cancellations: try flag(.cancellations),
                  reminders: try flag(.reminders), boarding: try flag(.boarding), aircraft: try flag(.aircraft),
                  favoriteAirports: try flag(.favoriteAirports))
    }

    public static let allOn = NotificationPreferences()

    /// One toggle of the Notifications screen.
    public enum Category: String, CaseIterable, Sendable, Identifiable {
        case delays, gates, takeoffLanding, baggage, cancellations, reminders, boarding, aircraft, favoriteAirports
        public var id: String { rawValue }

        public var keyPath: WritableKeyPath<NotificationPreferences, Bool> {
            switch self {
            case .delays: \.delays
            case .gates: \.gates
            case .takeoffLanding: \.takeoffLanding
            case .baggage: \.baggage
            case .cancellations: \.cancellations
            case .reminders: \.reminders
            case .boarding: \.boarding
            case .aircraft: \.aircraft
            case .favoriteAirports: \.favoriteAirports
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
            case .boarding: "Boarding"
            case .aircraft: "Aircraft Changes"
            case .favoriteAirports: "Favorite Airports"
            }
        }

        /// What the row sends, in the grey line under the title.
        public var detail: String {
            switch self {
            case .delays: "New delays, back on time, schedule changes, a late inbound plane, FAA ground stops"
            case .gates: "Your gate, gate changes and terminal changes"
            case .takeoffLanding: "Left the gate, took off, landed, arrived at the gate"
            case .baggage: "The belt your bags come out on"
            case .cancellations: "Canceled, back on the schedule, diverted"
            case .reminders: "Check-in opens, the morning of the flight, time to leave"
            case .boarding: "Boarding has started, boarding time changes"
            case .aircraft: "A different aircraft type or tail number before you leave"
            case .favoriteAirports: "Ground stops, delay programs and closures at airports you follow"
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
            case .boarding: "figure.walk.departure"
            case .aircraft: "arrow.triangle.2.circlepath"
            case .favoriteAirports: "star"
            }
        }
    }

    public subscript(_ c: Category) -> Bool {
        get { self[keyPath: c.keyPath] }
        set { self[keyPath: c.keyPath] = newValue }
    }
}
