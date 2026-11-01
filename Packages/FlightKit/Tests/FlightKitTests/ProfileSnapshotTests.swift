#if os(macOS)
import AppKit
import SwiftUI
import Testing
@testable import FlightKit

/// Profile onboarding renders, written to docs/screens/screens/onboarding-*.png (393 pt @3x, dark):
///
///     SNAPSHOTS=1 swift test --package-path Packages/FlightKit --filter "ComponentSnapshotTests/profile"
extension ComponentSnapshotTests {
    private func store(_ scenario: FakeProfileService.Scenario) async -> ProfileStore {
        let s = ProfileStore(service: FakeProfileService(scenario, now: now))
        await s.prepare(owner: FakeProfileService.userId)
        return s
    }

    @Test func profileOnboardingScreens() async throws {
        let apple = await store(.apple)
        #expect(apple.gate == .show)
        #expect(apple.draft == ProfileDraft(firstName: "Camille", lastName: "Laurent"))
        try render("onboarding-apple", to: Self.screensDir) {
            ProfileOnboardingView(store: apple).frame(height: 852).environment(\.airportStaticControls, true)
        }
        let email = await store(.email)
        #expect(email.draft == ProfileDraft(), "a relay address never prefills a name")
        try render("onboarding-email", to: Self.screensDir) {
            ProfileOnboardingView(store: email).frame(height: 852).environment(\.airportStaticControls, true)
        }
        // Google: name and picture prefilled (the picture is a drawn stand-in).
        let google = await store(.google)
        _ = await google.save(firstName: "Noa", lastName: "Levi", photo: .set(FakeProfilePhoto.jpeg(hue: 0.08)!),
                              finishOnboarding: false)
        try render("onboarding-google", to: Self.screensDir) {
            ProfileOnboardingView(store: google).frame(height: 852).environment(\.airportStaticControls, true)
        }
        let done = await store(.done)
        try render("onboarding-edit", to: Self.screensDir) {
            ProfileOnboardingView(store: done, mode: .edit).frame(height: 852).environment(\.airportStaticControls, true)
        }
    }

    /// The header's avatar button in its three states, on the sheet's header: photo, initials, no profile.
    @Test func profileHeaderButton() async throws {
        let withPhoto = await store(.done)
        _ = await withPhoto.save(firstName: "Quentin", lastName: "Caron", photo: .set(FakeProfilePhoto.jpeg(hue: 0.58)!),
                                 finishOnboarding: true)
        let initials = await store(.done)
        let nobody = ProfileStore(service: FakeProfileService())
        let full = await MyFlightsPreview.makeStore(.full)
        try render("header-avatar", to: Self.screensDir) {
            VStack(spacing: 0) {
                ForEach(Array([withPhoto, initials, nobody].enumerated()), id: \.offset) { _, profile in
                    MyFlightsView(store: full, onSelect: { _ in }, onSearch: {}, lookup: PreviewData.airport, now: now,
                                  scrolls: false)
                        .frame(height: 120, alignment: .top)
                        .clipped()
                        .overlay(alignment: .topTrailing) {
                            ProfileButton(profile: profile) {}.padding(.top, 19).padding(.trailing, 16)
                        }
                }
            }
            .environment(\.airportStaticControls, true)
        }
    }
}
#endif
