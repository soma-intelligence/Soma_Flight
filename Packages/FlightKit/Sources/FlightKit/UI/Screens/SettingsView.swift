import SwiftUI

/// Account, units, alerts, privacy, data export, account deletion and about, as a grouped list
/// of icon rows. Export and deletion are wired in Task 12.
public struct SettingsView: View {
    var session: SessionStore
    @Binding var units: Units
    var scrolls: Bool

    @Environment(\.openURL) private var openURL

    public init(session: SessionStore, units: Binding<Units>) {
        self.init(session: session, units: units, scrolls: true)
    }

    init(session: SessionStore, units: Binding<Units>, scrolls: Bool) {
        self.session = session; self._units = units; self.scrolls = scrolls
    }

    static let privacyURL = URL(string: "https://somalabs.me/privacy")!
    static let supportURL = URL(string: "https://somalabs.me/support")!

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScreenTitle("Settings")
                .padding(.horizontal, Theme.gutter)
                .padding(.top, 22)
                .padding(.bottom, 16)
            ScreenScroll(scrolls: scrolls) { content }
        }
        .background(Theme.background)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let error = session.error {
                ErrorBanner(error: error)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
            }
            AccountRow(session: session.session)
            Hairline()

            group("Units") {
                SettingsRow(icon: "ruler", title: "Distance") {
                    PillPicker(options: [(DistanceUnit.km, "Kilometers"), (.mi, "Miles")], selection: $units.distance)
                }
                SettingsRow(icon: "clock.fill", title: "Time", last: true) {
                    PillPicker(options: [(TimeStyle.h24, "24-Hour"), (.h12, "12-Hour")], selection: $units.clock)
                }
            }
            group("Alerts") {
                SettingsRow(icon: "bell.badge.fill", title: "Notifications", subtitle: "Gate changes, delays, take-off and landing",
                            last: true, action: openNotificationSettings) { RowChevron() }
            }
            group("Privacy") {
                SettingsRow(icon: "hand.raised.fill", title: "Privacy Policy", action: { openURL(Self.privacyURL) }) { RowChevron() }
                SettingsRow(icon: "lock.shield.fill", title: "What We Keep",
                            subtitle: "Flights you follow and your flight history, nothing else", last: true) { EmptyView() }
            }
            group("Your Data") {
                SettingsRow(icon: "curlybraces", title: "Export History as JSON", action: {}) { RowChevron() }
                SettingsRow(icon: "tablecells.fill", title: "Export History as CSV", last: true, action: {}) { RowChevron() }
            }
            group("Account") {
                if session.session != nil {
                    SettingsRow(icon: "rectangle.portrait.and.arrow.right", title: "Sign Out",
                                action: { Task { await session.signOut() } }) { EmptyView() }
                }
                SettingsRow(icon: "trash.fill", title: "Delete Account", tint: Theme.veryLate, last: true, action: {}) {
                    EmptyView()
                }
            }
            group("About") {
                SettingsRow(icon: "questionmark.circle.fill", title: "Help and Feedback", action: { openURL(Self.supportURL) }) {
                    RowChevron()
                }
                SettingsRow(icon: "info.circle.fill", title: "Soma Flight", last: true) {
                    Text(Self.version).scaledFont(17).foregroundStyle(Theme.secondary)
                }
            }
        }
        .padding(.bottom, 32)
    }

    private static var version: String {
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let b = info?["CFBundleVersion"] as? String
        return b.map { "\(v) (\($0))" } ?? v
    }

    private func group<C: View>(_ title: String, @ViewBuilder _ rows: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            CapsHeader(title)
                .padding(.horizontal, 16)
                .padding(.top, 34)
                .padding(.bottom, 8)
            Hairline().padding(.horizontal, 16)
            rows()
            Hairline().padding(.horizontal, 16)
        }
    }

    private func openNotificationSettings() {
        #if os(iOS)
        if let url = URL(string: UIApplication.openNotificationSettingsURLString) { openURL(url) }
        #else
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") { openURL(url) }
        #endif
    }
}

// MARK: - Rows

/// Plan badge and the signed-in account.
struct AccountRow: View {
    var session: UserSession?

    var body: some View {
        HStack(spacing: 14) {
            let pro = session?.plan == .pro
            Text(pro ? "PRO" : "FREE")
                .scaledFont(13, weight: .bold)
                .foregroundStyle(Theme.diverted)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.diverted.opacity(0.18)))
            VStack(alignment: .leading, spacing: 2) {
                Text(pro ? "Soma Flight Pro" : "Soma Flight Free")
                    .scaledFont(19, weight: .semibold)
                    .foregroundStyle(Theme.diverted)
                Text(detail)
                    .scaledFont(15)
                    .foregroundStyle(Theme.diverted.opacity(0.75))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 18)
        .accessibilityElement(children: .combine)
    }

    private var detail: String {
        guard let session else { return "Not signed in" }
        return session.email ?? "Signed in with Apple"
    }
}

/// Icon, title (and optional grey line), trailing accessory; a hairline under it from the title.
struct SettingsRow<Accessory: View>: View {
    var icon: String
    var title: String
    var subtitle: String?
    var tint: Color = Theme.primary
    var last = false
    var action: (() -> Void)?
    @ViewBuilder var accessory: Accessory

    var body: some View {
        VStack(spacing: 0) {
            if let action {
                Button(action: action) { row.contentShape(Rectangle()) }.buttonStyle(.plain)
            } else {
                row
            }
            if !last { Hairline().padding(.leading, 60).padding(.trailing, 16) }
        }
    }

    private var row: some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .scaledFont(18, weight: .medium)
                .foregroundStyle(tint)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).scaledFont(17).foregroundStyle(tint)
                if let subtitle {
                    Text(subtitle).scaledFont(13).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            accessory
        }
        .padding(.leading, 16)
        .padding(.trailing, 16)
        .frame(minHeight: 60)
        .padding(.vertical, subtitle == nil ? 0 : 6)
    }
}

// MARK: - Previews

struct SettingsPreview: View {
    var plan: Plan? = .free
    var failDelete = false
    @State private var units = Units()
    @State private var session: SessionStore?

    var body: some View {
        Group {
            if let session {
                SettingsView(session: session, units: $units)
            } else {
                ProgressView()
            }
        }
        .task { session = await Self.makeSession(plan: plan, failDelete: failDelete) }
    }

    static func makeSession(plan: Plan?, failDelete: Bool) async -> SessionStore {
        let auth = FakeAuthService(plan: plan ?? .free)
        let s = SessionStore(auth: auth)
        s.start()
        if plan != nil { try? await auth.signInWithEmail("quentin@somalabs.me") }
        if failDelete {
            await auth.setNextError(.providerUnavailable)
            await s.deleteAccount()
        }
        var tries = 0
        while (s.session == nil) == (plan != nil), tries < 200 { await Task.yield(); tries += 1 }
        return s
    }
}

#Preview("Free, dark") { SettingsPreview().preferredColorScheme(.dark) }
#Preview("Pro, light") { SettingsPreview(plan: .pro).preferredColorScheme(.light) }
#Preview("Signed out") { SettingsPreview(plan: nil).preferredColorScheme(.dark) }
#Preview("Delete failed") { SettingsPreview(failDelete: true).preferredColorScheme(.dark) }
