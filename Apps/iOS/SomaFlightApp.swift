import FlightKit
import SwiftUI

@main
struct SomaFlightApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var home: HomeModel?
    @State private var failure: String?
    /// A sign-in link opened before the home was built, handed over once it is.
    @State private var pendingURL: URL?

    var body: some Scene {
        WindowGroup {
            Group {
                if let home {
                    SignInGate(home: home) { RootTabView(home: home) }
                } else {
                    LaunchPlaceholder(failure: failure)
                }
            }
            .onOpenURL { url in
                if let home { Task { await home.session.handle(url: url) } } else { pendingURL = url }
            }
            .task {
                guard home == nil else { return }
                do {
                    // Built off the main thread: the SwiftData cache opens its store on creation.
                    // `-useFakes` on the command line runs on the seeded fakes with an in-memory cache.
                    let built = HomeModel(env: try await AppEnvironment.forLaunch())
                    built.attachPush(inbox: appDelegate.inbox) { UIApplication.shared.registerForRemoteNotifications() }
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
