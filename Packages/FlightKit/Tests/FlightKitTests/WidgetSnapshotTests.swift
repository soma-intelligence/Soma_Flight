#if os(macOS)
import AppKit
import Foundation
import ImageIO
import SwiftUI
import Testing
import UniformTypeIdentifiers
@testable import FlightKit

/// Renders the widgets' views into docs/screens/widget-*.png at the iPhone 17 Pro's widget sizes, for a
/// look without a simulator. Off by default, like the other snapshots:
///
///     SNAPSHOTS=1 swift test --package-path Packages/FlightKit --filter WidgetSnapshotTests
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["SNAPSHOTS"] == "1"))
struct WidgetSnapshotTests {
    static let outDir: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "docs/screens")

    let now = Date(timeIntervalSince1970: 1_792_770_120)

    var displays: [FlightWidgetDisplay] {
        WidgetSnapshot.preview(now: now).flights(at: now).map { FlightWidgetDisplay($0, at: now) }
    }

    /// A home screen widget: its content inset by the system's 16 pt margins on the dark background.
    func tile<V: View>(_ w: CGFloat, _ h: CGFloat, @ViewBuilder _ content: () -> V) -> some View {
        content().padding(16).frame(width: w, height: h)
            .background(ActivityPalette.background, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    func render<V: View>(_ name: String, @ViewBuilder _ content: () -> V) throws {
        let view = content().padding(16).background(Color(white: 0.35)).environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 3
        var image: CGImage?
        NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance { image = renderer.cgImage }
        let cg = try #require(image)
        try FileManager.default.createDirectory(at: Self.outDir, withIntermediateDirectories: true)
        let url = Self.outDir.appending(path: "widget-\(name).png")
        let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, cg, nil)
        #expect(CGImageDestinationFinalize(dest))
    }

    @Test func homeScreen() throws {
        let d = displays
        try render("home") {
            VStack(spacing: 16) {
                HStack(spacing: 16) {
                    tile(170, 170) { NextFlightSmallView(d[0]) }
                    tile(170, 170) { NextFlightSmallView(d[1]) }
                }
                tile(364, 170) { NextFlightMediumView(d[0]) }
                tile(364, 170) { NextFlightMediumView(d[1]) }
                tile(364, 382) { UpcomingFlightsLargeView(d, linked: false) }
                HStack(spacing: 16) {
                    tile(170, 170) { FlightWidgetEmptyView(.small) }
                    Spacer()
                }
                .frame(width: 364)
            }
        }
    }

    @Test func lockScreen() throws {
        let d = displays
        try render("lockscreen") {
            VStack(alignment: .leading, spacing: 16) {
                NextFlightInlineView(d[1])
                HStack(spacing: 16) {
                    NextFlightRectangularView(d[0]).frame(width: 170, height: 76)
                    NextFlightRectangularView(d[1]).frame(width: 170, height: 76)
                }
                HStack(spacing: 16) {
                    NextFlightCircularView(d[0]).frame(width: 76, height: 76)
                    NextFlightCircularView(d[1]).frame(width: 76, height: 76)
                    FlightWidgetEmptyView(.circular).frame(width: 76, height: 76)
                }
            }
            .foregroundStyle(.white)
        }
    }
}
#endif
