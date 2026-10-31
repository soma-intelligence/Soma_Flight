#if canImport(WatchConnectivity) && os(watchOS)
import Foundation
import os
import WatchConnectivity

/// The watch's end of WatchConnectivity: takes the snapshots the iPhone sends (application context,
/// and replies to the watch's own requests) and hands them to `WatchFlightsModel`.
///
/// WatchConnectivity calls the delegate on a background queue; each snapshot is decoded there and handed
/// to the model on the main actor.
public final class WatchSessionReceiver: NSObject, WCSessionDelegate, Sendable {
    private let deliver: @Sendable (WatchSnapshot) -> Void
    private static let log = Logger(subsystem: "me.somalabs.flight", category: "watch")

    public init(model: WatchFlightsModel) {
        deliver = { [weak model] snapshot in
            Task { @MainActor in model?.receive(snapshot) }
        }
        super.init()
    }

    /// Starts the session. The context the phone sent while the app was not running arrives at
    /// activation (`receivedApplicationContext`).
    public func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    /// Asks the phone for a fresh snapshot, when it can be reached. The phone answers with the one it
    /// last sent, then sends a new application context if anything changed.
    public func requestRefresh() {
        let session = WCSession.default
        guard session.activationState == .activated, session.isReachable else { return }
        let deliver = deliver
        session.sendMessage([WatchSnapshot.requestKey: true], replyHandler: { reply in
            if let snapshot = WatchSnapshot.from(applicationContext: reply) { deliver(snapshot) }
        }, errorHandler: { error in
            Self.log.info("Snapshot request failed: \(error.localizedDescription, privacy: .public)")
        })
    }

    // MARK: WCSessionDelegate

    public func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
                        error: (any Error)?) {
        if let error {
            Self.log.error("Watch session not activated: \(error.localizedDescription, privacy: .public)")
            return
        }
        if let snapshot = WatchSnapshot.from(applicationContext: session.receivedApplicationContext) {
            deliver(snapshot)
        }
        requestRefresh()
    }

    public func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        guard let snapshot = WatchSnapshot.from(applicationContext: applicationContext) else {
            Self.log.error("Unreadable snapshot from the phone (another version?)")
            return
        }
        deliver(snapshot)
    }

    public func sessionReachabilityDidChange(_ session: WCSession) {
        if session.isReachable { requestRefresh() }
    }
}
#endif
