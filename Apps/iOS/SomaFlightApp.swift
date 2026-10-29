import FlightKit
import SwiftUI

@main
struct SomaFlightApp: App {
    @State private var env: AppEnvironment?
    @State private var failure: String?

    /// `-useFakes` on the command line runs on the seeded fakes with an in-memory cache.
    static var useFakes: Bool { ProcessInfo.processInfo.arguments.contains("-useFakes") }

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
                    env = Self.useFakes ? try await AppEnvironment.fake() : try await AppEnvironment.live()
                } catch {
                    failure = "Soma Flight could not open its storage. Restart the app to try again."
                }
            }
        }
    }
}

/// What shows for the moment the environment takes to build.
private struct LaunchPlaceholder: View {
    var failure: String?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let failure {
                Text(failure)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(32)
            }
        }
    }
}
