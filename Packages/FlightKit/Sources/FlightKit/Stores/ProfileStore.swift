import Foundation
import Observation
import os

/// The signed-in user's profile: their name and photo (the header's avatar button, Settings > Profile), the
/// one-time onboarding after the first sign-in, and their friends' photos. One store lives as long as the
/// home; `prepare(owner:)` points it at whoever is signed in.
@MainActor @Observable
public final class ProfileStore {
    /// Whether the onboarding shows. `.unknown` while the first read for this account runs.
    public enum Gate: Equatable, Sendable { case unknown, show, hidden }

    public private(set) var owner: UUID?
    public private(set) var profile: UserProfile?
    public private(set) var identity: AccountIdentity?
    /// The user's own photo (JPEG), nil without one.
    public private(set) var photo: Data?
    /// Friends' photos (JPEG) by friend.
    public private(set) var friendPhotos: [UUID: Data] = [:]
    public private(set) var gate: Gate = .hidden
    public private(set) var error: APIError?
    public private(set) var saving = false
    /// Bumps on every change of name or photo, so views that draw them redraw.
    public private(set) var revision = 0

    /// Runs after a save, so stores that show the name (Friends' own card) read it again.
    @ObservationIgnored public var onSaved: (@MainActor () async -> Void)?

    @ObservationIgnored private let service: any ProfileService
    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private var friendVersions: [UUID: Date] = [:]
    @ObservationIgnored private var appleName: PersonNameComponents?
    private static let log = Logger(subsystem: "me.somalabs.flight", category: "profile")

    /// - Parameter defaults: remembers, per account, that onboarding was finished or put off on this device,
    ///   so later launches open straight on the home without waiting for the network. Nil keeps it in memory.
    public init(service: any ProfileService, defaults: UserDefaults? = nil) {
        self.service = service; self.defaults = defaults
    }

    @ObservationIgnored private var memoryDone: Set<UUID> = []

    static func doneKey(_ user: UUID) -> String { "profile.onboarded.\(user.uuidString.lowercased())" }

    private func doneHere(_ user: UUID) -> Bool {
        memoryDone.contains(user) || defaults?.bool(forKey: Self.doneKey(user)) == true
    }

    private func markDone(_ user: UUID) {
        memoryDone.insert(user)
        defaults?.set(true, forKey: Self.doneKey(user))
    }

    // MARK: Loading

    /// Points the store at `owner` (nil: nobody) and reads their profile. The onboarding shows when the
    /// profile was never onboarded, or when it has no name and the user did not put it off on this device.
    /// An account already done on this device opens at once (`.hidden`) and reads in the background; a read
    /// that fails hides it too (it never blocks the app; the next launch asks again).
    public func prepare(owner: UUID?, appleName: PersonNameComponents? = nil) async {
        if owner != self.owner {
            self.owner = owner
            profile = nil; identity = nil; photo = nil; friendPhotos = [:]; friendVersions = [:]; error = nil
            revision += 1
        }
        if let appleName { self.appleName = appleName }
        guard let owner else { gate = .hidden; return }
        gate = doneHere(owner) ? .hidden : (gate == .show ? .show : .unknown)
        await reload()
        guard self.owner == owner else { return }
        if let profile {
            let named = !DisplayName.resolve(typed: profile.displayName, identity: nil).isEmpty
            let needs = profile.onboardedAt == nil || (!named && !doneHere(owner))
            gate = needs ? .show : .hidden
            if !needs { markDone(owner) }
        } else if gate == .unknown {
            gate = .hidden
        }
    }

    /// Reads the profile, the provider identity and the photo again.
    public func reload() async {
        guard let owner else { return }
        identity = await service.identity()?.adding(appleName: appleName)
        do {
            let p = try await service.load()
            guard self.owner == owner else { return }
            profile = p
            error = nil
            if p.avatarPath != nil {
                photo = try? await service.avatar()
            } else {
                photo = nil
            }
            revision += 1
        } catch {
            Self.log.error("Profile read failed: \(String(describing: error), privacy: .public)")
            self.error = error
        }
    }

