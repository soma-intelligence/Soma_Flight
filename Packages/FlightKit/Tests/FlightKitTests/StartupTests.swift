import Foundation
import Testing
@testable import FlightKit

/// The notification settings call never answers (as seen on simulators).
private struct SilentAuthorizer: NotificationAuthorizer {
    func status() async -> NotificationPermission {
        try? await Task.sleep(for: .seconds(3600))
        return .denied
    }
    func request() async -> Bool { false }
}

@MainActor private final class Flag { var on = false }

/// App start must never wait on the notification settings.
@MainActor @Suite struct StartupTests {
    @Test func startDoesNotWaitOnNotificationSettings() async throws {
        let home = HomeModel(env: try await AppEnvironment.fake())
        let inbox = PushInbox()
        // Enabled on every platform, so the coordinator really asks the silent authorizer.
        home.attachPush(inbox: inbox, authorizer: SilentAuthorizer(), enabled: true) {}
        await home.load()
        let flight = try #require(home.followed.first)
        // A tap that launched the app is still opened by start.
        inbox.receiveTap(["flightId": flight.id.uuidString])
        let done = Flag()
        let start = Task { await home.start(); done.on = true }
        for _ in 0..<500 where !done.on { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(done.on)
        #expect(home.shell.path == [.flight(flight.id)])
        start.cancel()
    }
}
