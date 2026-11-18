import SwiftUI

/// Settings > Notifications: which alerts the account gets, one switch per category, saved to the
/// backend (`notification_preferences`). The flight alerts come from the server; Reminders are
/// scheduled on this device. The system's own switch (allowed or not) stays in the OS settings, linked
/// at the bottom.
public struct NotificationSettingsView: View {
    var store: NotificationSettingsStore
    var onDone: (() -> Void)?
    var scrolls: Bool
    /// The permission to show, for previews and snapshots; nil reads the system's (E5).
    var fixedPermission: NotificationPermission?

    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @State private var permission: NotificationPermission?

    /// - Parameters:
    ///   - onDone: shows a Done button in the header row; nil leaves it out.
    ///   - permission: the system permission to show; nil reads it from the system (and again when the app
    ///     comes back from Settings).
    public init(store: NotificationSettingsStore, onDone: (() -> Void)? = nil, permission: NotificationPermission? = nil) {
        self.init(store: store, onDone: onDone, scrolls: true)
        self.fixedPermission = permission
    }

    init(store: NotificationSettingsStore, onDone: (() -> Void)?, scrolls: Bool) {
        self.store = store; self.onDone = onDone; self.scrolls = scrolls
    }

    /// Notifications are off for the app in the system settings: the switches can't do anything yet (E5).
    private var denied: Bool { (fixedPermission ?? permission) == .denied }

    /// The switches show the account's real choices: loaded and allowed (E5, E11).
    private var switchesLive: Bool { store.hasPreferences && !denied }

    static let deniedTitle = "Notifications Are Off"
    static let deniedText = "Allow notifications for Soma Flight in Settings to get the alerts you pick here."

    static let alertCategories: [NotificationPreferences.Category] = [
        .delays, .gates, .takeoffLanding, .boarding, .aircraft, .baggage, .cancellations,
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
        .task { if !store.hasPreferences { await store.load() } }
        .task { await readPermission() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await readPermission() } } }
    }

    /// Reads the system permission without prompting. Skipped outside an app bundle (tests, snapshots).
    private func readPermission() async {
        guard fixedPermission == nil, Bundle.main.bundleURL.pathExtension == "app" else { return }
        permission = await SystemNotificationAuthorizer().status()
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            if denied {
                // Same card as Calendar's denied access: what is off and the way to Settings (E5).
                SettingsSection {
                    SettingsRow(icon: "bell.slash.fill", title: Self.deniedTitle, subtitle: Self.deniedText,
                                tone: .neutral, last: true, action: openSystemSettings) {
                        Text("Open Settings")
                            .scaledFont(15, weight: .semibold)
                            .foregroundStyle(Theme.accentText)
                            .fixedSize()
                    }
                }
                .scaledPadding(.bottom, 12)
            }
            if store.loadFailed, let error = store.error {
                // The switches show defaults, not the account's choices, until a load works (E11).
                ErrorBanner(error: error, hasContent: false, retry: { Task { await store.retry() } })
                    .scaledPadding(.horizontal, 16)
                    .scaledPadding(.bottom, 12)
            } else if let error = store.error {
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
            group("Airports", [.favoriteAirports])
            if let texts = store.texts { TextMeTooSection(store: texts) }
            deviceSection
            Text("Reminders are set on this device: check-in opens a day before, a summary at 7:00 on the morning of the flight, and a nudge to leave, timed from where you are when you allow your location, else 3 hours before an international flight or 2 before a domestic one.")
                .scaledFont(13)
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .scaledPadding(.horizontal, 32)
                .scaledPadding(.top, 7)
            Text(NotificationSettingsView.landmarksNote)
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

    static let landmarksTitle = "Landmarks Overflown"
    static let landmarksDetail = "Mountains, cities and lakes passing the plane"
    static let landmarksNote: LocalizedStringKey = "Landmark alerts are planned before take-off from the schedule, so they come even in airplane mode. They stay off until you turn them on."

    /// Reminders (saved to the account like the alerts) and the landmark alerts' switch, kept on this
    /// device and off by default.
    private var deviceSection: some View {
        SettingsSection("On This Device") {
            reminderRow(.reminders, last: false)
            SettingsRow(icon: "mountain.2.fill", title: Self.landmarksTitle, subtitle: Self.landmarksDetail, last: true) {
                Toggle(Self.landmarksTitle, isOn: Binding(get: { store.landmarkAlerts },
                                                         set: { store.setLandmarkAlerts($0) }))
                    .labelsHidden()
                    .tint(Theme.accent)
                    .disabled(denied)
            }
            .opacity(denied ? 0.45 : 1)
            .accessibilityElement(children: .combine)
        }
    }

    private func group(_ title: String, _ categories: [NotificationPreferences.Category]) -> some View {
        SettingsSection(title) {
            ForEach(categories) { c in reminderRow(c, last: c == categories.last) }
        }
    }

    private func reminderRow(_ c: NotificationPreferences.Category, last: Bool) -> some View {
        SettingsRow(icon: c.icon, title: c.title, subtitle: c.detail, last: last) {
            Toggle(c.title, isOn: Binding(get: { store.preferences[c] },
                                          set: { on in Task { await store.set(c, on) } }))
                .labelsHidden()
                .tint(Theme.accent)
                .disabled(!switchesLive)
        }
        // Dimmed while the switches are not the account's real choices (denied, or not loaded).
        .opacity(switchesLive ? 1 : 0.45)
        .accessibilityElement(children: .combine)
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
    var denied = false
    @State private var store: NotificationSettingsStore?

    var body: some View {
        Group {
            if let store {
                NotificationSettingsView(store: store, onDone: {}, permission: denied ? .denied : .authorized)
            } else { ProgressView() }
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
#Preview("Notifications, denied") {
    NotificationSettingsPreview(denied: true).preferredColorScheme(.dark)
}
#endif
