import Foundation
import UserNotifications
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// How the end of a long import reaches the traveller who left the app meanwhile: a local notification,
/// with the permission asked for (once, while the app is in front) only when it was never answered.
/// Behind a protocol for tests.
@MainActor
public protocol ImportNotifier: AnyObject {
    /// True while the app is in front: the import then ends on its result screen or a toast.
    var isAppActive: Bool { get }
    /// Asks for notification permission when it was never asked. Called as a long import starts.
    func prepare() async
    /// Posts "Import finished" now, when the permission allows it.
    func notify(title: String, body: String) async
    /// Keeps the app running in the background until `end` is called (iOS gives it a few minutes), so an
    /// import the traveller leaves finishes. Returns a token for `end`.
    func beginBackgroundWork() -> Int
    func endBackgroundWork(_ token: Int)
}

/// `UNUserNotificationCenter` and the app's run state. Uses the app's own authorizer (the one follows use)
/// so the prompt and its answer are the same everywhere.
@MainActor
public final class SystemImportNotifier: ImportNotifier {
    private let authorizer: any NotificationAuthorizer

    public init(authorizer: any NotificationAuthorizer = SystemNotificationAuthorizer()) {
        self.authorizer = authorizer
    }

    public var isAppActive: Bool {
        #if os(iOS)
        UIApplication.shared.applicationState == .active
        #elseif os(macOS)
        NSApplication.shared.isActive
        #else
        true
        #endif
    }

    public func prepare() async {
        if await authorizer.status() == .notDetermined { _ = await authorizer.request() }
    }

    public func notify(title: String, body: String) async {
        guard await authorizer.status() == .authorized else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.threadIdentifier = "import"
        try? await UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "import-\(UUID().uuidString)", content: content, trigger: nil))
    }

    public func beginBackgroundWork() -> Int {
        #if os(iOS)
        UIApplication.shared.beginBackgroundTask(withName: "Import flights").rawValue
        #else
        0
        #endif
    }

    public func endBackgroundWork(_ token: Int) {
        #if os(iOS)
        UIApplication.shared.endBackgroundTask(UIBackgroundTaskIdentifier(rawValue: token))
        #endif
    }
}
