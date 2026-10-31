#if os(macOS)
import AppKit
import SwiftUI
import Testing
@testable import FlightKit

/// Screen renders for Task 6b, written to docs/screens/screens (393 pt @3x, dark unless the name
/// says light). Same gate and refresh steps as the component suite:
///
///     SNAPSHOTS=1 swift test --package-path Packages/FlightKit --filter ComponentSnapshotTests
///     python3 Scripts/compare.py
extension ComponentSnapshotTests {
    @discardableResult
    private func screen<V: View>(_ name: String, light: Bool = false, height: CGFloat? = nil,
                                 @ViewBuilder _ content: () -> V) throws -> CGImage {
        try render(name, to: Self.screensDir, light: light) {
            content()
                .frame(height: height)
                .environment(\.airportStaticControls, true)
        }
    }

    /// Cuts a tall render into slices at the given heights (pt), saved as name-1, name-2, ...
    private func slice(_ image: CGImage, _ name: String, at cuts: [CGFloat]) throws {
        let all = [0] + cuts.filter { $0 * 3 < CGFloat(image.height) } + [CGFloat(image.height) / 3]
        for i in 0..<(all.count - 1) {
            let rect = CGRect(x: 0, y: all[i] * 3, width: CGFloat(image.width), height: (all[i + 1] - all[i]) * 3)
            try save(try #require(image.cropping(to: rect)), "\(name)-\(i + 1)", to: Self.screensDir)
        }
    }

    @Test func friendsScreens() async throws {
        let store = FriendsStore(service: FakeFriendsService(now: now))
        await store.load()
        try screen("friends") {
            FriendsView(store: store, onOpenFriend: { _ in }, lookup: PreviewData.airport, now: now, scrolls: false)
        }
        try screen("friends-light", light: true) {
            FriendsView(store: store, onOpenFriend: { _ in }, lookup: PreviewData.airport, now: now, scrolls: false)
        }
        let empty = FriendsStore(service: FakeFriendsService(now: now))
        empty.seed(friends: [], flights: [], me: FriendsMe(friendCode: "DB4GXA3N"))
        try screen("friends-empty") {
            FriendsView(store: empty, onOpenFriend: { _ in }, lookup: PreviewData.airport, now: now, scrolls: false)
        }
    }

    @Test func myFlightsScreens() async throws {
        let full = await MyFlightsPreview.makeStore(.full)
        try screen("my-flights") {
            MyFlightsView(store: full, onSelect: { _ in }, onSearch: {}, lookup: PreviewData.airport, now: now, scrolls: false)
        }
        try screen("my-flights-light", light: true) {
            MyFlightsView(store: full, onSelect: { _ in }, onSearch: {}, lookup: PreviewData.airport, now: now, scrolls: false)
        }
        let empty = await MyFlightsPreview.makeStore(.empty)
        #expect(empty.live.isEmpty && empty.upcoming.isEmpty)
        // Same height as the reference's short home sheet.
        try screen("my-flights-empty", height: 318) {
            MyFlightsView(store: empty, onSelect: { _ in }, onSearch: {}, lookup: PreviewData.airport, now: now, scrolls: false)
        }
        let offline = await MyFlightsPreview.makeStore(.offline)
        #expect(offline.isOffline)
        try screen("my-flights-offline") {
            MyFlightsView(store: offline, onSelect: { _ in }, onSearch: {}, lookup: PreviewData.airport, now: now, scrolls: false)
        }
    }

    @Test func flightDetailScreens() async throws {
        for (mode, name) in [(FlightDetailPreview.Mode.enRoute, "flight-detail"), (.sparse, "flight-detail-sparse"),
                             (.diverted, "flight-detail-diverted"), (.canceled, "flight-detail-canceled")] {
            let store = await FlightDetailPreview.makeStore(mode)
            #expect(store.flight != nil)
            try screen(name) {
                FlightDetailView(store: store, onAirport: { _ in }, now: now, scrolls: false)
            }
        }
    }

    /// Task 15: the v1.1 sheet top (header, countdown, times, empty tiles) and, with details kept, the
    /// filled tiles and the notes card near the bottom.
    @Test func flightDetailV2Screens() async throws {
        let top = await FlightDetailPreview.makeStore(.enRoute)
        #expect(top.details == .empty)
        try screen("flight-detail-v2-top") {
            FlightDetailView(store: top, onAirport: { _ in }, onClose: {}, now: now, scrolls: false)
        }
        let noted = await FlightDetailPreview.makeStore(.noted)
        #expect(noted.details?.seat == "23A")
        try screen("flight-detail-v2-notes") {
            FlightDetailView(store: noted, onAirport: { _ in }, onClose: {}, now: now, scrolls: false)
        }
    }

    @Test func searchScreens() async throws {
        for (mode, name) in [(SearchPreview.Mode.start, "search"), (.results, "search-results"),
                             (.planLimit, "search-plan-limit")] {
            let store = await SearchPreview.makeStore(mode)
            try screen(name, height: mode == .start ? 892 : nil) {
                SearchView(store: store, onFollowed: { _ in }, lookup: SearchPreview.lookup, scrolls: false)
            }
        }
        let limited = await SearchPreview.makeStore(.planLimit)
        #expect(limited.error == .planLimit)
        #expect(limited.text == "AF84")
    }

    @Test func passportScreens() async throws {
        let store = await PassportPreview.makeStore(.full)
        let full = try render("passport-full", write: false) {
            PassportView(store: store, lookup: PreviewData.airport, now: now, scrolls: false)
                .environment(\.airportStaticControls, true)
        }
        try slice(full, "passport", at: [860, 1760])
        let light = try render("passport-light-full", write: false, light: true) {
            PassportView(store: store, lookup: PreviewData.airport, now: now, scrolls: false)
                .environment(\.airportStaticControls, true)
        }
        try save(try #require(light.cropping(to: CGRect(x: 0, y: 0, width: light.width, height: min(light.height, 860 * 3)))),
                 "passport-light-1", to: Self.screensDir)
        let offline = await PassportPreview.makeStore(.offline)
        #expect(offline.isOffline)
        let off = try render("passport-offline-full", write: false) {
            PassportView(store: offline, lookup: PreviewData.airport, now: now, scrolls: false)
                .environment(\.airportStaticControls, true)
        }
        try save(try #require(off.cropping(to: CGRect(x: 0, y: 0, width: off.width, height: min(off.height, 560 * 3)))),
                 "passport-offline", to: Self.screensDir)
    }

    @Test func settingsAndSignIn() async throws {
        let session = SettingsPreview.makeSession(plan: .free, failDelete: false)
        #expect(session.session != nil)
        try screen("settings") {
            SettingsView(session: session, units: .constant(Units()), scrolls: false, dataNote: false)
        }
        let signedOut = SessionStore(auth: FakeAuthService())
        try screen("sign-in", height: 852) {
            SignInView(session: signedOut)
        }
    }
}
#endif
