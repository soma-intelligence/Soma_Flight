#if os(macOS)
import AppKit
import SwiftUI
import Testing
import UniformTypeIdentifiers
@testable import FlightKit

/// The home sheet's three detents drawn on a whole iPhone 17 Pro screen (402 x 874 pt), for a check
/// without a simulator: a stand-in map, the map controls, and the real tab screen in `HomeSheetBody` at
/// each detent's height. Written to $SHEET_RENDER_DIR (else docs/screens/sheet):
///
///     SNAPSHOTS=1 swift test --package-path Packages/FlightKit --filter SheetGeometrySnapshotTests
///
/// ImageRenderer draws no Liquid Glass, so the pill and the controls show flat.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["SNAPSHOTS"] == "1"))
struct SheetGeometrySnapshotTests {
    let geometry = SheetGeometry.standard
    let width: CGFloat = 402
    let now = PreviewData.now

    var outDir: URL {
        if let dir = ProcessInfo.processInfo.environment["SHEET_RENDER_DIR"] { return URL(fileURLWithPath: dir) }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "docs/screens/sheet")
    }

    @Test func passportInEachDetent() async throws {
        let store = await PassportPreview.makeStore(.full)
        for detent in SheetDetent.allCases {
            try render("sheet-passport-\(detent)", detent: detent, tab: .passport) {
                PassportView(store: store, lookup: PreviewData.airport, now: now, scrolls: false)
            }
        }
    }

    @Test func myFlightsInEachDetent() async throws {
        let store = await MyFlightsPreview.makeStore(.full)
        for detent in SheetDetent.allCases {
            try render("sheet-my-flights-\(detent)", detent: detent, tab: .flights) {
                MyFlightsView(store: store, onSelect: { _ in }, onSearch: {}, lookup: PreviewData.airport, now: now,
                              scrolls: false)
            }
        }
    }

    private func render<V: View>(_ name: String, detent: SheetDetent, tab: HomeTab,
                                 @ViewBuilder _ screen: () -> V) throws {
        let g = geometry
        let view = ZStack(alignment: .topLeading) {
            mapStandIn
            controls
                .opacity(detent == .expanded ? 0 : 1)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.trailing, 12)
                .padding(.top, g.safeTop + 8)
            HomeSheetBody(tab: .constant(tab), onSearch: {}) {
                screen()
                    .environment(\.airportStaticControls, true)
                    .overlay(alignment: .topTrailing) {
                        Circle().fill(Color.gray).frame(width: 44, height: 44)
                            .padding(.top, 19).padding(.trailing, 16)
                    }
            } toast: { EmptyView() }
            // The sheet's own bottom safe area, which the pill reaches 14 pt into.
            .padding(.bottom, g.safeBottom)
            // Where the glass pill and search button sit (ImageRenderer leaves glass blank).
            .overlay(alignment: .bottom) {
                HStack(spacing: 10) {
                    Capsule().fill(.white.opacity(0.14))
                    Circle().fill(.white.opacity(0.14)).frame(width: 59)
                }
                .frame(height: 59)
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
            .frame(width: width, height: g.height(of: detent))
            .background(Theme.background)
            .clipShape(UnevenRoundedRectangle(topLeadingRadius: Theme.sheetRadius, topTrailingRadius: Theme.sheetRadius))
            .offset(y: g.top(of: detent))
        }
        .frame(width: width, height: g.screenHeight, alignment: .topLeading)
        .clipped()
        .environment(\.colorScheme, .dark)

        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        var image: CGImage?
        NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance { image = renderer.cgImage }
        let cg = try #require(image, "no image for \(name)")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let url = outDir.appending(path: "\(name).png")
        let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, cg, nil)
        #expect(CGImageDestinationFinalize(dest))
    }

    /// A flat stand-in for the globe: a dark sea with a faint grid, and the status bar's band.
    private var mapStandIn: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(red: 0.07, green: 0.12, blue: 0.2)))
            var grid = Path()
            for x in stride(from: 0, through: size.width, by: 40) { grid.move(to: CGPoint(x: x, y: 0)); grid.addLine(to: CGPoint(x: x, y: size.height)) }
            for y in stride(from: 0, through: size.height, by: 40) { grid.move(to: CGPoint(x: 0, y: y)); grid.addLine(to: CGPoint(x: size.width, y: y)) }
            context.stroke(grid, with: .color(.white.opacity(0.06)), lineWidth: 1)
        }
        .frame(width: width, height: geometry.screenHeight)
    }

    private var controls: some View {
        VStack(spacing: 0) {
            Text("3D").font(.system(size: 15, weight: .semibold, design: .rounded)).frame(width: 44, height: 44)
            Rectangle().fill(.white.opacity(0.18)).frame(width: 24, height: 1)
            Image(systemName: "map.fill").frame(width: 44, height: 44)
        }
        .foregroundStyle(.white)
        .background(Capsule().fill(.white.opacity(0.15)))
    }
}
#endif
