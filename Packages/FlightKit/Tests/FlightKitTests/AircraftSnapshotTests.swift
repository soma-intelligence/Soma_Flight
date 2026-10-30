#if os(macOS)
import AppKit
import ImageIO
import SwiftUI
import Testing
import UniformTypeIdentifiers
@testable import FlightKit

/// Renders our side views, plain scheme, 1200 px wide, into docs/screens/components/side-views-<family>.png
/// (each family with its variants under it) for visual review, then compare against the references:
///
///     SNAPSHOTS=1 swift test --package-path Packages/FlightKit --filter AircraftSnapshotTests
///     python3 Scripts/compare.py v2-aircraft-b777 v2-aircraft-b787
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["SNAPSHOTS"] == "1"))
struct AircraftSnapshotTests {
    static let width: CGFloat = 400
    static let outDir: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "docs/screens/components")

    /// The family's default first, then its other variants.
    static let sheets: [(name: String, family: AircraftFamily, variants: [String])] = [
        ("a320", .a320, ["A319", "A320", "A321"]),
        ("a350", .a350, ["A359", "A35K"]),
        ("b737", .b737, ["B738", "B737", "B739"]),
        ("b737max", .b737max, ["B38M", "B37M", "B3XM"]),
        ("b777", .b777, ["B77W", "B772"]),
        ("b787", .b787, ["B789", "B788", "B78X"]),
        ("generic", .other, ["", "A333"]),
    ]

    func render<V: View>(_ name: String, @ViewBuilder _ content: () -> V) throws {
        let view = content()
            .frame(width: Self.width)
            .background(Color(red: 0.87, green: 0.91, blue: 0.97))
            .environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 3
        let cg = try #require(renderer.cgImage, "no image for \(name)")
        #expect(cg.width == 1200)
        try FileManager.default.createDirectory(at: Self.outDir, withIntermediateDirectories: true)
        let url = Self.outDir.appending(path: "\(name).png")
        let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, cg, nil)
        #expect(CGImageDestinationFinalize(dest))
    }

    @Test func sideViews() throws {
        let reference = ReferenceData.bundled()
        for sheet in Self.sheets {
            let types: [AircraftType?] = sheet.variants.map { id in
                if id.isEmpty { return nil }
                return reference.type(id) ?? AircraftType(id: id, family: sheet.family, manufacturer: "", name: id)
            }
            // Variants drawn at one metre scale so their lengths compare.
            let longest = types.map { AircraftGeometry.geometry(type: $0).lengthM }.max() ?? 1
            try render("side-views-\(sheet.name)") {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(types.enumerated()), id: \.offset) { i, type in
                        let g = AircraftGeometry.geometry(type: type)
                        VStack(alignment: .leading, spacing: 2) {
                            AircraftSideView(type: type)
                                .frame(width: (Self.width - 24) * g.lengthM / longest)
                            Text(type?.name ?? "Generic").font(.system(size: 7, weight: .medium)).foregroundStyle(.secondary)
                        }
                        .padding(.top, i == 0 ? 0 : 6)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
#endif
