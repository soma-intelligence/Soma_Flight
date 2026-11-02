#if os(macOS)
import AppKit
import SwiftUI
import Testing
@testable import FlightKit

/// Task 12 final pass: every screen and state, dark and light, into docs/screens/final/rendered/<scheme>/
/// (393 pt @3x like the other renders; the Mac settings page at its 480 pt window width). The app
/// captures from the simulator and the Mac window sit beside them in docs/screens/final/ios and mac.
///
///     SNAPSHOTS=1 swift test --package-path Packages/FlightKit --filter "ComponentSnapshotTests/final"
extension ComponentSnapshotTests {
    static let finalDir: URL = outDir.deletingLastPathComponent().appending(path: "final/rendered")

    private func both(_ name: String, height: CGFloat? = nil, maxHeight: CGFloat? = nil, width: CGFloat = ComponentSnapshotTests.width,
                      @ViewBuilder _ content: () -> some View) throws {
        for light in [false, true] {
            let view = content()
                .frame(height: height)
                .environment(\.airportStaticControls, true)
                .frame(width: width)
                .background(Theme.background)
                .environment(\.colorScheme, light ? .light : .dark)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 3
            var image: CGImage?
            NSAppearance(named: light ? .aqua : .darkAqua)!.performAsCurrentDrawingAppearance { image = renderer.cgImage }
            var cg = try #require(image, "no image for \(name)")
            if let maxHeight, CGFloat(cg.height) > maxHeight * 3 {
                cg = try #require(cg.cropping(to: CGRect(x: 0, y: 0, width: cg.width, height: Int(maxHeight * 3))))
            }
            try save(cg, name, to: Self.finalDir.appending(path: light ? "light" : "dark"))
        }
    }

    @Test func finalMyFlights() async throws {
        for (mode, name) in [(MyFlightsPreview.Mode.full, "my-flights"), (.empty, "my-flights-empty"),
                             (.offline, "my-flights-offline"), (.stale, "my-flights-stale"),
                             (.offlineEmpty, "my-flights-offline-empty")] {
            let store = await MyFlightsPreview.makeStore(mode)
            try both(name, height: mode == .empty || mode == .offlineEmpty ? 318 : nil) {
                MyFlightsView(store: store, onSelect: { _ in }, onSearch: {}, lookup: PreviewData.airport, now: now, scrolls: false)
            }
        }
    }

    @Test func finalFlightDetail() async throws {
        for (mode, name) in [(FlightDetailPreview.Mode.enRoute, "flight-detail"), (.sparse, "flight-detail-sparse"),
                             (.canceled, "flight-detail-canceled"), (.diverted, "flight-detail-diverted"),
                             (.error, "flight-detail-error")] {
            let store = await FlightDetailPreview.makeStore(mode)
            #expect(store.flight != nil)
            try both(name) { FlightDetailView(store: store, onAirport: { _ in }, now: now, scrolls: false) }
        }
        let followed = await FlightDetailPreview.makeStore(.enRoute)
        #expect(followed.notify == true)
    }

    @Test func finalSearch() async throws {
        for (mode, name) in [(SearchPreview.Mode.start, "search"), (.results, "search-results"), (.sparse, "search-sparse"),
                             (.notFound, "search-not-found"), (.planLimit, "search-plan-limit"),
                             (.rateLimited, "search-rate-limited")] {
            let store = await SearchPreview.makeStore(mode)
            try both(name, height: mode == .start ? 892 : nil) {
                SearchView(store: store, onFollowed: { _ in }, lookup: SearchPreview.lookup, scrolls: false)
            }
        }
    }

    @Test func finalPassport() async throws {
        for (mode, name) in [(PassportPreview.Mode.full, "passport"), (.sparse, "passport-sparse"), (.empty, "passport-empty"),
                             (.offline, "passport-offline")] {
            let store = await PassportPreview.makeStore(mode)
            try both(name, maxHeight: 1760) { PassportView(store: store, lookup: PreviewData.airport, now: now, scrolls: false) }
        }
    }

    @Test func finalAirport() async throws {
        let store = AirportStore(code: "KAUS", airports: FakeAirportService(now: now))
        await store.load()
        try both("airport", maxHeight: 1930) {
            AirportView(store: store, lookup: PreviewData.airport, now: now, scrolls: false, rowLimit: 22)
        }
    }

    @Test func finalSettingsAndSignIn() async throws {
        let session = SettingsPreview.makeSession(signedIn: true, failDelete: false)
        try both("settings") {
            SettingsView(session: session, units: .constant(Units()), history: FakeHistoryService(), onDeleteAccount: { _ in true },
                         scrolls: false, dataNote: false)
        }
        let failed = SettingsPreview.makeSession(signedIn: true, failDelete: true)
        try both("settings-delete-failed", maxHeight: 400) {
            SettingsView(session: failed, units: .constant(Units(distance: .mi, clock: .h12)), history: FakeHistoryService(),
                         onDeleteAccount: { _ in true }, scrolls: false, dataNote: false)
        }
        try both("settings-mac", width: 480) {
            SettingsView(session: session, units: .constant(Units()), history: FakeHistoryService(), onDeleteAccount: { _ in true },
                         scrolls: false, dataNote: true)
        }
        try both("sign-in", height: 852) { SignInView(session: SessionStore(auth: FakeAuthService())) }
    }
}
#endif

#if os(macOS)
import SwiftUI
import Testing
@testable import FlightKit

/// The lock screen with the 12 hour clock, as the extension shows it once Settings asks for it.
extension LiveActivitySnapshotTests {
    @Test func lockScreen12Hour() throws {
        var a = enRoute, b = lateDeparture
        a.twelveHour = true; b.twelveHour = true
        #expect(a.departureTime.hasSuffix("M"))
        try render("lockscreen-12h", width: 370) {
            VStack(spacing: 12) {
                FlightActivityLockScreenView(a)
                    .background(ActivityPalette.background, in: RoundedRectangle(cornerRadius: 22))
                FlightActivityLockScreenView(b)
                    .background(ActivityPalette.background, in: RoundedRectangle(cornerRadius: 22))
            }
        }
    }
}
#endif
