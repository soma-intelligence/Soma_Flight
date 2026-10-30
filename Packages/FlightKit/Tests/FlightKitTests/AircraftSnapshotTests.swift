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
        ("a220", .a220, ["BCS3", "BCS1"]),
        ("a330", .a330, ["A333", "A332", "A339", "A338"]),
        ("a380", .a380, ["A388"]),
        ("b747", .b747, ["B744", "B748", "B74S"]),
        ("b757", .b757, ["B752", "B753"]),
        ("b767", .b767, ["B763", "B762", "B764"]),
        ("ejet", .ejet, ["E190", "E170", "E175", "E195", "E290", "E295"]),
        ("crj", .crj, ["CRJ9", "CRJ2", "CRJ7", "CRJX"]),
        ("atr", .atr, ["AT76", "AT46"]),
        ("generic", .other, ["", "A346"]),
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
                            AircraftSideView(type: type, gearDown: true)
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
    // MARK: Liveries

    static let liveryDir: URL = outDir.deletingLastPathComponent().appending(path: "liveries")
    static let repoRoot: URL = outDir.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// Seed airlines on every drawn family they fly, then derived liveries on one family each.
    static let liveryMatrix: [(icao: String, family: String, type: String)] = [
        ("UAL", "a320", "A320"), ("UAL", "b737", "B739"), ("UAL", "b737max", "B39M"), ("UAL", "b777", "B77W"),
        ("UAL", "b787", "B789"),
        ("AFR", "a320", "A320"), ("AFR", "a350", "A359"), ("AFR", "b777", "B77W"), ("AFR", "b787", "B789"),
        ("RYR", "b737", "B738"), ("RYR", "b737max", "B38M"),
        ("DLH", "a350", "A359"), ("ACA", "b787", "B789"), ("TRA", "b737", "B738"), ("BEL", "a320", "A320"),
        ("FLE", "b737max", "B38M"),
        // The remaining families: seed liveries, then a derived one on each.
        ("UAL", "b757", "B752"), ("UAL", "b767", "B763"), ("AFR", "a220", "BCS3"), ("AFR", "a330", "A332"),
        ("ACA", "a220", "BCS3"), ("BEL", "a330", "A333"), ("DLH", "a380", "A388"), ("DLH", "b747", "B748"),
        ("DAL", "b757", "B752"), ("DAL", "b767", "B763"), ("KLM", "ejet", "E190"), ("SKW", "crj", "CRJ9"),
        ("ANZ", "atr", "AT76"),
    ]

    /// The entries from the remaining families, on their own sheet.
    static let remainingFamilies: Set<String> = ["a220", "a330", "a380", "b747", "b757", "b767", "ejet", "crj", "atr"]

    /// What production serves as `.logo`: the Commons symbol when one was cropped
    /// (assets/logos/commons/symbol/png), else the full logo (a wordmark, which never goes on a fin).
    static func brandService() -> FakeBrandAssetService {
        var seeded: [(icao: String, kind: BrandAssetKind, asset: BrandAsset)] = []
        for icao in Set(liveryMatrix.map(\.icao)) {
            let symbol = repoRoot.appending(path: "assets/logos/commons/symbol/png/\(icao).png")
            let full = repoRoot.appending(path: "assets/logos/commons/png/\(icao).png")
            if let data = (try? Data(contentsOf: symbol)) ?? (try? Data(contentsOf: full)) {
                seeded.append((icao, .logo, BrandAsset(data: data, format: "png", version: "snapshot")))
            }
        }
        return FakeBrandAssetService(seeded: seeded)
    }

    func write(_ cg: CGImage, to url: URL) throws {
        let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, cg, nil)
        #expect(CGImageDestinationFinalize(dest))
    }

    @Test func liveries() async throws {
        let reference = ReferenceData.bundled()
        let service = Self.brandService()
        AircraftArtMemo.shared.removeAll()
        await AircraftSideView.preload(Self.liveryMatrix.map(\.icao), service: service)
        try FileManager.default.createDirectory(at: Self.liveryDir, withIntermediateDirectories: true)
        let sky = Color(red: 0.87, green: 0.91, blue: 0.97)
        func plane(_ entry: (icao: String, family: String, type: String), width: CGFloat) -> some View {
            let type = reference.type(entry.type)
            return AircraftSideView(type: type, livery: reference.livery(entry.icao))
                .frame(width: width)
                .environment(\.brandAssets, service)
        }
        for entry in Self.liveryMatrix {
            let view = plane(entry, width: 400).padding(12).background(sky).environment(\.colorScheme, .light)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 3
            let cg = try #require(renderer.cgImage)
            try write(cg, to: Self.liveryDir.appending(path: "\(entry.icao)-\(entry.family).png"))
        }
        let remaining = Self.liveryMatrix.filter { Self.remainingFamilies.contains($0.family) }
        for (name, entries) in [("sheet", Self.liveryMatrix), ("sheet-remaining-families", remaining)] {
            let sheet = VStack(alignment: .leading, spacing: 14) {
                ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                    VStack(alignment: .leading, spacing: 2) {
                        plane(entry, width: 380)
                        Text("\(entry.icao) \(reference.type(entry.type)?.name ?? entry.type)\(LiverySeed.all[entry.icao] == nil ? ", derived" : ", seed")")
                            .font(.system(size: 7, weight: .medium)).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(12)
            .frame(width: 404, alignment: .leading)
            .background(sky)
            .environment(\.colorScheme, .light)
            let renderer = ImageRenderer(content: sheet)
            renderer.scale = 3
            let cg = try #require(renderer.cgImage)
            try write(cg, to: Self.liveryDir.appending(path: "\(name).png"))
        }
        AircraftArtMemo.shared.removeAll()
    }
}
#endif
