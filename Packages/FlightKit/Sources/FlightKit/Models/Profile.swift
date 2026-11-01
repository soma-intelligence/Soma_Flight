import Foundation

/// How the account signed in. Google is built but not switched on yet (docs/profile-onboarding.md).
public enum AuthProvider: String, Sendable, Hashable, Codable {
    case apple, google, email, other

    /// Supabase's `app_metadata.provider`.
    public init(supabase raw: String?) {
        switch raw?.lowercased() {
        case "apple": self = .apple
        case "google": self = .google
        case "email": self = .email
        default: self = .other
        }
    }
}

/// What the sign-in provider says about the person: Apple's name (first authorization only, never a
/// photo), Google's name and picture, or only an email. Read from Supabase's `user_metadata`, never trusted
/// as is: `DisplayName` filters out what does not look like a name.
public struct AccountIdentity: Sendable, Hashable {
    public var provider: AuthProvider
    public var email: String?
    public var fullName: String?
    public var givenName: String?
    public var familyName: String?
    /// The provider's picture (Google's `avatar_url` or `picture`), https only.
    public var avatarURL: URL?

    public init(provider: AuthProvider, email: String? = nil, fullName: String? = nil, givenName: String? = nil,
                familyName: String? = nil, avatarURL: URL? = nil) {
        self.provider = provider; self.email = email; self.fullName = fullName
        self.givenName = givenName; self.familyName = familyName; self.avatarURL = avatarURL
    }

    /// Reads Supabase's `user_metadata` (Apple and Google fill different keys): `full_name` or `name`,
    /// `given_name` / `family_name` (and Apple's `first_name` / `last_name` spelling), `avatar_url` or `picture`.
    public static func from(metadata: [String: String], provider: AuthProvider, email: String?) -> AccountIdentity {
        func value(_ keys: String...) -> String? {
            for k in keys {
                if let v = metadata[k]?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty { return v }
            }
            return nil
        }
        let picture = value("avatar_url", "picture").flatMap(URL.init(string:)).flatMap { $0.scheme == "https" ? $0 : nil }
        return AccountIdentity(provider: provider, email: email ?? value("email"),
                               fullName: value("full_name", "name"),
                               givenName: value("given_name", "first_name"),
                               familyName: value("family_name", "last_name"),
                               avatarURL: picture)
    }

    /// The same identity with Apple's one-time name added where the metadata had none (the name the sign-in
    /// just received, before the metadata write lands).
    public func adding(appleName name: PersonNameComponents?) -> AccountIdentity {
        guard let name else { return self }
        var copy = self
        if copy.givenName == nil { copy.givenName = name.givenName.flatMap { $0.isEmpty ? nil : $0 } }
        if copy.familyName == nil { copy.familyName = name.familyName.flatMap { $0.isEmpty ? nil : $0 } }
        return copy
    }
}

/// The name shown for the user, as a pure function with no network. In order:
/// 1. the name they typed;
/// 2. the provider's full name;
/// 3. the provider's given and family names;
/// 4. the email's local part, only when the address is not a private relay and the local part looks like a
///    name (letters, at most one dot or underscore: "jean.dupont" gives "Jean Dupont");
/// 5. empty, so the app asks.
/// A step whose value looks like a random id (digits, a hash, an address) is skipped, so the app never shows
/// "j3k9x2abc" as someone's name.
public enum DisplayName {
    public static let maxLength = 40

    public static func resolve(typed: String?, identity: AccountIdentity?) -> String {
        if let t = clean(typed) { return t }
        guard let identity else { return "" }
        if let full = plausible(identity.fullName) { return full }
        let parts = [identity.givenName, identity.familyName].compactMap { plausible($0) }
        if !parts.isEmpty, let joined = plausible(parts.joined(separator: " ")) { return joined }
        if let email = identity.email, let fromEmail = nameFromEmail(email) { return fromEmail }
        return ""
    }

    /// Apple's Hide My Email (`…@privaterelay.appleid.com`), and iCloud+ Hide My Email addresses on
    /// icloud.com, me.com or mac.com, which carry digits in a random word pair ("dense.crane_0q@icloud.com").
    public static func isPrivateRelay(_ email: String) -> Bool {
        let lower = email.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard let at = lower.lastIndex(of: "@") else { return false }
        let local = lower[..<at], domain = lower[lower.index(after: at)...]
        if domain == "privaterelay.appleid.com" || domain.hasSuffix(".privaterelay.appleid.com") { return true }
        if ["icloud.com", "me.com", "mac.com"].contains(String(domain)), local.contains(where: \.isNumber) { return true }
        return false
    }

