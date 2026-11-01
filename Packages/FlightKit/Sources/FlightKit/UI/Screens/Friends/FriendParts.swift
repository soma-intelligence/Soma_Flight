import SwiftUI

// MARK: - Wording

/// The Friends screens' words, kept apart so tests can read them.
enum FriendFacts {
    /// One line about a flight on a friend's row, and its colour: in the air, leaving in, late, landed.
    static func status(_ f: Flight, now: Date) -> (text: String, color: Color) {
        let late = lateText(f)
        switch f.status {
        case .canceled: return ("Canceled", Theme.veryLate)
        case .diverted: return ("Diverted", Theme.diverted)
        case .landed, .arrived: return ("Landed", Theme.secondary)
        case .departed, .enRoute:
            return (["In the air", late].compactMap { $0 }.joined(separator: " · "), f.level.color)
        case .scheduled, .unknown:
            let count = DetailFacts.countdownColumn(f, now: now)
            let when: String = switch count.unit {
            case "DEPARTING": "Leaving now"
            case "SCHEDULED": "Scheduled"
            default: "Leaves in \(count.value) \(unitWord(count.unit, count.value))"
            }
            return ([when, late ?? "On time"].joined(separator: " · "), f.level.color)
        }
    }

    /// "25 min late" once a delay is worth saying (5 minutes or more); nil otherwise.
    static func lateText(_ f: Flight) -> String? {
        let delay: Duration? = switch f.status {
        case .departed, .enRoute, .landed, .arrived: f.arrivalDelay ?? f.departureDelay
        default: f.departureDelay
        }
        guard let d = delay else { return nil }
        let m = Int(d.components.seconds / 60)
        guard m >= 5 else { return nil }
        if m < 60 { return "\(m) min late" }
        return m % 60 == 0 ? "\(m / 60) h late" : "\(m / 60) h \(m % 60) min late"
    }

    private static func unitWord(_ unit: String, _ value: String) -> String {
        switch unit {
        case "DAY": "day"
        case "DAYS": "days"
        case "HR", "HRS": "h"
        default: "min"
        }
    }

    /// "AF 84 · CDG to SFO".
    static func summary(_ f: Flight) -> String {
        "\(Format.ident(f.ident)) · \(f.originCode) to \(f.destinationCode)"
    }

    /// "Friends since October 2026".
    static func since(_ d: Date) -> String {
        "Friends since \(d.formatted(.dateTime.month(.wide).year().locale(Locale(identifier: "en_US_POSIX"))))"
    }

    /// "AF 84 · Paris → San Francisco": the flight and its cities (codes when an airport is unknown).
    static func route(_ f: Flight, lookup: (String) -> Airport?) -> String {
        let from = lookup(f.originIcao)?.city ?? f.originCode, to = lookup(f.destinationIcao)?.city ?? f.destinationCode
        return "\(Format.ident(f.ident)) · \(from) → \(to)"
    }

    /// The short status after the route on a friend's row, and its colour: "departs in 3h",
    /// "in the air · lands in 1h 20m", "departs in 40 min · 25 min late", "landed", "canceled".
    static func when(_ f: Flight, now: Date) -> (text: String, color: Color) {
        switch f.status {
        case .canceled: return ("canceled", Theme.veryLate)
        case .diverted: return ("diverted", Theme.diverted)
        case .landed, .arrived: return ("landed", Theme.secondary)
        case .departed, .enRoute:
            let lands = DetailFacts.bestIn(f).map { Int($0.timeIntervalSince(now) / 60) }.flatMap { $0 > 0 ? $0 : nil }
            return (["in the air", lands.map { "lands in \(span($0))" }].compactMap { $0 }.joined(separator: " · "),
                    f.level.color)
        case .scheduled, .unknown:
            guard let out = DetailFacts.bestOut(f) else { return ("scheduled", f.level.color) }
            let m = Int(out.timeIntervalSince(now) / 60)
            let leaves = m <= 0 ? "departing now" : "departs in \(span(m))"
            return ([leaves, lateText(f)].compactMap { $0 }.joined(separator: " · "), f.level.color)
        }
    }

    /// A wait in a few characters: "40 min", "1h 40m" (under 3 hours), "3h", "1 day", "4 days".
    static func span(_ minutes: Int) -> String {
        let m = max(0, minutes)
        if m < 60 { return "\(m) min" }
        if m < 24 * 60 {
            let h = m / 60, rest = m % 60
            return h < 3 && rest > 0 ? "\(h)h \(rest)m" : "\(h)h"
        }
        let d = m / (24 * 60)
        return d == 1 ? "1 day" : "\(d) days"
    }

    /// The friend code as VoiceOver reads it, one character at a time in its two groups:
    /// "K 7 M 2, X 9 Q P".
    static func spokenCode(_ code: String) -> String {
        let spaced = FriendsMe(friendCode: code).spacedCode
        return spaced.split(separator: " ").map { $0.map(String.init).joined(separator: " ") }.joined(separator: ", ")
    }

    /// What the code card shows before the code has loaded.
    static let codePlaceholder = "···· ····"

    /// The words that travel with an invitation link (and alone when no link could be made).
    static func inviteMessage(code: String?) -> String {
        let base = "Let's follow each other's flights on Soma Flight."
        guard let code else { return base }
        return "\(base) My friend code is \(FriendsMe(friendCode: code).spacedCode)."
    }

    /// The line under the QR sheet's title: how long the invitation lasts, from its own end date.
    static func qrBlurb(expiresAt: Date?, now: Date) -> String {
        let base = "Point another phone's camera here."
        guard let expiresAt else { return "\(base) The invitation works once." }
        let left = expiresAt.timeIntervalSince(now)
        let days = Int((left / 86_400).rounded(.up))
        let span = left <= 0 ? "it has expired" : days <= 1 ? "for 1 more day" : "for \(days) more days"
        return "\(base) The invitation works once, \(span)."
    }