    /// Reads which friends have a photo and downloads the new or changed ones.
    public func loadFriendPhotos() async {
        guard owner != nil, let refs = try? await service.friendAvatars() else { return }
        let keep = Set(refs.map(\.friendId))
        let stale = refs.filter { friendVersions[$0.friendId] != $0.updatedAt }
        friendPhotos = friendPhotos.filter { keep.contains($0.key) }
        guard !stale.isEmpty, let fresh = try? await service.friendAvatarData(stale) else { return }
        for ref in stale where fresh[ref.friendId] != nil { friendVersions[ref.friendId] = ref.updatedAt }
        friendPhotos.merge(fresh) { _, new in new }
        revision += 1
    }

    // MARK: What the screens show

    /// The name shown for the user: their own, else what the provider gave, never a relay id; empty asks.
    public var displayName: String {
        DisplayName.resolve(typed: profile?.displayName ?? DisplayName.join(first: profile?.firstName ?? "",
                                                                            last: profile?.lastName ?? ""),
                            identity: identity)
    }

    /// Fields prefilled for onboarding or editing.
    public var draft: ProfileDraft { ProfileDraft.prefill(profile: profile, identity: identity) }

    /// The provider's picture (Google), downloaded for onboarding to offer; nil otherwise.
    public func providerPhoto() async -> Data? {
        guard photo == nil, let url = identity?.avatarURL, let raw = await service.providerPhoto(url) else { return nil }
        return AvatarImage.jpeg(from: raw)
    }

    // MARK: Saving

    /// What happens to the photo on save.
    public enum PhotoChange: Equatable, Sendable {
        case keep
        /// A new picture, any format; it is squared, resized and stripped of metadata before upload.
        case set(Data)
        case remove
    }

    /// Saves names and photo; `finishOnboarding` stamps `onboarded_at` and hides the onboarding. True on
    /// success; on failure `error` is set and nothing is hidden.
    @discardableResult
    public func save(firstName: String, lastName: String, photo change: PhotoChange, emoji: String? = nil,
                     finishOnboarding: Bool) async -> Bool {
        guard let owner else { return false }
        saving = true
        defer { saving = false }
        let first = DisplayName.clean(firstName), last = DisplayName.clean(lastName)
        let shown = DisplayName.clean(DisplayName.join(first: first ?? "", last: last ?? ""))
        do throws(APIError) {
            switch change {
            case .keep: break
            case .set(let raw):
                guard let jpeg = AvatarImage.jpeg(from: raw) else { throw APIError.decoding("not a picture") }
                profile = try await service.uploadAvatar(jpeg)
                photo = jpeg
            case .remove:
                profile = try await service.removeAvatar()
                photo = nil
            }
            profile = try await service.save(firstName: first, lastName: last, displayName: shown,
                                             emoji: emoji ?? profile?.emoji, onboarded: finishOnboarding)
            error = nil
        } catch {
            self.error = error
            revision += 1
            return false
        }
        if finishOnboarding {
            markDone(owner)
            gate = .hidden
        }
        revision += 1
        await onSaved?()
        return true
    }

    /// "Later": onboarding goes away for this account and does not come back on this device. The server
    /// stamp is best effort (offline, the device still remembers).
    public func skip() async {
        guard let owner else { return }
        markDone(owner)
        gate = .hidden
        let p = profile
        if let updated = try? await service.save(firstName: p?.firstName, lastName: p?.lastName,
                                                 displayName: p?.displayName, emoji: p?.emoji, onboarded: true) {
            profile = updated
        }
    }

    #if DEBUG
    /// Screenshot runs: shows the onboarding whatever the profile says (`-onboarding <scenario>`).
    public func forceOnboarding() { gate = .show }

    /// Previews and snapshots: the state a screen shows without the service.
    func seed(profile: UserProfile?, identity: AccountIdentity?, photo: Data? = nil, friendPhotos: [UUID: Data] = [:]) {
        owner = profile?.userId
        self.profile = profile; self.identity = identity; self.photo = photo; self.friendPhotos = friendPhotos
        revision += 1
    }
    #endif
}
