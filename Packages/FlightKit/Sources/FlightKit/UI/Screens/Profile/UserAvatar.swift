import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

extension Image {
    /// A JPEG or PNG from memory; nil when it does not decode.
    static func from(data: Data?) -> Image? {
        guard let data, !data.isEmpty else { return nil }
        #if os(iOS)
        return UIImage(data: data).map { Image(uiImage: $0) }
        #else
        return NSImage(data: data).map { Image(nsImage: $0) }
        #endif
    }
}

/// A round avatar: the photo when there is one, else the initials of `name` on the person's soft colour
/// (the same colours friends' avatars use), else a neutral person glyph (no profile yet).
struct UserAvatar: View {
    var photo: Data?
    var name: String?
    var id: UUID?
    var size: CGFloat

    var body: some View {
        let tone = FriendAvatar.tones[FriendAvatarText.tone(id, count: FriendAvatar.tones.count)]
        ZStack {
            if let image = Image.from(data: photo) {
                image.resizable().interpolation(.high).scaledToFill()
            } else if let name, !name.trimmingCharacters(in: .whitespaces).isEmpty {
                Circle().fill(tone.opacity(0.22))
                Text(FriendAvatarText.initials(name))
                    .font(.system(size: size * 0.38, weight: .semibold, design: .rounded))
                    .foregroundStyle(tone)
            } else {
                Circle().fill(Theme.pill)
                Image(systemName: "person.fill")
                    .font(.system(size: size * 0.42, weight: .medium))
                    .foregroundStyle(Theme.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityHidden(true)
    }
}

/// The header's top right control on My Flights, Friends and Passport: the user's avatar in the same
/// Liquid Glass circle the gear had, opening Settings. A neutral person glyph while there is no profile
/// (signed out, or still loading). It redraws as soon as the profile's name or photo changes.
public struct ProfileButton: View {
    var profile: ProfileStore?
    var action: () -> Void
    @Environment(\.metricsScale) private var scale
    @Environment(\.airportStaticControls) private var staticControls

    public init(profile: ProfileStore?, action: @escaping () -> Void) {
        self.profile = profile; self.action = action
    }

    public var body: some View {
        let side = Theme.metric(44, scale)
        Button(action: action) {
            avatar(inset: side - Theme.metric(6, scale))
                .frame(width: side, height: side)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .modifier(GlassOrFlat(flat: staticControls))
        .accessibilityLabel("Settings and profile")
    }

    @ViewBuilder private func avatar(inset: CGFloat) -> some View {
        if let profile, profile.owner != nil, profile.photo != nil || !profile.displayName.isEmpty {
            // `revision` is read so a new photo or name redraws the button at once.
            let _ = profile.revision
            UserAvatar(photo: profile.photo, name: profile.displayName, id: profile.owner, size: inset)
        } else {
            Image(systemName: "person.fill")
                .font(.system(size: Theme.metric(18, scale), weight: .medium))
                .foregroundStyle(Theme.primary)
        }
    }
}

/// Friends' photos by friend, for `FriendAvatar` (set by the shells from `ProfileStore.friendPhotos`).
struct FriendPhotosKey: EnvironmentKey {
    static let defaultValue: [UUID: Data] = [:]
}

public extension EnvironmentValues {
    var friendPhotos: [UUID: Data] {
        get { self[FriendPhotosKey.self] }
        set { self[FriendPhotosKey.self] = newValue }
    }
}

/// The round Liquid Glass of the floating controls; snapshots get a flat circle (ImageRenderer cannot draw
/// glass, and drops what it holds).
struct GlassOrFlat: ViewModifier {
    var flat: Bool
    func body(content: Content) -> some View {
        if flat {
            content.background(Circle().fill(Theme.pill))
        } else {
            content.roundGlass()
        }
    }
}
