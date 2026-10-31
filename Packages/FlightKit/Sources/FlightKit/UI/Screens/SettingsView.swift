import SwiftUI

/// Account, units, alerts, privacy, data export, account deletion and about, as a grouped list
/// of icon rows. A row whose action the shell has not supplied is not drawn, so nothing taps to
/// no effect.
public struct SettingsView: View {
    var session: SessionStore
    @Binding var units: Units
    var onSignIn: (() -> Void)?
    var history: (any HistoryService)?
    var onDeleteAccount: (() async -> Bool)?
    /// The Notifications screen's store; nil keeps the row opening the system settings.
    var notifications: NotificationSettingsStore?
    /// The Calendar screen's sync; nil hides its row.
    var calendar: CalendarSync?
    var scrolls: Bool
    /// The closing data note of the Mac settings page.
    var dataNote: Bool

    #if os(macOS)
    static let defaultDataNote = true
    #else
    static let defaultDataNote = false
    #endif

    @Environment(\.openURL) private var openURL
    @State private var confirming: Confirmation?
    @State private var deleting = false
    @State private var showingAcknowledgements = false
    @State private var showingNotifications = false
    @State private var showingCalendar = false
    /// Which security lane the leave time counts (`LeaveTimeSettings`).
    @AppStorage(LeaveTimeSettings.precheckKey) private var precheck = false
    /// The deletion failed and the account is still signed in.
    @State private var deleteFailure: APIError?

    private enum Confirmation: Identifiable {
        case signOut, deleteAccount
        var id: Self { self }
    }

    /// The deletion dialog's copy.
    static let deleteTitle = "Delete your account?"
    static let deleteMessage = "Your followed flights and flight history will be removed. This can't be undone."

    /// - Parameters:
    ///   - onSignIn: shows the sign-in screen from the signed-out account row; nil hides the button.
    ///   - history: where the JSON and CSV exports are read from, built on the device and handed to the
    ///     share sheet; nil hides the export rows.
    ///   - onDeleteAccount: runs after the user confirms deleting the account (`SessionStore.deleteAccount()`);
    ///     nil hides the row. When it returns false, the session's error is shown.
    ///   - notifications: the alert categories (`HomeModel.notificationSettings`); the Notifications row
    ///     opens its screen. Nil keeps the row opening the system settings.
    ///   - calendar: the calendar sync (`HomeModel.calendar`); the Calendar row opens its screen. Nil hides the row.
    public init(session: SessionStore, units: Binding<Units>, onSignIn: (() -> Void)? = nil,
                history: (any HistoryService)? = nil, onDeleteAccount: (() async -> Bool)? = nil,
                notifications: NotificationSettingsStore? = nil, calendar: CalendarSync? = nil) {
        self.init(session: session, units: units, onSignIn: onSignIn, history: history,
                  onDeleteAccount: onDeleteAccount, notifications: notifications, calendar: calendar, scrolls: true)
    }

