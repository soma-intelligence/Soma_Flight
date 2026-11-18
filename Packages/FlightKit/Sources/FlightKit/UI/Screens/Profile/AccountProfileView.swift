import SwiftUI
#if canImport(LocalAuthentication)
import LocalAuthentication
#endif

/// Settings > account row: the Profil (refined 2026-11-17, R5 and R6). The modal header, the avatar, the name
/// and how the account signs in, then flat cards under small caps labels. Account: name and photo, email,
/// account ID (copied on a tap) and how fresh the followed flights are. Security: the sign-in method and the
/// Travel Documents lock and sync. Then the privacy policy and signing out, and deleting the account on its
/// own card. Only what the app knows is shown; a row without its data is left out. Nothing is changed on the
/// page itself (each row opens what changes it), so the header has no Done.
struct AccountProfileView: View {
    var session: UserSession
    var profile: ProfileStore?
    var flights: MyFlightsStore?
    /// The X of the modal header; nil leaves the header out.
    var onClose: (() -> Void)?
    var onDocuments: (() -> Void)?
    var onSignOut: () -> Void
    var onDeleteAccount: (() -> Void)?
    var deleting = false
    var scrolls = true

    @Environment(\.travelDocuments) private var documents
    @Environment(\.openURL) private var openURL
    @Environment(\.metricsScale) private var scale
    @State private var editing = false
    /// The ID row says "copied" for a moment after a tap.
    @State private var idCopied = false

    /// The line under Delete Account.
    static let deleteNote = "Removes your account and its flights from every device."

    private var name: String {
        guard let profile, profile.owner != nil else { return "" }
        let _ = profile.revision
        return profile.displayName
    }

    private var email: String? { session.email ?? profile?.identity?.email }

    private var method: String? {
        ProfileFacts.signInMethod(provider: profile?.identity?.provider, usesApple: session.usesApple)
    }

    var body: some View {
        VStack(spacing: 0) {
            if let onClose {
                SheetHeader(.modal(title: "Profile", leading: .close(onClose)))
                    .scaledPadding(.top, 8)
            }
            ScreenScroll(scrolls: scrolls) {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    accountCard.scaledPadding(.top, 24)
                    securityCard
                    linksCard.scaledPadding(.top, 20)
                    deleteCard
                }
                .scaledPadding(.bottom, 32)
            }
        }
        .background(Theme.background)
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

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 8) {
            UserAvatar(photo: profile?.owner != nil ? profile?.photo : nil, name: name.isEmpty ? nil : name,
                       id: profile?.owner ?? session.userId, size: Theme.metric(72, scale))
            Text(verbatim: name.isEmpty ? (email ?? UIText.localized("Signed in")) : name)
                .themeFont(.sheetTitle)
                .foregroundStyle(Theme.primary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .accessibilityAddTraits(.isHeader)
            if let method {
                // The chip: the accent at 14 % behind accent words.
                Text(verbatim: method)
                    .scaledFont(12, weight: .semibold)
                    .foregroundStyle(Theme.accent)
                    .scaledPadding(.horizontal, 10)
                    .frame(minHeight: Theme.metric(26, scale))
                    .background(Theme.accent.opacity(0.14), in: .capsule)
                    .accessibilityIdentifier("profile.methodBadge")
            }
        }
        .frame(maxWidth: .infinity)
        .scaledPadding(.top, 8)
        .scaledPadding(.horizontal, Theme.gutter)
    }

    // MARK: - Account

    private var accountCard: some View {
        let showsEmail = !(email ?? "").isEmpty
        let short = ProfileFacts.shortID(session.userId)
        let showsSync = flights != nil
        return ProfileSection(title: "Account", id: "profile.account") {
            if let profile, profile.owner != nil {
                ProfileRow(title: "Name and Photo",
                           value: name.isEmpty ? UIText.localized("Add your name and photo") : name,
                           last: !showsEmail && short == nil && !showsSync,
                           id: "profile.account.name") { editing = true }
                    .accessibilityHint(UIText.localized("Edit your name and photo"))
            }
            if showsEmail {
                ProfileRow(title: "Email", value: email, accessory: nil,
                           last: short == nil && !showsSync, id: "profile.account.email")
            }
            if let short {
                ProfileRow(title: "Account ID", value: idCopied ? UIText.localized("ID Copied") : short,
                           accessory: idCopied ? "checkmark" : "doc.on.doc", accessoryTint: Theme.accent,
                           monospaced: !idCopied, last: !showsSync, id: "profile.account.id") { copyID() }
                    .accessibilityHint(UIText.localized("Copy your account ID"))
            }
            if let flights {
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    ProfileRow(title: "Sync",
                               value: ProfileFacts.syncLine(ProfileFacts.SyncState(flights), now: context.date),
                               accessory: nil, last: true, id: "profile.account.sync")
                }
            }
        }
    }

    private func copyID() {
        Clipboard.copy(ProfileFacts.fullID(session.userId), sensitive: false)
        idCopied = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            idCopied = false
        }
    }

    // MARK: - Security

    /// The sign-in method and the Travel Documents lock and sync; nothing when the app knows none of them.
    @ViewBuilder private var securityCard: some View {
        let showsMethod = !(method ?? "").isEmpty
        let showsDocuments = documents != nil && onDocuments != nil
        if showsMethod || showsDocuments {
            ProfileSection(title: "Security", id: "profile.security") {
                if showsMethod {
                    ProfileRow(title: "Sign-In", value: method, accessory: nil, last: !showsDocuments,
                               id: "profile.security.signIn")
                }
                if let documents, let onDocuments {
                    ProfileRow(title: "Document Numbers",
                               value: ProfileFacts.documentsLock(biometry: Self.biometry, onMac: Self.onMac),
                               id: "profile.security.documents", action: onDocuments)
                        .accessibilityHint(UIText.localized("Opens Travel Documents"))
                    ProfileRow(title: "Document Sync", value: ProfileFacts.documentsSync(documents.syncsWithICloud),
                               last: true, id: "profile.security.documentsSync", action: onDocuments)
                        .accessibilityHint(UIText.localized("Opens Travel Documents"))
                }
            }
            .scaledPadding(.top, 20)
        }
    }

    // MARK: - Links and deletion

    private var linksCard: some View {
        ProfileSection(title: nil, id: "profile.links") {
            ProfileRow(title: "Privacy Policy", value: nil, accessory: "arrow.up.right",
                       id: "profile.security.privacy") { openURL(SettingsView.privacyURL) }
            ProfileRow(title: "Sign Out", value: nil, accessory: nil, tone: .action, last: true,
                       id: "profile.security.signOut", action: onSignOut)
        }
    }

    @ViewBuilder private var deleteCard: some View {
        if let onDeleteAccount {
            VStack(alignment: .leading, spacing: 8) {
                ProfileSection(title: nil, id: "profile.delete") {
                    ProfileRow(title: "Delete Account", value: nil, accessory: nil, tone: .destructive,
                               busy: deleting, last: true, id: "profile.security.delete",
                               action: deleting ? nil : onDeleteAccount)
                }
                Text(ui: Self.deleteNote)
                    .themeFont(.sectionSubtitle)
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .scaledPadding(.horizontal, Theme.gutter + 16)
            }
            .scaledPadding(.top, 20)
        }
    }

    private static var onMac: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }

    /// "Face ID", "Touch ID" or "Optic ID" when the device has one enrolled; nil leaves the passcode.
    private static var biometry: String? {
        #if canImport(LocalAuthentication)
        let context = LAContext()
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) else { return nil }
        switch context.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        default: return nil
        }
        #else
        return nil
        #endif
    }
}

