import Foundation

public enum PushTokenKind: String, Sendable, Hashable {
    case alert
    case liveActivity = "live_activity"
}

public protocol PushService: Sendable {
    func register(deviceToken: Data, kind: PushTokenKind, flightId: Flight.ID?) async throws(APIError)
}
