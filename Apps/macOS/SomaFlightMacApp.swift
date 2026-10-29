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
                } else {
                    LaunchPlaceholder(failure: failure, showsProgress: true) { failure = nil; attempt += 1 }
                }
            }
            .frame(minWidth: RootSidebarView.minimumSize.width, minHeight: RootSidebarView.minimumSize.height)
            .onOpenURL { url in
                if let home { Task { await home.session.handle(url: url) } } else { pendingURL = url }
            }
            .preferredColorScheme(.dark)
            .task(id: attempt) {
                guard home == nil else { return }
                do {
                    // Built off the main thread: the SwiftData cache opens its store on creation.
                    // `-useFakes` on the command line runs on the seeded fakes with an in-memory cache.
                    let built = HomeModel(env: try await AppEnvironment.forLaunch())
                    home = built
                    if let url = pendingURL {
                        pendingURL = nil
                        await built.session.handle(url: url)
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
