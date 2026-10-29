import Foundation
import Observation

/// Where the app delegate leaves what the system hands it, until the home can act on it. The delegate
/// exists before the home is built (a notification tap can launch the app), so a tap, a foreground
/// notification or a device token waits here. `serial` changes with every arrival, for views to watch.
@MainActor @Observable
public final class PushInbox {
    public private(set) var serial = 0
    public private(set) var deviceToken: Data?
    public private(set) var pendingFlight: Flight.ID?
    public private(set) var foregroundFlight: Flight.ID?

    public init() {}

    public func receive(deviceToken token: Data) {
        deviceToken = token
        serial += 1
    }

    /// The user tapped a notification. False when it is not a flight's.
    @discardableResult
    public func receiveTap(_ userInfo: [AnyHashable: Any]) -> Bool {
        guard let payload = PushPayload(userInfo: userInfo) else { return false }
        receiveTap(payload)
        return true
    }

    public func receiveTap(_ payload: PushPayload) {
        pendingFlight = payload.flightId
        serial += 1
    }

    /// A notification arrived with the app open.
    public func receiveForeground(_ payload: PushPayload) {
        foregroundFlight = payload.flightId
        serial += 1
    }

    /// Puts a tapped flight back (it could not be fetched for now); no new arrival is signalled.
    func keepPending(_ id: Flight.ID) { pendingFlight = id }

    func takePendingFlight() -> Flight.ID? { defer { pendingFlight = nil }; return pendingFlight }
    func takeForegroundFlight() -> Flight.ID? { defer { foregroundFlight = nil }; return foregroundFlight }
}
