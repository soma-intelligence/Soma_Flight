import Foundation

/// The texts the Profil computes (Settings > account row, after OnePass's Profil of 2026-11-14): the
/// short account ID, the sync line of the followed flights, the sign-in method and the Travel Documents
/// lock and sync. Pure: the views pass the values in, the clock and the locale included.
public enum ProfileFacts {
    /// "5a1e…00c1": the first and last four characters of the account's ID.
    public static func shortID(_ id: UUID?) -> String? { shortID(id.map(fullID)) }

    /// The first and last four characters of a long ID; a short one as is, nil without one.
    public static func shortID(_ id: String?) -> String? {
        guard let id, !id.isEmpty else { return nil }
        guard id.count > 12 else { return id }
        return "\(id.prefix(4))\u{2026}\(id.suffix(4))"
    }

    /// The ID as the account's rows on the server write it (lowercase), what the copy puts on the clipboard.
    public static func fullID(_ id: UUID) -> String { id.uuidString.lowercased() }

    /// How fresh the followed flights are on this device (`MyFlightsStore`).
    public struct SyncState: Equatable, Sendable {
        /// A healthy realtime subscription keeps the list current (`isLiveSynced`).
        public var live: Bool
        public var offline: Bool
        /// A load has finished, whatever its outcome (`hasLoaded`).
        public var loaded: Bool
        /// The last load failed (`error != nil`).
        public var failed: Bool
        /// When the list was last confirmed (`fetchedAt`): the load, or the saved copy while offline.
        public var confirmedAt: Date?

        public init(live: Bool, offline: Bool, loaded: Bool, failed: Bool, confirmedAt: Date?) {
            self.live = live; self.offline = offline; self.loaded = loaded; self.failed = failed
            self.confirmedAt = confirmedAt
        }

        @MainActor public init(_ store: MyFlightsStore) {
            self.init(live: store.isLiveSynced, offline: store.isOffline, loaded: store.hasLoaded,
                      failed: store.error != nil, confirmedAt: store.fetchedAt)
        }
    }

    /// "Live", "Up to date · 3 min ago", "Offline · 2 hr ago", "Couldn't sync" or "Syncing…".
    public static func syncLine(_ state: SyncState, now: Date, locale: Locale = .current) -> String {
        if state.live { return UIText.localized(live) }
        if state.offline { return withTime(UIText.localized(offline), state.confirmedAt, now: now, locale: locale) }
        if state.failed { return UIText.localized(failed) }
        if state.loaded, state.confirmedAt != nil {
            return withTime(UIText.localized(upToDate), state.confirmedAt, now: now, locale: locale)
        }
        return UIText.localized(syncing)
    }

    private static func withTime(_ label: String, _ date: Date?, now: Date, locale: Locale) -> String {
        guard let date else { return label }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        formatter.dateTimeStyle = .named
        formatter.locale = locale
        // A device clock behind the server's never reads "in 5 sec".
        return "\(label) \u{00B7} \(formatter.localizedString(for: min(date, now), relativeTo: now))"
    }

    /// How the account signs in, from the provider's word (`ProfileStore.identity`), else from the
    /// session (Apple is always known there); nil when neither says.
    public static func signInMethod(provider: AuthProvider?, usesApple: Bool) -> String? {
        switch provider {
        case .apple: return UIText.localized(apple)
        case .google: return "Google"
        case .email: return UIText.localized(email)
        case .other, nil: return usesApple ? UIText.localized(apple) : nil
        }
    }

    /// "Shown after Face ID": the hidden numbers open after the device owner check (biometry, else the
    /// passcode, or the password on the Mac, `LocalDeviceOwnerCheck`).
    public static func documentsLock(biometry: String?, onMac: Bool = false) -> String {
        String(format: UIText.localized(shownAfter), biometry ?? UIText.localized(onMac ? password : passcode))
    }

    /// The Travel Documents screen's own words for its sync switch.
    public static func documentsSync(_ on: Bool) -> String {
        UIText.localized(on ? TravelDocumentsCopy.syncOn : TravelDocumentsCopy.syncOff)
    }

    // MARK: Catalog keys

    static let live = "Live"
    static let offline = "Offline"
    static let failed = "Couldn't sync"
    static let upToDate = "Up to date"
    static let syncing = "Syncing\u{2026}"
    static let apple = "Sign in with Apple"
    static let email = "Email sign-in link"
    static let shownAfter = "Shown after %@"
    static let passcode = "your passcode"
    static let password = "your password"

    /// Every catalog key the Profil reads, its own and the screen's; each has a French line.
    static let catalogKeys = [
        live, offline, failed, upToDate, syncing, apple, email, shownAfter, passcode, password,
        "Account", "Security", "Name and Photo", "Email", "Account ID", "ID Copied", "Sync",
        "Sign-In", "Document Numbers", "Document Sync", "Sign Out", "Delete Account",
        "Copy your account ID", "Edit your name and photo", "Add your name and photo", "Signed in", "Privacy Policy",
        "Opens Travel Documents", "Shows your account and security",
    ]
}