    init(session: SessionStore, units: Binding<Units>, onSignIn: (() -> Void)? = nil,
         history: (any HistoryService)? = nil, onDeleteAccount: (() async -> Bool)? = nil,
         notifications: NotificationSettingsStore? = nil, calendar: CalendarSync? = nil, scrolls: Bool,
         dataNote: Bool = SettingsView.defaultDataNote) {
        self.session = session; self._units = units; self.onSignIn = onSignIn; self.history = history
        self.onDeleteAccount = onDeleteAccount; self.notifications = notifications; self.calendar = calendar
        self.scrolls = scrolls; self.dataNote = dataNote
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
                SettingsRow(icon: "bell.badge.fill", title: "Notifications",
                            subtitle: notifications == nil ? "Gate changes, delays, take-off and landing"
                                : "Delays, gates, take-off and landing, bags, reminders",
                            last: true, action: notifications == nil ? openNotificationSettings : { showingNotifications = true }) {
                    RowChevron()
                }
            }
            group("Travel") {
                if calendar != nil {
                    SettingsRow(icon: "calendar", title: "Calendar", subtitle: "Put followed flights in your calendar",
                                action: { showingCalendar = true }) { RowChevron() }
                }
                SettingsRow(icon: "person.badge.shield.checkmark", title: "I Have TSA PreCheck",
                            subtitle: "Leave times count the PreCheck lane", last: true) {
                    Toggle("I Have TSA PreCheck", isOn: $precheck).labelsHidden().tint(Theme.accent)
                }
                .accessibilityElement(children: .combine)
            }
            group("Privacy") {
                SettingsRow(icon: "hand.raised.fill", title: "Privacy Policy", action: { openURL(Self.privacyURL) }) { RowChevron() }
                SettingsRow(icon: "lock.shield.fill", title: "What We Keep",
                            subtitle: "Flights you follow and your flight history, nothing else", last: true) { EmptyView() }
            }
            if let history {
                group("Your Data") {
                    ExportRow(icon: "curlybraces", title: "Export History as JSON", format: .json, history: history)
                    ExportRow(icon: "tablecells.fill", title: "Export History as CSV", format: .csv, history: history, last: true)
                }
            }
            if session.session != nil {
                group("Account") {
                    SettingsRow(icon: "rectangle.portrait.and.arrow.right", title: "Sign Out",
                                last: onDeleteAccount == nil, action: { confirming = .signOut }) { EmptyView() }
                    if onDeleteAccount != nil, session.session != nil {
                        SettingsRow(icon: "trash.fill", title: "Delete Account", tint: Theme.veryLate, last: true,
                                    action: deleting ? nil : { confirming = .deleteAccount }) {
                            if deleting {
                                ProgressView().controlSize(.small)
                                    .accessibilityLabel("Deleting account")
                                    .accessibilityAddTraits(.updatesFrequently)
                            }
                        }
                    }
                }
            }
            group("About") {
                SettingsRow(icon: "questionmark.circle.fill", title: "Help and Feedback", action: { openURL(Self.supportURL) }) {
                    RowChevron()
                }
                SettingsRow(icon: "doc.text.fill", title: "Acknowledgements", action: { showingAcknowledgements = true }) {
                    RowChevron()
                }
                SettingsRow(icon: "info.circle.fill", title: "Soma Flight", last: true) {
                    Text(Self.version).scaledFont(17).foregroundStyle(Theme.secondary)
                }
            }
            if dataNote {
                MinimalDataNote()
                    .scaledPadding(.horizontal, 16)
                    .scaledPadding(.top, 28)
            }
        }
        .scaledPadding(.bottom, 32)
        .confirmationDialog(confirming == .deleteAccount ? Self.deleteTitle : "Sign out?",
                            isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
                            titleVisibility: .visible, presenting: confirming) { action in
            switch action {
            case .signOut:
                Button("Sign Out", role: .destructive) { Task { await session.signOut() } }
            case .deleteAccount:
                Button("Delete Account", role: .destructive) { deleteAccount() }
            }
            Button("Cancel", role: .cancel) {}
        } message: { action in
            switch action {
            case .signOut: Text("Flights you follow stay on your account. The saved copy on this device is cleared.")
            case .deleteAccount: Text(Self.deleteMessage)
            }
        }
        #if os(iOS)
        // On the phone the two pages slide in inside the Settings sheet (its NavigationStack), with a round
        // back button, rather than stacking a second sheet over it.
        .navigationDestination(isPresented: $showingAcknowledgements) {
            PushedPage { AcknowledgementsView() }
        }
        .navigationDestination(isPresented: $showingNotifications) {
            if let notifications { PushedPage { NotificationSettingsView(store: notifications) } }
        }
        .navigationDestination(isPresented: $showingCalendar) {
            if let calendar { PushedPage { CalendarSettingsView(sync: calendar) } }
        }
        #else
        .sheet(isPresented: $showingAcknowledgements) {
            AcknowledgementsView(onDone: { showingAcknowledgements = false })
                .frame(minWidth: 420, minHeight: 520)
        }
        .sheet(isPresented: $showingNotifications) {
            if let notifications {
                NotificationSettingsView(store: notifications, onDone: { showingNotifications = false })
                    .frame(minWidth: 420, minHeight: 560)
            }
        }
        .sheet(isPresented: $showingCalendar) {
            if let calendar {
                CalendarSettingsView(sync: calendar, onDone: { showingCalendar = false })
                    .frame(minWidth: 420, minHeight: 560)
            }
        }
        #endif
        .alert("Couldn't Delete Your Account", isPresented: Binding(get: { deleteFailure != nil },
                                                                   set: { if !$0 { deleteFailure = nil } }),
               presenting: deleteFailure) { _ in
            Button("OK", role: .cancel) {}
        } message: { error in
            Text("\(error.message) You're still signed in.")
        }
    }

    /// Runs the deletion; on success the session ends and the shells show Sign In, on failure the account
    /// stays signed in and the error shows in an alert (and in the banner on top).
    private func deleteAccount() {
        guard let onDeleteAccount, !deleting else { return }
        deleting = true
        Task {
            let deleted = await onDeleteAccount()
            deleting = false
            if !deleted { deleteFailure = session.error ?? .providerUnavailable }
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

/// A history export row: opens the share sheet with `soma-flight-history-YYYY-MM-DD.<ext>`, built on
/// the device when the sheet asks for it.
struct ExportRow: View {
    var icon: String
    var title: String
    var format: ExportFormat
    var history: any HistoryService
    var last = false

    var body: some View {
        ShareLink(item: HistoryExport(format: format, history: history),
                  preview: SharePreview(HistoryExport.fileName(for: format, on: .now))) {
            SettingsRow(icon: icon, title: title, last: last) { RowChevron() }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityHint("Opens the share sheet")
    }
}

/// The Mac settings page's closing note, a green card like the reference's data note.
struct MinimalDataNote: View {
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "checkmark.shield.fill")
                .scaledFont(20, weight: .medium)
                .foregroundStyle(Theme.onTime)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("Soma Flight keeps minimal data")
                    .scaledFont(15, weight: .semibold)
                    .foregroundStyle(Theme.onTime)
                Text("Your email, the flights you follow and your flight history. No location, no contacts, no tracking. Exports are built on this device.")
                    .scaledFont(14)
                    .foregroundStyle(Theme.primary.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .scaledPadding(.all, 14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.onTime.opacity(0.14)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.onTime.opacity(0.25), lineWidth: 1))
        .accessibilityElement(children: .combine)
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
                    SettingsView(session: session, units: $units, onSignIn: {}, history: FakeHistoryService(),
                                 onDeleteAccount: { true })
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

#if os(iOS)
/// A page pushed inside a sheet: no navigation bar, a round back button at the top left, the sheet's
/// background, and the edge swipe back.
struct PushedPage<Content: View>: View {
    @ViewBuilder var content: Content
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        content
            .scaledPadding(.top, 44)
            .overlay(alignment: .topLeading) {
                RoundButton(systemImage: "chevron.left", label: "Back") { dismiss() }
                    .scaledPadding(.leading, 16)
                    .scaledPadding(.top, 8)
            }
            .background(Theme.background)
            .toolbar(.hidden, for: .navigationBar)
    }
}
#endif
