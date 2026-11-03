import SwiftUI

/// Account, units, alerts, privacy, data export, account deletion and about, as a grouped list
/// of icon rows. A row whose action the shell has not supplied is not drawn, so nothing taps to
/// no effect.
public struct SettingsView: View {
    var session: SessionStore
    @Binding var units: Units
    var onSignIn: (() -> Void)?
    var history: (any HistoryService)?
    /// Deletes the account; its argument is the Apple authorization code for an Apple account, else nil.
    var onDeleteAccount: ((String?) async -> Bool)?
    /// The Notifications screen's store; nil keeps the row opening the system settings.
    var notifications: NotificationSettingsStore?
    /// The Calendar screen's sync; nil hides its row.
    var calendar: CalendarSync?
    /// The name and emoji friends see (Account); nil hides the rows.
    var friends: FriendsStore?
    /// The name and photo (Profile); it replaces the plain name field when set.
    var profile: ProfileStore?
    var scrolls: Bool
    /// The closing data note of the Mac settings page.
    var dataNote: Bool
    var onClose: (() -> Void)?
    /// The App Icon picker's model; the phone builds its own on the system setting, snapshots pass a fake.
    var iconModel: AppIconModel?

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
    @State private var showingDocuments = false
    #if os(iOS)
    /// The app icon in use on the phone.
    @State private var systemIcon = AppIconModel(setter: SystemAppIconSetting())
    #endif
    /// The travel documents vault; nil hides its row.
    @Environment(\.travelDocuments) private var documents
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
    ///   - friends: the Friends store (`HomeModel.friends`); Account then holds the name and emoji friends see.
    ///   - profile: the user's name and photo (`HomeModel.profile`); Profile then shows them and opens the editor.
    ///   - onClose: closes Settings from the round X at the top right (the phone's sheet); nil leaves it out.
    public init(session: SessionStore, units: Binding<Units>, onSignIn: (() -> Void)? = nil,
                history: (any HistoryService)? = nil, onDeleteAccount: ((String?) async -> Bool)? = nil,
                notifications: NotificationSettingsStore? = nil, calendar: CalendarSync? = nil,
                friends: FriendsStore? = nil, profile: ProfileStore? = nil, onClose: (() -> Void)? = nil) {
        self.init(session: session, units: units, onSignIn: onSignIn, history: history,
                  onDeleteAccount: onDeleteAccount, notifications: notifications, calendar: calendar, friends: friends,
                  profile: profile, scrolls: true, onClose: onClose)
    }

    init(session: SessionStore, units: Binding<Units>, onSignIn: (() -> Void)? = nil,
         history: (any HistoryService)? = nil, onDeleteAccount: ((String?) async -> Bool)? = nil,
         notifications: NotificationSettingsStore? = nil, calendar: CalendarSync? = nil, friends: FriendsStore? = nil,
         profile: ProfileStore? = nil,
         scrolls: Bool, dataNote: Bool = SettingsView.defaultDataNote, onClose: (() -> Void)? = nil,
         iconModel: AppIconModel? = nil) {
        self.session = session; self._units = units; self.onSignIn = onSignIn; self.history = history
        self.friends = friends; self.profile = profile
        self.onDeleteAccount = onDeleteAccount; self.notifications = notifications; self.calendar = calendar
        self.scrolls = scrolls; self.dataNote = dataNote; self.onClose = onClose; self.iconModel = iconModel
    }

    /// The App Icon picker's model: the one passed in, else the phone's own; nil (the Mac) hides the picker.
    private var appIcon: AppIconModel? {
        #if os(iOS)
        iconModel ?? systemIcon
        #else
        iconModel
        #endif
    }

    static let privacyURL = URL(string: "https://somalabs.me/legal/soma-flight-privacy")!
    static let supportURL = URL(string: "https://somalabs.me/support")!

