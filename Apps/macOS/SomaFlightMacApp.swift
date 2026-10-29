import FlightKit
import SwiftUI

@main
struct SomaFlightMacApp: App {
    @State private var home: HomeModel?
    @State private var failure: String?
    @StoredUnits private var units: Units

    var body: some Scene {
        // One window: the panel's navigation and the session belong to the one home.
        Window("Soma Flight", id: "main") {
            Group {
                if let home {
                    RootSidebarView(home: home)
                } else {
                    LaunchPlaceholder(failure: failure)
                }
            }
            .frame(minWidth: RootSidebarView.minimumSize.width, minHeight: RootSidebarView.minimumSize.height)
            .preferredColorScheme(.dark)
            .task {
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
                    LaunchPlaceholder(failure: failure)
                }
            }
            .frame(width: 480, height: 640)
            .environment(\.units, units)
            .preferredColorScheme(.dark)
        }
    }
}