// MARK: - Parts

/// A Profil section (R6): the small caps label outside, then one flat card of rows, no stroke, no coloured top.
private struct ProfileSection<Content: View>: View {
    var title: String?
    var id: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title { SectionLabel(title) }
            RefinedCard(padding: 0) {
                VStack(spacing: 0) { content }
            }
            .scaledPadding(.horizontal, Theme.gutter)
            // A container: the card's identifier never replaces its rows' own.
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(id)
        }
    }
}

/// One row of a Profil card: the title in the body size and its value under it in grey (a row without a value
/// reads as its action, in the accent or red), then a chevron or `accessory`, and a separator unless `last`.
/// With an action the row is a button; without one its value stays selectable.
private struct ProfileRow: View {
    enum Tone { case plain, action, destructive }

    var title: String
    var value: String?
    var accessory: String? = "chevron.right"
    var accessoryTint: Color = Theme.secondary.opacity(0.7)
    var monospaced = false
    var tone: Tone = .plain
    var busy = false
    var last = false
    var id: String
    var action: (() -> Void)?
    @Environment(\.metricsScale) private var scale

    var body: some View {
        VStack(spacing: 0) {
            if let action {
                Button(action: action) { row.contentShape(Rectangle()) }
                    .buttonStyle(SettingsRowStyle())
                    .disabled(busy)
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityIdentifier(id)
            } else if tone != .plain || busy {
                row
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier(id)
            } else {
                row
                    .textSelection(.enabled)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier(id)
            }
            if !last {
                Rectangle().fill(Theme.separator).frame(height: 0.5).scaledPadding(.leading, 16)
            }
        }
        .privacySensitive()
    }

    private var titleColor: Color {
        switch tone {
        case .plain: Theme.primary
        case .action: Theme.accent
        case .destructive: Theme.veryLate
        }
    }

    private var row: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(ui: title).themeFont(.body).foregroundStyle(titleColor)
                if let value, !value.isEmpty {
                    Text(verbatim: value)
                        .themeFont(.sectionSubtitle)
                        .monospaced(monospaced)
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
            }
            Spacer(minLength: 8)
            if busy {
                ProgressView().controlSize(.small)
            } else if let accessory {
                Image(systemName: accessory)
                    .scaledFont(accessory == "chevron.right" || accessory == "arrow.up.right" ? 13 : 17,
                                weight: accessory == "chevron.right" || accessory == "arrow.up.right" ? .semibold : .medium)
                    .foregroundStyle(accessoryTint)
                    .frame(minWidth: 22)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, value == nil ? 0 : 6)
        .frame(maxWidth: .infinity, minHeight: Theme.metric(value == nil ? 50 : 60, scale), alignment: .leading)
        .scaledPadding(.horizontal, 16)
    }
}

#if DEBUG
#Preview("Profil, light") {
    @Previewable @State var profile: ProfileStore? = nil
    Group {
        if let profile {
            AccountProfileView(session: UserSession(userId: FakeProfileService.userId, email: nil, usesApple: true),
                               profile: profile, onClose: {}, onDocuments: {}, onSignOut: {}, onDeleteAccount: {})
        } else {
            ProgressView()
        }
    }
    .environment(\.travelDocuments, .preview())
    .preferredColorScheme(.light)
    .task {
        let store = ProfileStore(service: FakeProfileService())
        await store.prepare(owner: FakeProfileService.userId)
        profile = store
    }
}
#endif
