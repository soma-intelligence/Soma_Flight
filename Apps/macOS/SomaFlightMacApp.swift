import FlightKit
import SwiftUI

/// Quits with the last window: the globe window is the app, and Settings alone has nothing to act on.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct SomaFlightMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var home: HomeModel?
    @State private var failure: String?
    /// Bumped by Try Again, which builds the environment again.
    @State private var attempt = 0
    @StoredUnits private var units: Units

    var body: some Scene {
        // One window: the panel's navigation and the session belong to the one home.
        Window("Soma Flight", id: "main") {
            Group {
                if let home {
                    RootSidebarView(home: home)
                } else {
                    LaunchPlaceholder(failure: failure, showsProgress: true) { failure = nil; attempt += 1 }
                }
            }
            .frame(minWidth: RootSidebarView.minimumSize.width, minHeight: RootSidebarView.minimumSize.height)
            .preferredColorScheme(.dark)
            .task(id: attempt) {
                guard home == nil else { return }
                do {
                    // Built off the main thread: the SwiftData cache opens its store on creation.
                    // `-useFakes` on the command line runs on the seeded fakes with an in-memory cache.
                    home = HomeModel(env: try await AppEnvironment.forLaunch())
                } catch {
                    failure = LaunchPlaceholder.storageFailure
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
                    // Export arrives with Task 12.
                    SettingsView(session: home.session, units: $units,
                                 onDeleteAccount: { Task { await home.session.deleteAccount() } })
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
}
