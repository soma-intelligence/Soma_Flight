import Foundation

/// What a flight notification carries. The backend (push-sender) puts `flightId` and `eventId` beside
/// `aps`; `flight_id` is accepted too, so a payload written either way opens the flight.
public struct PushPayload: Sendable, Equatable {
    public var flightId: Flight.ID
    public var eventId: UUID?

    public init(flightId: Flight.ID, eventId: UUID? = nil) {
        self.flightId = flightId; self.eventId = eventId
    }

    /// Nil when there is no valid flight id (any other notification).
    public init?(userInfo: [AnyHashable: Any]) {
        func uuid(_ keys: [String]) -> UUID? {
            for key in keys {
                if let s = userInfo[key] as? String, let id = UUID(uuidString: s) { return id }
            }
            return nil
        }
        guard let flight = uuid(["flightId", "flight_id"]) else { return nil }
        self.init(flightId: flight, eventId: uuid(["eventId", "event_id"]))
    }
}
