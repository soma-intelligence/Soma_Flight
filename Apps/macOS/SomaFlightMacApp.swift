import FlightKit
import SwiftUI
import UserNotifications

/// Quits with the last window: the globe window is the app, and Settings alone has nothing to act on.
/// It also receives the notification callbacks and leaves them in `inbox` for the home, which is built
/// after the delegate (a tap that launched the app is not lost).
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    let inbox = PushInbox()

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Set before launch finishes, so a notification that launched the app reaches the delegate.
    func applicationWillFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
    }

    func application(_ application: NSApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        inbox.receive(deviceToken: deviceToken)
    }

    func application(_ application: NSApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) {
        // Debug builds carry no push entitlement (no provisioning profile); the Mac gets no pushes from the
        // backend yet either, so there is nothing to retry.
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        if let payload = PushPayload(userInfo: notification.request.content.userInfo) {
            await inbox.receiveForeground(payload)
        }
        return [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
              let payload = PushPayload(userInfo: response.notification.request.content.userInfo) else { return }
        await inbox.receiveTap(payload)
    }
}

@main
struct SomaFlightMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var home: HomeModel?
    @State private var failure: String?
    /// A sign-in link opened before the home was built, handed over once it is.
    @State private var pendingURL: URL?
    /// Bumped by Try Again, which builds the environment again.
    @State private var attempt = 0
    @StoredUnits private var units: Units

    var body: some Scene {
        // One window: the panel's navigation and the session belong to the one home.
        Window("Soma Flight", id: "main") {
            Group {
                if let home {
                    SignInGate(home: home, showsProgress: true) { RootSidebarView(home: home) }
                        .environment(\.brandAssets, home.env.brand)
                        .environment(\.leaveTimes, home.leaveTimes)
                } else {
                    LaunchPlaceholder(failure: failure, showsProgress: true) { failure = nil; attempt += 1 }
                }
            }
            .frame(minWidth: RootSidebarView.minimumSize.width, minHeight: RootSidebarView.minimumSize.height)
            .onOpenURL { url in
                // A calendar event's `somaflight://flight/<id>` opens that flight the way a tapped notification does.
                if let id = FlightLink.flightID(from: url) {
                    appDelegate.inbox.receiveTap(PushPayload(flightId: id))
                } else if let home {
                    Task { await Self.open(url, in: home) }
                } else {
                    pendingURL = url
                }
            }
            .preferredColorScheme(.dark)
            .task(id: attempt) {
                guard home == nil else { return }
                do {
                    // Built off the main thread: the SwiftData cache opens its store on creation.
                    // `-useFakes` on the command line runs on the seeded fakes with an in-memory cache.
                    let built = HomeModel(env: try await AppEnvironment.forLaunch())
                    built.attachPush(inbox: appDelegate.inbox) { NSApplication.shared.registerForRemoteNotifications() }
                    // The flight sheet's "Leave by" time and Settings > Calendar.
                    built.attachLeaveTimes(LeaveTimeEstimator.forLaunch(env: built.env))
                    built.attachCalendar(CalendarSync.forLaunch(env: built.env))
                    home = built
                    if let url = pendingURL {
                        pendingURL = nil
                        await Self.open(url, in: built)
                    }
                } catch {
                    failure = LaunchPlaceholder.failure(for: error)
                }
            }
        }
        .defaultSize(RootSidebarView.defaultSize)
        // The globe window is the app: it opens at every launch, even if it was closed at the last quit.
        .defaultLaunchBehavior(.presented)
        .windowToolbarStyle(.unifiedCompact(showsTitle: false))

        Settings {
            Group {
                if let home {
                    // Export only once there is someone to export for (signed in, or the fakes).
                    SettingsView(session: home.session, units: $units, history: home.needsSignIn ? nil : home.env.history,
                                 onDeleteAccount: { await home.session.deleteAccount() },
                                 notifications: home.needsSignIn ? nil : home.notificationSettings,
                                 calendar: home.needsSignIn ? nil : home.calendar,
                                 friends: home.needsSignIn ? nil : home.friends)
                } else {
                    // Settings opened before the window has built its environment.
                    LaunchPlaceholder(failure: failure, showsProgress: true)
                }
            }
            .frame(width: 480, height: 640)
            .environment(\.units, units)
            .preferredColorScheme(.dark)
        }
    }

    /// A URL the system opened the app with: a boarding pass (Open With, or a file dropped on the Dock
    /// icon) goes to the pass import, anything else is a sign-in link.
    @MainActor static func open(_ url: URL, in home: HomeModel) async {
        if await home.handleInvite(url: url) { return }
        if PassFile.isPassFile(url) {
            await home.importPass(from: url)
        } else {
            await home.session.handle(url: url)
        }
    }
}