    public var body: some View {
        #if os(iOS)
        // On the phone Notifications, Calendar and Acknowledgements slide up over the list as cards inside
        // the Settings sheet, as the home's screens do, rather than stacking a second sheet over it. Their
        // X sits where the sheet's own does and drops the card back down.
        CardStack(path: openPages, onPop: closePage) {
            list.overlay(alignment: .topTrailing) {
                if let onClose { CloseButton(action: onClose) }
            }
        } card: { page in
            PushedPage(onClose: closePage) { pageView(page) }
        }
        #else
        list
        #endif
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            if onClose != nil {
                // The sheet's bar: the title centred on the line of the round X, as OnePass sets Settings.
                Text("Settings")
                    .scaledFont(17, weight: .semibold, relativeTo: .headline)
                    .foregroundStyle(Theme.primary)
                    .accessibilityAddTraits(.isHeader)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 44)
                    .scaledPadding(.top, 16)
                    .scaledPadding(.horizontal, 64)
                    .scaledPadding(.bottom, 6)
            } else {
                ScreenTitle("Settings")
                    .scaledPadding(.horizontal, Theme.gutter)
                    .scaledPadding(.top, 22)
                    .scaledPadding(.bottom, 16)
            }
            ScreenScroll(scrolls: scrolls) { content }
        }
        .background(Theme.background)
    }

    #if os(iOS)
    /// A page of Settings opened over the list.
    enum Page: Hashable { case notifications, calendar, documents, acknowledgements }

    /// The page on show, as a card stack's path (one page at most).
    var openPages: [Page] {
        if showingNotifications { [.notifications] }
        else if showingCalendar { [.calendar] }
        else if showingDocuments { [.documents] }
        else if showingAcknowledgements { [.acknowledgements] }
        else { [] }
    }

    private func closePage() {
        showingNotifications = false; showingCalendar = false; showingDocuments = false
        showingAcknowledgements = false
    }

    @ViewBuilder private func pageView(_ page: Page) -> some View {
        switch page {
        case .notifications: if let notifications { NotificationSettingsView(store: notifications) }
        case .calendar: if let calendar { CalendarSettingsView(sync: calendar) }
        case .documents: if let documents { TravelDocumentsView(store: documents) }
        case .acknowledgements: AcknowledgementsView()
        }
    }
    #endif

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let error = session.error {
                ErrorBanner(error: error)
                    .scaledPadding(.horizontal, 16)
                    .scaledPadding(.bottom, 12)
            }
            SettingsHero(session: session.session, profile: profile, onSignIn: onSignIn)

            if let appIcon {
                SettingsSection("App Icon") {
                    AppIconPicker(model: appIcon, scrolls: scrolls)
                }
            }
            if profile?.owner == nil, let friends {
                SettingsSection("Profile", footer: "Only friends see your name and emoji.") { ProfileRows(store: friends) }
            }
            SettingsSection("Units") {
                SettingsRow(icon: "ruler.fill", title: "Distance", tint: SettingsStyle.teal) {
                    PillPicker(options: [(DistanceUnit.km, "Kilometers"), (.mi, "Miles")], selection: $units.distance)
                }
                SettingsRow(icon: "clock.fill", title: "Time", tint: SettingsStyle.indigo, last: true) {
                    PillPicker(options: [(TimeStyle.h24, "24-Hour"), (.h12, "12-Hour")], selection: $units.clock)
                }
            }
            SettingsSection("Alerts and Travel") {
                SettingsRow(icon: "bell.badge.fill", title: "Notifications",
                            subtitle: notifications == nil ? "Gate changes, delays, take-off and landing"
                                : "Delays, gates, take-off and landing, bags, reminders", tint: SettingsStyle.red,
                            action: notifications == nil ? openNotificationSettings : { showingNotifications = true }) {
                    RowChevron()
                }
                if calendar != nil {
                    SettingsRow(icon: "calendar", title: "Calendar", subtitle: "Put followed flights in your calendar",
                                tint: SettingsStyle.orange,
                                action: { showingCalendar = true }) { RowChevron() }
                }
                if documents != nil {
                    SettingsRow(icon: "person.text.rectangle.fill", title: "Travel Documents",
                                subtitle: "Loyalty, passport and trusted traveler numbers, on this device only",
                                tint: SettingsStyle.blue,
                                action: { showingDocuments = true }) { RowChevron() }
                }
                SettingsRow(icon: "checkmark.shield.fill", title: "I Have TSA PreCheck",
                            subtitle: "Leave times count the PreCheck lane", tint: SettingsStyle.green, last: true) {
                    Toggle("I Have TSA PreCheck", isOn: $precheck).labelsHidden().tint(Theme.accent)
                }
                .accessibilityElement(children: .combine)
            }
            if let history {
                SettingsSection("Your Data", footer: "Exports are built on this device.") {
                    ExportRow(icon: "curlybraces", title: "Export History as JSON", tint: SettingsStyle.slate, format: .json,
                              history: history)
                    ExportRow(icon: "tablecells.fill", title: "Export History as CSV", tint: SettingsStyle.green, format: .csv,
                              history: history, last: true)
                }
            }
            if session.session != nil {
                SettingsSection("Account") {
                    SettingsRow(icon: "rectangle.portrait.and.arrow.right", title: "Sign Out", tone: .neutral,
                                last: onDeleteAccount == nil, action: { confirming = .signOut }) { EmptyView() }
                    if onDeleteAccount != nil, session.session != nil {
                        SettingsRow(icon: "trash.fill", title: "Delete Account", tone: .destructive, last: true,
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
            SettingsSection("Privacy and Support",
                            footer: "We keep your email, name and photo, the flights you follow and your flight history.") {
                SettingsRow(icon: "hand.raised.fill", title: "Privacy Policy", tone: .neutral, tint: SettingsStyle.blue,
                            action: { openURL(Self.privacyURL) }) { RowLink() }
                SettingsRow(icon: "questionmark.circle.fill", title: "Help and Feedback", tone: .neutral, tint: SettingsStyle.purple,
                            action: { openURL(Self.supportURL) }) { RowLink() }
                SettingsRow(icon: "doc.text.fill", title: "Acknowledgements", tone: .neutral, last: true,
                            action: { showingAcknowledgements = true }) { RowChevron() }
            }
            VStack(spacing: 2) {
                Text("Soma Flight is open source (AGPL-3.0)")
                Text("Version \(Self.version)")
            }
            .scaledFont(13)
            .foregroundStyle(Theme.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .scaledPadding(.top, 16)
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
        #if !os(iOS)
        // The phone opens them as cards over the list instead (`body`).
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
        .sheet(isPresented: $showingDocuments) {
            if let documents {
                TravelDocumentsView(store: documents, onDone: { showingDocuments = false })
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
    /// stays signed in and the error shows in an alert (and in the banner on top). An Apple account first
    /// signs in with Apple again, so the server can revoke its Apple tokens; cancelling that stops here.
    private func deleteAccount() {
        guard let onDeleteAccount, !deleting else { return }
        deleting = true
        Task {
            var appleCode: String?
            if session.session?.usesApple == true {
                switch await AppleReauthorization.request() {
                case .code(let code): appleCode = code
                case .cancelled:
                    deleting = false
                    return
                case .failed:
                    deleting = false
                    deleteFailure = .rejected("Sign in with Apple didn't finish. Try again.")
                    return
                }
            }
            let deleted = await onDeleteAccount(appleCode)
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

    private func openNotificationSettings() {
        #if os(iOS)
        if let url = URL(string: UIApplication.openNotificationSettingsURLString) { openURL(url) }
        #else
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") { openURL(url) }
        #endif
    }
}

// MARK: - Rows

/// Who is signed in, as the head of Settings, the way OnePass opens its own: a card with the photo, the name
/// and the account's email, and a chevron when the row opens something (the profile editor, or Sign In when
/// signed out). Without a profile the email alone, and nothing to open.
struct SettingsHero: View {
    var session: UserSession?
    var profile: ProfileStore?
    var onSignIn: (() -> Void)?
    @State private var editing = false
    @Environment(\.metricsScale) private var scale

    var body: some View {
        let editable = session != nil && profile?.owner != nil
        let name = editable ? (profile?.displayName ?? "") : ""
        let action: (() -> Void)? = editable ? { editing = true } : (session == nil ? onSignIn : nil)
        Group {
            if let action {
                Button(action: action) { card(name: name, opens: true) }
                    .buttonStyle(SettingsRowStyle())
                    .accessibilityHint(editable ? "Edit your name and photo" : "Sign in")
            } else {
                card(name: name, opens: false)
            }
        }
        .background(RoundedRectangle(cornerRadius: SettingsStyle.radius, style: .continuous).fill(Theme.card))
        .clipShape(RoundedRectangle(cornerRadius: SettingsStyle.radius, style: .continuous))
        .scaledPadding(.horizontal, 16)
        .scaledPadding(.top, 4)
        .sheet(isPresented: $editing) {
            if let profile {
                ProfileOnboardingView(store: profile, mode: .edit) { editing = false }
                    .presentationBackground(Theme.background)
                    #if os(macOS)
                    .frame(minWidth: 420, minHeight: 560)
                    #endif
            }
        }
    }

    private func card(name: String, opens: Bool) -> some View {
        HStack(spacing: 14) {
            UserAvatar(photo: session != nil && profile?.owner != nil ? profile?.photo : nil,
                       name: name.isEmpty ? nil : name, id: profile?.owner ?? session?.userId,
                       size: Theme.metric(56, scale))
                .overlay(Circle().strokeBorder(Theme.primary.opacity(0.06), lineWidth: 1))
            VStack(alignment: .leading, spacing: 2) {
                Text(title(name))
                    .scaledFont(20, weight: .semibold, relativeTo: .title3)
                    .foregroundStyle(Theme.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(detail)
                    .scaledFont(15)
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if opens { RowChevron() }
        }
        .multilineTextAlignment(.leading)
        .scaledPadding(.horizontal, 16)
        .scaledPadding(.vertical, 12)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private func title(_ name: String) -> String {
        guard let session else { return "Not Signed In" }
        if !name.isEmpty { return name }
        return session.email ?? "Signed In"
    }

    private var detail: String {
        guard let session else { return "Sign in to keep your flights on every device." }
        if profile?.owner != nil, !(profile?.displayName ?? "").isEmpty { return Self.detail(session) }
        if profile?.owner != nil { return "Add your name and photo" }
        return session.email == nil ? "Signed in with Apple" : "Signed in"
    }

    /// The line under the name: the account's email, or how it signed in when Apple hid the email.
    static func detail(_ session: UserSession) -> String { session.email ?? "Signed in with Apple" }
}

/// A row's tile, as OnePass sets its Settings: a white symbol on a rounded square of the row's hue, lit from
/// above by the hue's own gradient, with a hairline of white around it.
struct SettingsTile: View {
    var symbol: String
    var color: Color
    @Environment(\.metricsScale) private var scale

    var body: some View {
        let side = Theme.metric(SettingsStyle.iconSide, scale)
        let shape = RoundedRectangle(cornerRadius: Theme.metric(SettingsStyle.iconRadius, scale), style: .continuous)
        shape
            .fill(color.gradient)
            .overlay { shape.strokeBorder(.white.opacity(0.18), lineWidth: 0.5) }
            .frame(width: side, height: side)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: side * 0.52, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.12), radius: 0.5, y: 0.5)
            }
            .accessibilityHidden(true)
    }
}

/// A titled group of rows on a rounded card, inset from the screen's edges, with an optional grey note under it
/// (the inset grouped look of the system's own settings).
struct SettingsSection<Content: View>: View {
    var title: String?
    var footer: String?
    @ViewBuilder var content: Content

    init(_ title: String? = nil, footer: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title; self.footer = footer; self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title {
                Text(title.uppercased())
                    .scaledFont(13)
                    .tracking(0.2)
                    .foregroundStyle(Theme.secondary)
                    .scaledPadding(.horizontal, 32)
                    .scaledPadding(.bottom, 7)
                    .accessibilityAddTraits(.isHeader)
            }
            VStack(spacing: 0) { content }
                .background(RoundedRectangle(cornerRadius: SettingsStyle.radius, style: .continuous).fill(Theme.card))
                .clipShape(RoundedRectangle(cornerRadius: SettingsStyle.radius, style: .continuous))
                .scaledPadding(.horizontal, 16)
            if let footer {
                Text(footer)
                    .scaledFont(13)
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .scaledPadding(.horizontal, 32)
                    .scaledPadding(.top, 7)
            }
        }
        .scaledPadding(.top, 28)
    }
}

/// Settings' shared measures and its tile palette, after OnePass's Settings: each row wears a tile of its
/// own hue, graphite for the account and the plain links, red for deleting.
enum SettingsStyle {
    /// The inset grouped card's corner, as the system's own settings cards turn.
    static let radius: CGFloat = 26
    static let iconSide: CGFloat = 29
    /// The tile's corner: 27 percent of its side.
    static let iconRadius: CGFloat = iconSide * 0.27
    /// Where a row's text starts, so the separators between rows start there too.
    static let textInset: CGFloat = 16 + iconSide + 14
    static let graphite = Color(light: 0x8A8C94, dark: 0x8A8C94)
    static let blue = Color(light: 0x3378F5, dark: 0x3378F5)
    static let teal = Color(light: 0x008CB3, dark: 0x008CB3)
    static let indigo = Color(light: 0x5957D6, dark: 0x5957D6)
    static let purple = Color(light: 0x7D3BED, dark: 0x7D3BED)
    static let green = Color(light: 0x21A16B, dark: 0x21A16B)
    static let orange = Color(light: 0xE09400, dark: 0xE09400)
    static let red = Color(light: 0xE5372C, dark: 0xE5372C)
    static let slate = Color(light: 0x475569, dark: 0x475569)
}

/// A history export row: opens the share sheet with `soma-flight-history-YYYY-MM-DD.<ext>`, built on
/// the device when the sheet asks for it.
struct ExportRow: View {
    var icon: String
    var title: String
    var tint: Color?
    var format: ExportFormat
    var history: any HistoryService
    var last = false

    var body: some View {
        ShareLink(item: HistoryExport(format: format, history: history),
                  preview: SharePreview(HistoryExport.fileName(for: format, on: .now))) {
            SettingsRow(icon: icon, title: title, tint: tint, last: last) { RowChevron() }
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
                Text("Your email, your name and photo, the flights you follow and your flight history. Your location stays on this device. No contacts, no tracking. Exports are built on this device.")
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

/// One row of a Settings card: a white glyph in a tinted rounded square, the title (and an optional grey
/// line), the trailing accessory; a separator under it from the title on, except on the last row.
struct SettingsRow<Accessory: View>: View {
    /// The square's colour: blue for the app's features, graphite for account and support, red for deleting.
    enum Tone { case feature, neutral, destructive }

    var icon: String
    var title: String
    var subtitle: String?
    var tone: Tone = .feature
    /// The tile's own hue; nil takes the tone's.
    var tint: Color?
    var last = false
    var action: (() -> Void)?
    @ViewBuilder var accessory: Accessory
    @Environment(\.metricsScale) private var scale

    var body: some View {
        VStack(spacing: 0) {
            if let action {
                Button(action: action) { row.contentShape(Rectangle()) }.buttonStyle(SettingsRowStyle())
            } else {
                row
            }
            if !last {
                Rectangle().fill(Theme.separator).frame(height: 0.5)
                    .padding(.leading, Theme.metric(SettingsStyle.textInset, scale))
            }
        }
    }

    private var fill: Color {
        if let tint { return tint }
        return switch tone {
        case .feature: Theme.accent
        case .neutral: SettingsStyle.graphite
        case .destructive: Theme.veryLate
        }
    }

    private var row: some View {
        HStack(spacing: 14) {
            SettingsTile(symbol: icon, color: fill)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).scaledFont(17).foregroundStyle(tone == .destructive ? Theme.veryLate : Theme.primary)
                if let subtitle {
                    Text(subtitle).scaledFont(13).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            accessory
        }
        .scaledPadding(.horizontal, 16)
        .frame(minHeight: subtitle == nil ? 52 : 60)
        .padding(.vertical, subtitle == nil ? 0 : 8)
    }
}

/// A row pressed: the card darkens under the finger, as the system's lists do.
struct SettingsRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Theme.primary.opacity(0.08) : .clear)
    }
}

/// The arrow at the end of a row that leaves the app for a web page.
struct RowLink: View {
    var body: some View {
        Image(systemName: "arrow.up.right")
            .scaledFont(13, weight: .semibold)
            .foregroundStyle(Theme.secondary.opacity(0.7))
            .accessibilityHidden(true)
    }
}

#if DEBUG
// MARK: - Previews

struct SettingsPreview: View {
    var signedIn = true
    var failDelete = false
    var full = false
    @State private var units = Units()
    @State private var session: SessionStore?

    var body: some View {
        Group {
            if let session {
                if full {
                    SettingsView(session: session, units: $units, onSignIn: {}, history: FakeHistoryService(),
                                 onDeleteAccount: { _ in true })
                } else {
                    SettingsView(session: session, units: $units, onSignIn: {})
                }
            } else {
                ProgressView()
            }
        }
        .task { session = Self.makeSession(signedIn: signedIn, failDelete: failDelete) }
    }

    @MainActor static func makeSession(signedIn: Bool, failDelete: Bool) -> SessionStore {
        let s = SessionStore(auth: FakeAuthService())
        let user = signedIn ? UserSession(userId: UUID(uuidString: "5a1e0000-0000-4000-8000-000000000001")!,
                                          email: "quentin@somalabs.me") : nil
        s.seed(session: user, error: failDelete ? .providerUnavailable : nil)
        return s
    }
}

#Preview("Signed in, dark") { SettingsPreview().preferredColorScheme(.dark) }
#Preview("Signed in, light, all rows") { SettingsPreview(full: true).preferredColorScheme(.light) }
#Preview("Signed out") { SettingsPreview(signedIn: false).preferredColorScheme(.dark) }
#Preview("Delete failed") { SettingsPreview(failDelete: true, full: true).preferredColorScheme(.dark) }
#endif

#if os(iOS)
/// A page of Settings as a card over the list (`CardStack`): the sheet's background and the round X at
/// the top right, where the sheet's own sits, which drops the card back to the list.
struct PushedPage<Content: View>: View {
    var onClose: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .overlay(alignment: .topTrailing) { CloseButton(action: onClose) }
            .background(Theme.background)
    }
}
#endif
