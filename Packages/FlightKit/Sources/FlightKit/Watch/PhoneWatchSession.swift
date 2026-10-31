#if canImport(WatchConnectivity) && os(iOS)
import Foundation
import os
import WatchConnectivity

/// The iPhone's end of WatchConnectivity: replaces the application context with each snapshot and
/// answers the watch's requests for a fresh one.
///
/// A request is answered at once with the context last sent (`WCSession.applicationContext`), then the
/// sender rebuilds the snapshot on the main actor and sends a new context if anything changed.
@MainActor
public final class PhoneWatchSession: NSObject, WatchTransport {
    public var onRequest: (@MainActor () -> Void)?
    private let delegate = Delegate()

    /// Activates the session; nothing happens on a phone without WatchConnectivity support.
    override public init() {
        super.init()
        guard WCSession.isSupported() else { return }
        delegate.onRequest = { [weak self] in
            Task { @MainActor in self?.onRequest?() }
        }
        WCSession.default.delegate = delegate
        WCSession.default.activate()
    }

    public var canSend: Bool {
        guard WCSession.isSupported() else { return false }
        let session = WCSession.default
        return session.activationState == .activated && session.isPaired && session.isWatchAppInstalled
    }

    public func send(_ data: Data) throws {
        try WCSession.default.updateApplicationContext([WatchSnapshot.contextKey: data])
    }

    /// The delegate WatchConnectivity calls on its own queue.
    private final class Delegate: NSObject, WCSessionDelegate, @unchecked Sendable {
        // Set once, before the session is activated, and only read after.
        var onRequest: (@Sendable () -> Void)?

        func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
                     error: (any Error)?) {
            if let error {
                watchLog.error("Watch session not activated: \(error.localizedDescription, privacy: .public)")
                return
            }
            // A snapshot skipped while the session was not active yet goes now.
            onRequest?()
        }

        func session(_ session: WCSession, didReceiveMessage message: [String: Any],
                     replyHandler: @escaping ([String: Any]) -> Void) {
            guard message[WatchSnapshot.requestKey] != nil else { return replyHandler([:]) }
            replyHandler(session.applicationContext)
            onRequest?()
        }

        func sessionWatchStateDidChange(_ session: WCSession) {
            // The watch app was just installed, or a watch paired: it needs the snapshot.
            if session.isPaired, session.isWatchAppInstalled { onRequest?() }
        }

        func sessionDidBecomeInactive(_ session: WCSession) {}

        func sessionDidDeactivate(_ session: WCSession) {
            // Switching watches: activate again for the new one.
            session.activate()
        }
    }
}

private let watchLog = Logger(subsystem: "me.somalabs.flight", category: "watch")
#endif
