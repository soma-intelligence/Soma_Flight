import SwiftUI

/// Account, units, alerts, privacy, data export, account deletion and about, as a grouped list
/// of icon rows. A row whose action the shell has not supplied is not drawn, so nothing taps to
/// no effect: export and account deletion appear once Task 12 passes their closures.
public struct SettingsView: View {
    var session: SessionStore
    @Binding var units: Units
    var onSignIn: (() -> Void)?
    var onExport: ((ExportFormat) -> Void)?
    var onDeleteAccount: (() -> Void)?
    var scrolls: Bool

    @Environment(\.openURL) private var openURL
    @State private var confirming: Confirmation?

    private enum Confirmation: Identifiable {
        case signOut, deleteAccount
        var id: Self { self }
    }

    /// - Parameters:
    ///   - onSignIn: shows the sign-in screen from the signed-out account row; nil hides the button.
    ///   - onExport: starts a history export in the chosen format; nil hides the export rows.
    ///   - onDeleteAccount: runs after the user confirms deleting the account; nil hides the row.
    public init(session: SessionStore, units: Binding<Units>, onSignIn: (() -> Void)? = nil,
                onExport: ((ExportFormat) -> Void)? = nil, onDeleteAccount: (() -> Void)? = nil) {
        self.init(session: session, units: units, onSignIn: onSignIn, onExport: onExport,
                  onDeleteAccount: onDeleteAccount, scrolls: true)
    }

    init(session: SessionStore, units: Binding<Units>, onSignIn: (() -> Void)? = nil,
         onExport: ((ExportFormat) -> Void)? = nil, onDeleteAccount: (() -> Void)? = nil, scrolls: Bool) {
        self.session = session; self._units = units; self.onSignIn = onSignIn; self.onExport = onExport
        self.onDeleteAccount = onDeleteAccount; self.scrolls = scrolls
    }

    static let privacyURL = URL(string: "https://somalabs.me/privacy")!
    static let supportURL = URL(string: "https://somalabs.me/support")!

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScreenTitle("Settings")
                .scaledPadding(.horizontal, Theme.gutter)
                .scaledPadding(.top, 22)
                .scaledPadding(.bottom, 16)
            ScreenScroll(scrolls: scrolls) { content }
        }
        .background(Theme.background)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let error = session.error {
                ErrorBanner(error: error)
                    .scaledPadding(.horizontal, 16)
                    .scaledPadding(.bottom, 12)
            }
            AccountRow(session: session.session, onSignIn: onSignIn)
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
            if let onExport {
                group("Your Data") {
                    SettingsRow(icon: "curlybraces", title: "Export History as JSON", action: { onExport(.json) }) { RowChevron() }
                    SettingsRow(icon: "tablecells.fill", title: "Export History as CSV", last: true,
                                action: { onExport(.csv) }) { RowChevron() }
                }
            }
            if session.session != nil || onDeleteAccount != nil {
                group("Account") {
                    if session.session != nil {
                        SettingsRow(icon: "rectangle.portrait.and.arrow.right", title: "Sign Out",
                                    last: onDeleteAccount == nil, action: { confirming = .signOut }) { EmptyView() }
                    }
                    if onDeleteAccount != nil {
                        SettingsRow(icon: "trash.fill", title: "Delete Account", tint: Theme.veryLate, last: true,
                                    action: { confirming = .deleteAccount }) { EmptyView() }
                    }
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
        .scaledPadding(.bottom, 32)
        .confirmationDialog(confirming == .deleteAccount ? "Delete your account?" : "Sign out?",
                            isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
                            titleVisibility: .visible, presenting: confirming) { action in
            switch action {
            case .signOut:
                Button("Sign Out", role: .destructive) { Task { await session.signOut() } }
            case .deleteAccount:
                Button("Delete Account", role: .destructive) { onDeleteAccount?() }
            }
            Button("Cancel", role: .cancel) {}
        } message: { action in
            switch action {
            case .signOut: Text("Flights you follow stay on your account. The saved copy on this device is cleared.")
            case .deleteAccount: Text("This removes your account, the flights you follow and your history. It can't be undone.")
            }
        }
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
                .scaledPadding(.horizontal, 16)
                .scaledPadding(.top, 34)
                .scaledPadding(.bottom, 8)
            Hairline().scaledPadding(.horizontal, 16)
            rows()
            Hairline().scaledPadding(.horizontal, 16)
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
    var onSignIn: (() -> Void)?

    var body: some View {
        HStack(spacing: 14) {
            let pro = session?.plan == .pro
            if session != nil {
                Text(pro ? "PRO" : "FREE")
                    .scaledFont(13, weight: .bold)
                    .foregroundStyle(Theme.diverted)
                    .scaledPadding(.horizontal, 7)
                    .scaledPadding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.diverted.opacity(0.18)))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(session == nil ? "Not signed in" : pro ? "Soma Flight Pro" : "Soma Flight Free")
                    .scaledFont(19, weight: .semibold)
                    .foregroundStyle(Theme.diverted)
                Text(detail)
                    .scaledFont(15)
                    .foregroundStyle(Theme.diverted.opacity(0.75))
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            if session == nil, let onSignIn {
                Button("Sign In", action: onSignIn)
                    .scaledFont(15, weight: .semibold)
                    .foregroundStyle(.white)
                    .scaledPadding(.horizontal, 14)
                    .scaledPadding(.vertical, 8)
                    .background(Capsule().fill(Theme.accent))
                    .buttonStyle(.plain)
            }
        }
        .scaledPadding(.horizontal, 16)
        .scaledPadding(.vertical, 18)
        .accessibilityElement(children: .combine)
    }

    private var detail: String {
        guard let session else { return "Sign in to keep your flights on every device" }
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
            if !last { Hairline().scaledPadding(.leading, 60).scaledPadding(.trailing, 16) }
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
        .scaledPadding(.leading, 16)
        .scaledPadding(.trailing, 16)
        .frame(minHeight: 60)
        .padding(.vertical, subtitle == nil ? 0 : 6)
    }
}

#if DEBUG
// MARK: - Previews

struct SettingsPreview: View {
    var plan: Plan? = .free
    var failDelete = false
    var full = false
    @State private var units = Units()
    @State private var session: SessionStore?

    var body: some View {
        Group {
            if let session {
                if full {
                    SettingsView(session: session, units: $units, onSignIn: {}, onExport: { _ in }, onDeleteAccount: {})
                } else {
                    SettingsView(session: session, units: $units, onSignIn: {})
                }
            } else {
                ProgressView()
            }
        }
        .task { session = Self.makeSession(plan: plan, failDelete: failDelete) }
    }

    @MainActor static func makeSession(plan: Plan?, failDelete: Bool) -> SessionStore {
        let s = SessionStore(auth: FakeAuthService(plan: plan ?? .free))
        let user = plan.map { UserSession(userId: UUID(uuidString: "5a1e0000-0000-4000-8000-000000000001")!,
                                           email: "quentin@somalabs.me", plan: $0) }
        s.seed(session: user, error: failDelete ? .providerUnavailable : nil)
        return s
    }
}

#Preview("Free, dark") { SettingsPreview().preferredColorScheme(.dark) }
#Preview("Pro, light, all rows") { SettingsPreview(plan: .pro, full: true).preferredColorScheme(.light) }
#Preview("Signed out") { SettingsPreview(plan: nil).preferredColorScheme(.dark) }
#Preview("Delete failed") { SettingsPreview(failDelete: true, full: true).preferredColorScheme(.dark) }
#endif
