#if os(macOS)
import AppKit
import SwiftUI
import Testing
@testable import FlightKit

/// Settings as the phone shows it, signed in with a profile, the App Icon picker and every row, dark and light,
/// into docs/screens/screens/settings-<scheme>.png; then its Notifications page and the signed-out head.
///
///     SNAPSHOTS=1 swift test --package-path Packages/FlightKit --filter settingsScreens
extension ComponentSnapshotTests {
    @MainActor @Test func settingsScreens() async throws {
        let session = SettingsPreview.makeSession(signedIn: true, failDelete: false)
        let profile = ProfileStore(service: FakeProfileService(.apple))
        await profile.prepare(owner: FakeProfileService.userId)
        let icons = AppIconModel(setter: AppIconsTests.FakeSetter("AppIcon-supersonic"))
        let notifications = NotificationSettingsStore(service: FakeNotificationPreferencesService(NotificationPreferences()))
        notifications.seed(NotificationPreferences(), error: nil)
        let signedOut = SettingsPreview.makeSession(signedIn: false, failDelete: false)
        for light in [false, true] {
            let scheme = light ? "light" : "dark"
            try render("settings-\(scheme)", to: Self.screensDir, light: light) {
                SettingsView(session: session, units: .constant(Units()), history: FakeHistoryService(),
                             onDeleteAccount: { true }, notifications: notifications, profile: profile,
                             scrolls: false, dataNote: false, iconModel: icons)
            }
            try render("settings-notifications-\(scheme)", to: Self.screensDir, light: light) {
                NotificationSettingsView(store: notifications, onDone: nil, scrolls: false)
            }
            try render("settings-signed-out-\(scheme)", to: Self.screensDir, light: light) {
                SettingsHero(session: nil, profile: nil, onSignIn: {}).padding(.vertical, 24)
            }
        }
    }
}
#endif
