import SwiftUI

/// Settings > Notifications: which alerts the account gets, one switch per category, saved to the
/// backend (`notification_preferences`). The flight alerts come from the server; Reminders are
/// scheduled on this device. The system's own switch (allowed or not) stays in the OS settings, linked
/// at the bottom.
public struct NotificationSettingsView: View {
    var store: NotificationSettingsStore
    var onDone: (() -> Void)?
    var scrolls: Bool

    @Environment(\.openURL) private var openURL

    /// - Parameter onDone: shows a Done button in the header row; nil leaves it out.
    public init(store: NotificationSettingsStore, onDone: (() -> Void)? = nil) {
        self.init(store: store, onDone: onDone, scrolls: true)
    }

    init(store: NotificationSettingsStore, onDone: (() -> Void)?, scrolls: Bool) {
        self.store = store; self.onDone = onDone; self.scrolls = scrolls
    }

    static let alertCategories: [NotificationPreferences.Category] = [
        .delays, .gates, .takeoffLanding, .baggage, .cancellations,
    ]

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let onDone {
                HStack {
                    Spacer()
                    Button("Done", action: onDone)
                        .scaledFont(17, weight: .semibold)
                        .foregroundStyle(Theme.accent)
                        .buttonStyle(.plain)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .scaledPadding(.horizontal, Theme.gutter)
                .scaledPadding(.top, 8)
            }
            ScreenTitle("Notifications")
                .scaledPadding(.horizontal, Theme.gutter)
                .scaledPadding(.top, onDone == nil ? 22 : 0)
                .scaledPadding(.bottom, 16)
            ScreenScroll(scrolls: scrolls) { content }
        }
        .background(Theme.background)
        .task { if !store.hasLoaded { await store.load() } }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let error = store.error {
                ErrorBanner(error: error)
                    .scaledPadding(.horizontal, 16)
                    .scaledPadding(.bottom, 12)
            }
            Text("Choose what Soma Flight tells you about the flights you follow. Each switch counts for every flight on your account.")
                .scaledFont(15)
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .scaledPadding(.horizontal, 16)
            group("Flight Alerts", Self.alertCategories)
            if let texts = store.texts { TextMeTooSection(store: texts) }
            group("On This Device", [.reminders])
            Text("Reminders are set on this device: check-in opens a day before, a summary at 7:00 on the morning of the flight, and a nudge to leave, timed from where you are when you allow your location, else 3 hours before an international flight or 2 before a domestic one.")
                .scaledFont(13)
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .scaledPadding(.horizontal, 32)
                .scaledPadding(.top, 7)
            SettingsSection {
                SettingsRow(icon: "gearshape.fill", title: "System Notification Settings",
                            subtitle: "Allow notifications, sounds and the Lock Screen", tone: .neutral, last: true,
                            action: openSystemSettings) { RowChevron() }
            }
        }
        .scaledPadding(.bottom, 32)
    }

    private func group(_ title: String, _ categories: [NotificationPreferences.Category]) -> some View {
        SettingsSection(title) {
            ForEach(categories) { c in
                SettingsRow(icon: c.icon, title: c.title, subtitle: c.detail, last: c == categories.last) {
                    Toggle(c.title, isOn: Binding(get: { store.preferences[c] },
                                                  set: { on in Task { await store.set(c, on) } }))
                        .labelsHidden()
                        .tint(Theme.accent)
                        .disabled(!store.hasLoaded)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func openSystemSettings() {
        #if os(iOS)
        if let url = URL(string: UIApplication.openNotificationSettingsURLString) { openURL(url) }
        #else
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") { openURL(url) }
        #endif
    }
}

#if DEBUG
// MARK: - Previews

struct NotificationSettingsPreview: View {
    var preferences = NotificationPreferences(baggage: false)
    var error: APIError?
    @State private var store: NotificationSettingsStore?

    var body: some View {
        Group {
            if let store { NotificationSettingsView(store: store, onDone: {}) } else { ProgressView() }
        }
        .task {
            let s = NotificationSettingsStore(service: FakeNotificationPreferencesService(preferences))
            s.seed(preferences, error: error)
            store = s
        }
    }
}

#Preview("Notifications, dark") { NotificationSettingsPreview().preferredColorScheme(.dark) }
#Preview("Notifications, light, error") {
    NotificationSettingsPreview(error: .offline).preferredColorScheme(.light)
}
#endif