    static let emptyTitle = "Fly apart, stay close"
    static let emptyText = "See each other's flights, only with the people you pick."
    static let quietTitle = "Nobody is flying soon"
    static let quietText = "No friend has a flight in the next 24 hours."
}

// MARK: - Avatar

/// A friend's round mark: their emoji, else their initials, on a soft colour of their own (the friends
/// colour without an id).
struct FriendAvatar: View {
    var name: String?
    var emoji: String?
    var size: CGFloat = 40
    /// Picks the friend's colour (`FriendAvatarText.tone`).
    var id: UUID?

    /// The soft colours avatars take, the friends colour first.
    static let tones: [Color] = [Theme.friend, Theme.accent, Theme.diverted, Theme.late, Theme.onTime, Theme.passportAccent]
    /// Friends' photos (`ProfileStore.friendPhotos`); a friend with one shows it instead of emoji or initials.
    @Environment(\.friendPhotos) private var photos

    var body: some View {
        let tone = Self.tones[FriendAvatarText.tone(id, count: Self.tones.count)]
        ZStack {
            Circle().fill(tone.opacity(0.2))
            if let id, let photo = Image.from(data: photos[id]) {
                photo.resizable().interpolation(.high).scaledToFill().clipShape(Circle())
            } else if let emoji, !emoji.isEmpty {
                Text(emoji).font(.system(size: size * 0.52))
            } else {
                Text(FriendAvatarText.initials(name))
                    .font(.system(size: size * 0.38, weight: .semibold, design: .rounded))
                    .foregroundStyle(tone)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Icon, title and grey line, with a switch: the friend page's settings rows.
struct FriendToggleRow: View {
    var icon: String
    var title: String
    var subtitle: String?
    @Binding var isOn: Bool
    var last = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .scaledFont(17, weight: .medium)
                    .foregroundStyle(Theme.primary)
                    .frame(width: 26)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).scaledFont(17).foregroundStyle(Theme.primary)
                    if let subtitle {
                        Text(subtitle).scaledFont(13).foregroundStyle(Theme.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                Toggle(title, isOn: $isOn).labelsHidden().tint(Theme.accent)
            }
            .scaledPadding(.vertical, 12)
            .accessibilityElement(children: .combine)
            if !last { Hairline().scaledPadding(.leading, 40) }
        }
    }
}

// MARK: - Invitation answer

/// The sheet an opened invitation link shows: who sent it, what being friends means, Accept or Decline. A
/// link already used, expired, the user's own, or from a friend says so instead.
public struct FriendInviteSheet: View {
    var invite: PendingFriendInvite
    var onAnswer: (Bool) async -> APIError?
    var onClose: () -> Void
    @State private var working = false
    @State private var failure: APIError?

    public init(invite: PendingFriendInvite, onAnswer: @escaping (Bool) async -> APIError?, onClose: @escaping () -> Void) {
        self.invite = invite; self.onAnswer = onAnswer; self.onClose = onClose
    }

    public var body: some View {
        VStack(spacing: 18) {
            HStack { Spacer(); RoundButton(systemImage: "xmark", label: "Close", action: onClose) }
            if let preview = invite.preview {
                FriendAvatar(name: preview.displayName, emoji: preview.emoji, size: 76)
                Text(title(preview))
                    .scaledFont(24, weight: .bold)
                    .foregroundStyle(Theme.primary)
                    .multilineTextAlignment(.center)
                Text(text(preview))
                    .scaledFont(16)
                    .foregroundStyle(Theme.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                if let failure { ErrorBanner(error: failure) }
                if preview.state == .open {
                    VStack(spacing: 10) {
                        Button { answer(true) } label: {
                            Text("Accept").scaledFont(17, weight: .semibold).foregroundStyle(.white)
                                .frame(maxWidth: .infinity).scaledPadding(.vertical, 14)
                                .background(Capsule().fill(Theme.accent))
                        }
                        Button { answer(false) } label: {
                            Text("Decline").scaledFont(17, weight: .semibold).foregroundStyle(Theme.primary)
                                .frame(maxWidth: .infinity).scaledPadding(.vertical, 14)
                                .background(Capsule().fill(Theme.pill))
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(working)
                    .scaledPadding(.top, 8)
                } else {
                    Button("Close", action: onClose).scaledFont(17, weight: .semibold).scaledPadding(.top, 8)
                }
            } else if let error = invite.error {
                Text(error == .notFound ? "This invitation does not exist" : "Could not open this invitation")
                    .scaledFont(22, weight: .bold).foregroundStyle(Theme.primary)
                ErrorBanner(error: error)
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 160)
            }
            Spacer(minLength: 0)
        }
        .scaledPadding(.horizontal, 24)
        .scaledPadding(.top, 16)
        .background(Theme.background)
    }

    private func title(_ p: FriendInvitePreview) -> String {
        switch p.state {
        case .open: "\(p.name) invited you"
        case .friends: "You and \(p.name) are already friends"
        case .self: "This is your own invitation"
        case .expired: "This invitation has expired"
        case .used: "This invitation was already used"
        }
    }

    private func text(_ p: FriendInvitePreview) -> String {
        switch p.state {
        case .open: "Friends see each other's upcoming flights, nothing else. Either of you can stop sharing or end it at any time."
        case .friends: "Their flights are in your Friends tab."
        case .self: "Send it to a friend: whoever opens it first can accept."
        case .expired, .used: "Ask \(p.name) for a new link, or for their friend code."
        }
    }

    private func answer(_ accept: Bool) {
        working = true
        Task {
            failure = await onAnswer(accept)
            working = false
        }
    }
}
