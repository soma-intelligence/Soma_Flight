#if os(macOS)
import AppKit
import SwiftUI
import Testing
@testable import FlightKit

/// The refined Lot C screens (R5, R6, R8) rendered off screen: Friends with no friend yet (the invite card with
/// the code) and the Profil with its modal header and flat cards. They render without a crash and at the
/// phone width; the PNGs land in the temporary folder for a look beside the Penpot boards.
///
///     swift test --package-path Packages/FlightKit --filter refinedTabs
extension ComponentSnapshotTests {
    static let refinedDir = FileManager.default.temporaryDirectory.appending(path: "flight-refined-tabs")

    @MainActor @Test func refinedTabsFriendsEmpty() throws {
        let store = FriendsStore(service: UnavailableFriendsService())
        store.seed(friends: [], flights: [], me: FriendsMe(friendCode: "K7M2X9QP"))
        for light in [false, true] {
            try render("friends-empty-\(light ? "light" : "dark")", to: Self.refinedDir, light: light) {
                FriendsView(store: store, onOpenFriend: { _ in }, lookup: { _ in nil }, now: PreviewData.now,
                            scrolls: false)
            }
        }
    }

    @MainActor @Test func refinedTabsProfile() async throws {
        let profile = ProfileStore(service: FakeProfileService(.apple))
        await profile.prepare(owner: FakeProfileService.userId)
        let session = UserSession(userId: FakeProfileService.userId, email: nil, usesApple: true)
        for light in [false, true] {
            try render("profile-\(light ? "light" : "dark")", to: Self.refinedDir, light: light) {
                AccountProfileView(session: session, profile: profile, onClose: {}, onDocuments: {},
                                   onSignOut: {}, onDeleteAccount: {}, scrolls: false)
                    .environment(\.travelDocuments, .preview())
            }
        }
    }
}
#endif
