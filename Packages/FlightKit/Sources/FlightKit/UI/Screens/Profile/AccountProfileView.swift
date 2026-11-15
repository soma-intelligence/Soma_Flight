import SwiftUI
#if canImport(LocalAuthentication)
import LocalAuthentication
#endif

/// Settings > account row: the Profil, the way OnePass draws its own (2026-11-14). The avatar, the name and
/// how the account signs in, then two cards. Compte: name and photo, email, account ID (copied on a tap) and
/// how fresh the followed flights are. Sécurité: the sign-in method, the Travel Documents lock and sync,
/// the privacy policy, signing out and deleting the account. Only what the app knows is shown; a row
/// without its data is left out. Nothing is changed on the page itself: each row opens what changes it.
struct AccountProfileView: View {
    var session: UserSession
    var profile: ProfileStore?
    var flights: MyFlightsStore?
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
        ScreenScroll(scrolls: scrolls) {
            VStack(alignment: .leading, spacing: 0) {
                header
                accountCard.scaledPadding(.top, 24)
                securityCard.scaledPadding(.top, 20)
            }
            .scaledPadding(.bottom, 32)
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
                .overlay(Circle().strokeBorder(Theme.primary.opacity(0.06), lineWidth: 1))
            Text(verbatim: name.isEmpty ? (email ?? UIText.localized("Signed in")) : name)
                .scaledFont(22, weight: .bold, relativeTo: .title2)
                .foregroundStyle(Theme.primary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .accessibilityAddTraits(.isHeader)
            if let method {
                Text(verbatim: method)
                    .scaledFont(12, weight: .semibold)
                    .foregroundStyle(Theme.accent)
                    .scaledPadding(.horizontal, 8)
                    .scaledPadding(.vertical, 3)
                    .background(Theme.accent.opacity(0.15), in: .capsule)
                    .accessibilityIdentifier("profile.methodBadge")
            }
        }
        .frame(maxWidth: .infinity)
        .scaledPadding(.top, 28)
        .scaledPadding(.horizontal, 16)
    }

    // MARK: - Compte

    private var accountCard: some View {
        ProfileCard(title: "Account", symbol: "person.text.rectangle.fill", color: SettingsStyle.blue) {
            if let profile, profile.owner != nil {
                ProfileNavRow(label: "Name and Photo",
                              value: name.isEmpty ? UIText.localized("Add your name and photo") : name,
                              id: "profile.account.name") { editing = true }
                    .accessibilityHint(UIText.localized("Edit your name and photo"))
            }
            ProfileTextRow(label: "Email", value: email, id: "profile.account.email")
            if let short = ProfileFacts.shortID(session.userId) {
                ProfileNavRow(label: "Account ID", value: idCopied ? UIText.localized("ID Copied") : short,
                              accessory: idCopied ? "checkmark" : "doc.on.doc", monospaced: !idCopied,
                              id: "profile.account.id") { copyID() }
                    .accessibilityHint(UIText.localized("Copy your account ID"))
            }
            if let flights {
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    ProfileTextRow(label: "Sync",
                                   value: ProfileFacts.syncLine(ProfileFacts.SyncState(flights), now: context.date),
                                   id: "profile.account.sync")
                }
            }
        }
        .accessibilityIdentifier("profile.account")
    }

    private func copyID() {
        Clipboard.copy(ProfileFacts.fullID(session.userId), sensitive: false)
        idCopied = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            idCopied = false
        }
    }

    // MARK: - Sécurité

    private var securityCard: some View {
        ProfileCard(title: "Security", symbol: "lock.shield.fill", color: SettingsStyle.green) {
            ProfileTextRow(label: "Sign-In", value: method, id: "profile.security.signIn")
            if let documents, let onDocuments {
                ProfileNavRow(label: "Document Numbers", value: ProfileFacts.documentsLock(biometry: Self.biometry,
                                                                                         onMac: Self.onMac),
                              id: "profile.security.documents", action: onDocuments)
                    .accessibilityHint(UIText.localized("Opens Travel Documents"))
                ProfileNavRow(label: "Document Sync", value: ProfileFacts.documentsSync(documents.syncsWithICloud),
                              id: "profile.security.documentsSync", action: onDocuments)
                    .accessibilityHint(UIText.localized("Opens Travel Documents"))
            }
            ProfileNavRow(label: "Privacy Policy", value: nil, accessory: "arrow.up.right",
                          id: "profile.security.privacy") { openURL(SettingsView.privacyURL) }
            ProfileNavRow(label: "Sign Out", value: nil, accessory: nil, id: "profile.security.signOut",
                          action: onSignOut)
            if let onDeleteAccount {
                ProfileNavRow(label: "Delete Account", value: nil, accessory: nil, destructive: true,
                              busy: deleting, id: "profile.security.delete", action: deleting ? nil : onDeleteAccount)
            }
        }
        .accessibilityIdentifier("profile.security")
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

/// A Profil card, as OnePass draws it: a bar of the card's colour on top, the tile and the title, then
/// the rows.
private struct ProfileCard<Content: View>: View {
    var title: String
    var symbol: String
    var color: Color
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(color).frame(height: 4).accessibilityHidden(true)
            HStack(spacing: 14) {
                SettingsTile(symbol: symbol, color: color)
                Text(ui: title)
                    .scaledFont(17, weight: .semibold, relativeTo: .headline)
                    .foregroundStyle(Theme.primary)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 4)
            }
            .scaledPadding(.horizontal, 16)
            .frame(minHeight: 52)
            Rectangle().fill(Theme.separator).frame(height: 0.5)
                .scaledPadding(.leading, SettingsStyle.textInset)
            content
            Spacer().frame(height: 14)
        }
        .background(RoundedRectangle(cornerRadius: SettingsStyle.radius, style: .continuous).fill(Theme.card))
        .clipShape(RoundedRectangle(cornerRadius: SettingsStyle.radius, style: .continuous))
        .scaledPadding(.horizontal, 16)
        // A container: the card's identifier never replaces its rows' own.
        .accessibilityElement(children: .contain)
    }
}

