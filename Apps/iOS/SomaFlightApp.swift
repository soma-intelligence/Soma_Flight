import FlightKit
import SwiftUI

@main
struct SomaFlightApp: App {
    @State private var env: AppEnvironment?
    @State private var failure: String?

    var body: some Scene {
        WindowGroup {
            Group {
                if let env {
                    RootTabView(env: env)
                } else {
                    LaunchPlaceholder(failure: failure)
                }
            }
            .task {
                guard env == nil else { return }
                do {
                    // Built off the main thread: the SwiftData cache opens its store on creation.
                    // `-useFakes` on the command line runs on the seeded fakes with an in-memory cache.
                    env = try await AppEnvironment.forLaunch()
                } catch {
                    failure = LaunchPlaceholder.storageFailure
                }
            }
        }
    }
}