    /// A name from the email's local part, or nil. Letters only (any script, accents kept), at most one
    /// dot or underscore, each piece at least two letters and shaped like a word (a vowel, no long run of
    /// consonants). Never from a relay address.
    public static func nameFromEmail(_ email: String) -> String? {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isPrivateRelay(trimmed), let at = trimmed.lastIndex(of: "@") else { return nil }
        let local = String(trimmed[..<at])
        let separators = local.filter { $0 == "." || $0 == "_" }
        guard separators.count <= 1, !local.isEmpty, local.count <= 30 else { return nil }
        let pieces = local.split(whereSeparator: { $0 == "." || $0 == "_" }).map(String.init)
        guard pieces.count == separators.count + 1,
              pieces.allSatisfy({ $0.count >= 2 && $0.allSatisfy(\.isLetter) && wordShaped($0) }) else { return nil }
        let name = pieces.map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }.joined(separator: " ")
        return plausible(name)
    }

    /// What the user typed, trimmed, inner spaces collapsed and cut to `maxLength`; nil when empty. Their own
    /// words are kept as they are (no id check: a name typed on purpose is theirs).
    public static func clean(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let name = String(raw.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").prefix(maxLength))
            .trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    /// The trimmed name with inner runs of spaces collapsed, or nil when it is empty, too long, an address, or
    /// looks like an id (several digits, a hex string, a long piece with no vowel).
    public static func plausible(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let name = raw.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard !name.isEmpty, name.count <= maxLength, !name.contains("@") else { return nil }
        let letters = name.filter(\.isLetter).count, digits = name.filter(\.isNumber).count
        guard letters > 0, digits * 4 < max(letters, 1) else { return nil }
        if digits > 0, name.split(separator: " ").count == 1 { return nil } // "j3k9x2abc", "user2048"
        let compact = name.lowercased().filter { !$0.isWhitespace }
        if compact.count >= 8, compact.allSatisfy({ $0.isHexDigit }) { return nil }
        for word in name.split(separator: " ") where word.count >= 8 {
            if !wordShaped(String(word)) { return nil }
        }
        return name
    }

    /// Has a vowel and no run of five consonants: "dupont" yes, "xkcdqrst" no.
    static func wordShaped(_ word: String) -> Bool {
        let folded = word.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        // Scripts without Latin vowels (Greek, Cyrillic, CJK...) are left alone.
        guard folded.unicodeScalars.allSatisfy({ $0.isASCII }) else { return true }
        let vowels = Set("aeiouy")
        guard folded.contains(where: { vowels.contains($0) }) else { return false }
        var run = 0
        for c in folded {
            if c.isLetter, !vowels.contains(c) { run += 1; if run >= 5 { return false } } else { run = 0 }
        }
        return true
    }

    /// "Ada King Lovelace" -> ("Ada", "King Lovelace"); one word is a first name only.
    public static func split(_ full: String) -> (first: String, last: String) {
        let words = full.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard let first = words.first else { return ("", "") }
        return (first, words.dropFirst().joined(separator: " "))
    }

    /// First and last name joined, trimmed; empty when both are.
    public static func join(first: String, last: String) -> String {
        [first, last].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: " ")
    }
}

/// The signed-in user's own profile (`profiles`, migrations 20261028000001, 20261031000022, 20261031000030).
public struct UserProfile: Sendable, Hashable, Codable {
    public var userId: UUID
    public var firstName: String?
    public var lastName: String?
    /// What friends see; the app writes it from first and last name.
    public var displayName: String?
    public var emoji: String?
    /// `<user_id>/avatar.jpg` in the private `avatars` bucket, nil without a photo.
    public var avatarPath: String?
    /// When onboarding was finished or put off ("Later"); nil shows it.
    public var onboardedAt: Date?

    public init(userId: UUID, firstName: String? = nil, lastName: String? = nil, displayName: String? = nil,
                emoji: String? = nil, avatarPath: String? = nil, onboardedAt: Date? = nil) {
        self.userId = userId; self.firstName = firstName; self.lastName = lastName; self.displayName = displayName
        self.emoji = emoji; self.avatarPath = avatarPath; self.onboardedAt = onboardedAt
    }

    /// The fixed photo path for a user.
    public static func avatarPath(for user: UUID) -> String { "\(user.uuidString.lowercased())/avatar.jpg" }
}

/// What the onboarding fields start with: the profile's own names first, else the provider's given and
/// family names, else its full name split, else a name read from a non-relay email. Empty fields ask.
public struct ProfileDraft: Sendable, Hashable {
    public var firstName: String
    public var lastName: String

    public init(firstName: String = "", lastName: String = "") {
        self.firstName = firstName; self.lastName = lastName
    }

    public static func prefill(profile: UserProfile?, identity: AccountIdentity?) -> ProfileDraft {
        let first = DisplayName.clean(profile?.firstName), last = DisplayName.clean(profile?.lastName)
        if first != nil || last != nil { return ProfileDraft(firstName: first ?? "", lastName: last ?? "") }
        if let typed = DisplayName.clean(profile?.displayName) {
            let s = DisplayName.split(typed)
            return ProfileDraft(firstName: s.first, lastName: s.last)
        }
        guard let identity else { return ProfileDraft() }
        let given = DisplayName.plausible(identity.givenName), family = DisplayName.plausible(identity.familyName)
        if given != nil || family != nil { return ProfileDraft(firstName: given ?? "", lastName: family ?? "") }
        let full = DisplayName.resolve(typed: nil, identity: identity)
        let s = DisplayName.split(full)
        return ProfileDraft(firstName: s.first, lastName: s.last)
    }

    /// The name this draft gives friends; empty when both fields are.
    public var displayName: String { DisplayName.clean(DisplayName.join(first: firstName, last: lastName)) ?? "" }
}
