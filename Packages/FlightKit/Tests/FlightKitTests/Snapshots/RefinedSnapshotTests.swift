#if os(macOS)
import AppKit
import SnapshotTesting
import SwiftUI
import Testing
@testable import FlightKit

/// Image snapshots of the shared components (D10, A13), asserted against the references recorded in
/// `__Snapshots__/RefinedSnapshotTests/`. Each specimen is the one `ComponentGallery` shows, drawn 393 pt
/// wide in an `NSHostingView`, light and dark, at the default text size; the rows and the action bar again
/// at `.accessibility3`, and the rows with the extreme content of A13 (very long airport names, a missing
/// airline name, an emoji friend name).
///
/// The data is the seed at its own "now", the locale en_US, the clock 24 h, and animations are off.
/// A missing reference is recorded and the test fails once; run again to assert. To record everything
/// again after a deliberate change:
///
///     SNAPSHOT_TESTING_RECORD=all swift test --package-path Packages/FlightKit --filter RefinedSnapshotTests
///
/// References are drawn by macOS: record and assert on the same major macOS version.
@MainActor
@Suite(.serialized)
struct RefinedSnapshotTests {
    static let width: CGFloat = 393

    enum Look: String, CaseIterable { case light, dark }

    /// Draws `content` the way the app's sheet does and compares it with the reference `name`.
    func assertLook<V: View>(_ content: V, named name: String, look: Look, size: DynamicTypeSize = .large,
                             fileID: StaticString = #fileID, file: StaticString = #filePath,
                             testName: String = #function, line: UInt = #line, column: UInt = #column) {
        let dark = look == .dark
        let root = content
            .padding(.vertical, 16)
            .frame(width: Self.width, alignment: .topLeading)
            .fixedSize(horizontal: false, vertical: true)
            .background(Theme.background)
            .dynamicTypeSize(size)
            .environment(\.colorScheme, dark ? .dark : .light)
            .environment(\.locale, Locale(identifier: "en_US"))
            .environment(\.timeZone, TimeZone(identifier: "UTC")!)
            .environment(\.units, Units(distance: .km, clock: .h24))
            .transaction { $0.disablesAnimations = true; $0.animation = nil }
        let host = NSHostingView(rootView: root)
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        host.appearance = appearance
        // A window gives the view its backing scale and appearance, as on screen.
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: Self.width, height: 100),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance
        window.contentView = host
        let fitting = host.fittingSize
        host.frame = CGRect(origin: .zero, size: CGSize(width: Self.width, height: ceil(fitting.height)))
        window.setContentSize(host.frame.size)
        host.layoutSubtreeIfNeeded()
        host.display()
        let view: NSView = host
        assertSnapshot(of: view, as: .image(precision: 0.995, perceptualPrecision: 0.98),
                       named: "\(name)-\(size)-\(look.rawValue)",
                       fileID: fileID, file: file, testName: testName, line: line, column: column)
        window.contentView = nil
    }

    // MARK: Every specimen, light and dark

    @Test(arguments: GallerySpecimen.allCases)
    func specimen(_ specimen: GallerySpecimen) {
        for look in Look.allCases {
            assertLook(specimen.view(long: false), named: specimen.title, look: look)
        }
    }

    // MARK: Accessibility sizes (A12)

    /// At accessibility sizes the action bar drops its labels: icons only.
    @Test func actionBarIconsOnlyAtAccessibilitySize() {
        for look in Look.allCases {
            assertLook(GallerySpecimen.actionBar.view(long: false), named: "GlassActionBar", look: look,
                       size: .accessibility3)
        }
    }

    // MARK: Extreme content (A13)

    /// Very long airport names, a flight without its airline, an emoji name: at the default size and at
    /// `.accessibility3`, nothing overlaps and the rows grow instead of clipping.
    @Test(arguments: [GallerySpecimen.myFlightRow, .boardRow, .friendRow])
    func extremeContent(_ specimen: GallerySpecimen) {
        for size in [DynamicTypeSize.large, .accessibility3] {
            for look in Look.allCases {
                assertLook(specimen.view(long: true), named: "\(specimen.title)-long", look: look, size: size)
            }
        }
    }

    /// The rows at `.accessibility3` with the seed's ordinary content.
    @Test(arguments: [GallerySpecimen.myFlightRow, .boardRow, .friendRow])
    func rowsAtAccessibilitySize(_ specimen: GallerySpecimen) {
        for look in Look.allCases {
            assertLook(specimen.view(long: false), named: specimen.title, look: look, size: .accessibility3)
        }
    }

    // MARK: The fixtures themselves

    /// The extreme fixtures really are extreme, so the references above keep testing what A13 asks.
    @Test func fixturesAreExtreme() throws {
        let f = try #require(PreviewData.followed.first)
        let long = try #require(GalleryFixtures.longAirport(f.originIcao))
        #expect(long.city.count > 50)
        #expect(GalleryFixtures.emojiFriend.displayName?.unicodeScalars.allSatisfy { $0.properties.isEmoji || $0.value == 0xFE0F } == true)
        #expect(GallerySpecimen.allCases.count == 16)
    }
}
#endif
