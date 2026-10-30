import FlightKit
import SwiftUI

@main
struct SomaFlightApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var home: HomeModel?
    @State private var failure: String?
    /// A sign-in link opened before the home was built, handed over once it is.
    @State private var pendingURL: URL?

    /// Live Activities run on the backend. Screenshot runs (`-useFakes`) leave the lock screen alone,
    /// unless the Debug-only `-startLiveActivity YES` asks for one (the fake flight in the air).
    private static var wantsLiveActivity: Bool {
        guard ProcessInfo.processInfo.arguments.contains("-useFakes") else { return true }
        #if DEBUG
        return UserDefaults.standard.bool(forKey: "startLiveActivity")
        #else
        return false
        #endif
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if let home {
                    SignInGate(home: home) { RootTabView(home: home) }
                        .environment(\.brandAssets, home.env.brand)
                } else {
                    LaunchPlaceholder(failure: failure)
                }
            }
            .onOpenURL { url in
                // A widget's `somaflight://flight/<id>` opens that flight the way a tapped notification does:
                // it waits in the inbox until the home is built and someone is signed in.
                if let id = FlightLink.flightID(from: url) {
                    appDelegate.inbox.receiveTap(PushPayload(flightId: id))
                } else if let home {
                    Task { await home.session.handle(url: url) }
                } else {
                    pendingURL = url
                }
            }
            .task {
                guard home == nil else { return }
                do {
                    // Built off the main thread: the SwiftData cache opens its store on creation.
                    // `-useFakes` on the command line runs on the seeded fakes with an in-memory cache.
                    let built = HomeModel(env: try await AppEnvironment.forLaunch())
                    built.attachPush(inbox: appDelegate.inbox) { UIApplication.shared.registerForRemoteNotifications() }
                    // The home screen and lock screen widgets read My Flights from the App Group.
                    built.attachWidgets(WidgetSnapshotWriter(lookup: built.env.lookup))
                    if Self.wantsLiveActivity {
                        built.attachLiveActivities(FlightActivityController(
                            host: SystemFlightActivityHost(), push: built.env.push, lookup: built.env.lookup))
                    }
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
    }
}