/// A label over its value; nothing when the value is empty.
private struct ProfileTextRow: View {
    var label: String
    var value: String?
    var id: String

    var body: some View {
        if let value, !value.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text(ui: label).scaledFont(13).foregroundStyle(Theme.secondary)
                Text(verbatim: value)
                    .scaledFont(17)
                    .foregroundStyle(Theme.primary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .scaledPadding(.horizontal, 16)
            .scaledPadding(.top, 10)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(id)
            .privacySensitive()
        }
    }
}

/// A row that opens something: the label (and its value under it), a chevron or `accessory` at the end.
/// Without a value the label reads as the action ("Sign Out"), in red when `destructive`.
private struct ProfileNavRow: View {
    var label: String
    var value: String?
    var accessory: String? = "chevron.right"
    var monospaced = false
    var destructive = false
    var busy = false
    var id: String
    var action: (() -> Void)?

    var body: some View {
        Button { action?() } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    if let value {
                        Text(ui: label).scaledFont(13).foregroundStyle(Theme.secondary)
                        Text(verbatim: value)
                            .scaledFont(17)
                            .monospaced(monospaced)
                            .foregroundStyle(Theme.primary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    } else {
                        Text(ui: label).scaledFont(17).foregroundStyle(destructive ? Theme.veryLate : Theme.accent)
                    }
                }
                Spacer(minLength: 8)
                if busy {
                    ProgressView().controlSize(.small)
                } else if let accessory {
                    Image(systemName: accessory)
                        .scaledFont(14, weight: .semibold)
                        .foregroundStyle(Theme.secondary.opacity(0.7))
                        .accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .scaledPadding(.horizontal, 16)
            .scaledPadding(.top, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(SettingsRowStyle())
        .disabled(action == nil)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier(id)
        .privacySensitive()
    }
}

#if DEBUG
#Preview("Profil, light") {
    @Previewable @State var profile: ProfileStore? = nil
    Group {
        if let profile {
            AccountProfileView(session: UserSession(userId: FakeProfileService.userId, email: nil, usesApple: true),
                               profile: profile, onDocuments: {}, onSignOut: {}, onDeleteAccount: {})
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
