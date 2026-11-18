import Foundation
import Observation
import UserNotifications

public enum NotificationPermission: Sendable, Equatable {
    case notDetermined, denied, authorized
}

/// The system's notification permission, behind a protocol for tests.
public protocol NotificationAuthorizer: Sendable {
    func status() async -> NotificationPermission
    /// Shows the system prompt; true when the user allowed alerts.
    func request() async -> Bool
}

public struct SystemNotificationAuthorizer: NotificationAuthorizer {
    public init() {}

    public func status() async -> NotificationPermission {
        switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
        case .notDetermined: .notDetermined
        case .denied: .denied
        case .authorized, .provisional, .ephemeral: .authorized
        @unknown default: .denied
        }
    }

    public func request() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }
}

/// Permission and token registration. The prompt comes after the user's first follow, never at launch;
/// a denial leaves follows working. The alert token is registered every launch while allowed (tokens
/// rotate) and again after each sign-in (the server moves a token to the account signed in now).
@MainActor @Observable
public final class PushCoordinator {
    /// What the system allows, as last read (E5): nil until read, `.denied` when the user turned alerts off
    /// in Settings. The bell, the Notifications screen and its switches read it (through
    /// `HomeModel.notificationPermission`) so the app never says alerts are on when the system drops them.
    /// Read again at launch, after a follow and when the app comes back to the foreground (`refreshPermission()`).
    public private(set) var permission: NotificationPermission?

    /// True when the system drops this app's alerts: the screens show alerts as off and point to Settings.
    public var isDenied: Bool { permission == .denied }

    @ObservationIgnored private let push: any PushService
    @ObservationIgnored private let authorizer: any NotificationAuthorizer
    @ObservationIgnored private let registerForRemote: @MainActor () -> Void
    @ObservationIgnored private let enabled: Bool
    @ObservationIgnored private var owner: UUID?
    @ObservationIgnored private var hasAccount = false
    @ObservationIgnored private var lastRegistered: Data?

    /// - Parameter registerForRemote: asks the OS for a device token (`registerForRemoteNotifications`);
    ///   the token comes back through the app delegate and `PushInbox`.
    /// - Parameter enabled: false skips the prompt and the token. The default is iOS only: the backend
    ///   sends no pushes to the Mac yet (`SupabasePushService.register` is a no-op there), so asking
    ///   Mac users to allow alerts would promise something that never comes.
    ///   TODO: enable on macOS together with the backend's Mac delivery.
    public init(push: any PushService, authorizer: any NotificationAuthorizer = SystemNotificationAuthorizer(),
                enabled: Bool = PushCoordinator.platformSendsPushes,
                registerForRemote: @escaping @MainActor () -> Void) {
        self.push = push; self.authorizer = authorizer; self.enabled = enabled
        self.registerForRemote = registerForRemote
    }

    public static var platformSendsPushes: Bool {
        #if os(iOS)
        true
        #else
        false
        #endif
    }

    /// At launch: ask for a token only when alerts are already allowed. Never shows the prompt.
    public func refresh() async {
        guard enabled else { return }
        if await refreshPermission() == .authorized { registerForRemote() }
    }

    /// Reads the system's permission again (the user may have changed it in Settings) and returns it.
    /// Never shows the prompt. Platforms without pushes report nil.
    @discardableResult
    public func refreshPermission() async -> NotificationPermission? {
        guard enabled else { return nil }
        let now = await authorizer.status()
        if permission != now { permission = now }
        return now
    }

    /// After a follow went through: the first one shows the prompt. Later ones only make sure a token is
    /// registered.
    public func didFollow() async {
        guard enabled else { return }
        switch await refreshPermission() ?? .notDetermined {
        case .notDetermined:
            let allowed = await authorizer.request()
            permission = allowed ? .authorized : .denied
            if allowed { registerForRemote() }
        case .authorized:
            registerForRemote()
        case .denied:
            break
        }
    }

    /// A different account (or the first one) forgets what was registered, so the account now signed in
    /// gets the token.
    public func accountChanged(owner now: UUID?) {
        if !hasAccount || now != owner { lastRegistered = nil }
        hasAccount = true
        owner = now
    }

    /// Registers `token` as an alert token once per account. `HomeModel` only calls it when the backend's
    /// account is signed in; a failure is tried again at the next launch or sign-in.
    public func register(token: Data) async {
        guard token != lastRegistered else { return }
        do {
            try await push.register(deviceToken: token, kind: .alert, flightId: nil)
            lastRegistered = token
        } catch {
            // Tried again at the next launch or sign-in.
        }
    }
}
