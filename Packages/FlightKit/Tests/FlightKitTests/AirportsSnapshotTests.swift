#if os(macOS)
import AppKit
import SwiftUI
import Testing
@testable import FlightKit

/// The Airports screens from the fakes, into docs/screens/screens/airports-*.png: the list over the globe,
/// the airport card cut into its parts, and the card of a backend without a board provider.
///
///     SNAPSHOTS=1 swift test --package-path Packages/FlightKit --filter AirportsSnapshotTests
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["SNAPSHOTS"] == "1"))
struct AirportsSnapshotTests {
    let shots = ComponentSnapshotTests()
    var dir: URL { ComponentSnapshotTests.screensDir }
    let now = PreviewData.now
    let directory = AirportDirectory.bundled()

    private func list(live: Bool) async -> AirportsListStore {
        let store = AirportsListStore(service: FakeAirportOverviewService(now: now, live: live), lookup: directory.lookup,
                                      favorites: AirportFavorites(defaults: nil, seed: ["EGLL"]),
                                      tripAirports: { ["KSFO", "KAUS"] })
        await store.load()
        return store
    }

    private func airport(_ code: String, live: Bool) async -> AirportStore {
        let store = AirportStore(code: code, airports: FakeAirportService(now: now),
                                 security: FakeSecurityWaitService(now: now), faa: FakeFAAService(now: now),
                                 overview: FakeAirportOverviewService(now: now, live: live))
        await store.load()
        return store
    }

    private func past() async -> [PastFlight] { (try? await FakeHistoryService().pastFlights()) ?? [] }

    /// The list at the sheet's medium height over the globe, its dots coloured by status.
    @Test func listOverGlobe() async throws {
        let store = await list(live: true)
        let height: CGFloat = 852, sheetTop: CGFloat = 400
        try shots.render("airports-list", to: dir) {
            ZStack(alignment: .top) {
                TestGlobe(airports: store.globe.airports, status: store.globe.status, lookup: directory.lookup)
                    .frame(width: 393, height: sheetTop + 40)
                    .overlay(alignment: .topTrailing) {
                        VStack(spacing: 10) {
                            TestRound(text: "3D", height: 89)
                            TestRound(symbol: "antenna.radiowaves.left.and.right", height: 44)
                        }
                        .padding(.trailing, 12).padding(.top, 54)
                    }
                AirportsListView(store: store, onOpen: { _ in }, onClose: {}, scrolls: false)
                    .frame(width: 393, height: height - sheetTop, alignment: .top)
                    .clipShape(UnevenRoundedRectangle(topLeadingRadius: 38, topTrailingRadius: 38, style: .continuous))
                    .offset(y: sheetTop)
            }
            .frame(width: 393, height: height, alignment: .top)
            .clipped()
            .background(Color.black)
        }
        // The whole list too, for review.
        let whole = try shots.render("airports-list-full", write: false) {
            AirportsListView(store: store, onOpen: { _ in }, onClose: {}, scrolls: false)
        }
        try shots.save(try redraw(whole, top: 0, height: min(CGFloat(whole.height) / 3, 2400)), "airports-list-full", to: dir)
    }

    @Test func listWithoutProvider() async throws {
        let store = await list(live: false)
        let full = try shots.render("airports-list-no-provider", write: false) {
            AirportsListView(store: store, onOpen: { _ in }, onClose: {}, scrolls: false)
        }
        try shots.save(try #require(full.cropping(to: CGRect(x: 0, y: 0, width: full.width, height: min(full.height, 852 * 3)))),
                       "airports-list-no-provider", to: dir)
    }

    /// The airport card, cut where each part starts.
    @Test func detail() async throws {
        let store = await airport("KSFO", live: true)
        let flights = await past()
        let full = try shots.render("airports-detail-full", write: false) {
            AirportView(store: store, lookup: directory.lookup, now: now, scrolls: false, rowLimit: 1,
                        pastFlights: flights)
                .environment(\.airportStaticControls, true)
                .fixedSize(horizontal: false, vertical: true)
        }
        try saveSlices(full, names: ["top", "weather", "daily", "stats", "regulars"])
        let calm = await airport("KATL", live: true)
        let top = try shots.render("airports-detail-calm", write: false) {
            AirportView(store: calm, lookup: directory.lookup, now: now, scrolls: false, rowLimit: 6, pastFlights: flights)
                .environment(\.airportStaticControls, true)
                .fixedSize(horizontal: false, vertical: true)
        }
        try shots.save(try redraw(top, top: 0, height: min(CGFloat(top.height) / 3, 1000)), "airports-detail-calm", to: dir)
        try shots.render("airports-bottom-bar", to: dir) {
            AirportBottomBar(isFavorite: true, hasBoards: true, shareImage: nil, shareTitle: "", onDepartures: {},
                             onArrivals: {}, onFavorite: {}, copyCode: "SFO")
                .padding(.vertical, 20)
        }
    }

    @Test func detailWithoutProvider() async throws {
        let store = await airport("KSFO", live: false)
        let full = try shots.render("airports-no-provider-full", write: false) {
            AirportView(store: store, lookup: directory.lookup, now: now, scrolls: false, rowLimit: 6)
                .environment(\.airportStaticControls, true)
                .fixedSize(horizontal: false, vertical: true)
        }
        try shots.save(try #require(full.cropping(to: CGRect(x: 0, y: 0, width: full.width, height: min(full.height, 1300 * 3)))),
                       "airports-no-provider", to: dir)
    }

    /// A part of a tall render copied into its own bitmap: ImageIO cannot write a crop of an image taller
    /// than 16,384 pixels.
    private func redraw(_ image: CGImage, top: CGFloat, height: CGFloat) throws -> CGImage {
        let w = image.width, h = Int(height * 3)
        let ctx = try #require(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let crop = try #require(image.cropping(to: CGRect(x: 0, y: Int(top * 3), width: w, height: h)))
        ctx.draw(crop, in: CGRect(x: 0, y: 0, width: w, height: h))
        return try #require(ctx.makeImage())
    }

    /// Cuts a tall render into its parts at fixed heights (pt), checked by eye against the render.
    private func saveSlices(_ full: CGImage, names: [String]) throws {
        let total = CGFloat(full.height) / 3
        let ranges: [(CGFloat, CGFloat)] = [(0, 1000), (1530, 2620), (2620, 3470), (3470, 4215), (4215, 4860)]
        for (name, (top, bottom)) in zip(names, ranges) where top < total {
            try shots.save(try redraw(full, top: top, height: min(bottom, total) - top), "airports-detail-\(name)", to: dir)
        }
    }
}

/// A stand-in for the map control, drawn flat (glass does not render off screen).
private struct TestRound: View {
    var text: String?
    var symbol: String?
    var height: CGFloat

    init(text: String? = nil, symbol: String? = nil, height: CGFloat) {
        self.text = text; self.symbol = symbol; self.height = height
    }

    var body: some View {
        Group {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 16, weight: .semibold))
            } else {
                VStack(spacing: 22) {
                    Text(text ?? "").font(.system(size: 15, weight: .semibold, design: .rounded))
                    Image(systemName: "map").font(.system(size: 16, weight: .medium))
                }
            }
        }
        .foregroundStyle(.white)
        .frame(width: 44, height: height)
        .background(Capsule().fill(Color.white.opacity(0.16)))
        .overlay(Capsule().stroke(Color.white.opacity(0.25), lineWidth: 0.5))
    }
}

/// MapKit does not render off screen: an orthographic globe of the Passport's land outline, with a dot per
/// listed airport in its status colour, stands in for it.
private struct TestGlobe: View {
    var airports: [Airport]
    var status: [String: AirportStatusLevel]
    var lookup: (String) -> Airport?
    var centre = (lon: -38.0, lat: 34.0)

    private func project(_ lon: Double, _ lat: Double, _ r: CGFloat, _ c: CGPoint) -> CGPoint? {
        let φ = lat * .pi / 180, λ = lon * .pi / 180
        let φ0 = centre.lat * .pi / 180, λ0 = centre.lon * .pi / 180
        let cosc = sin(φ0) * sin(φ) + cos(φ0) * cos(φ) * cos(λ - λ0)
        guard cosc >= 0 else { return nil }
        let x = cos(φ) * sin(λ - λ0)
        let y = cos(φ0) * sin(φ) - sin(φ0) * cos(φ) * cos(λ - λ0)
        return CGPoint(x: c.x + CGFloat(x) * r, y: c.y - CGFloat(y) * r)
    }

    /// Where a hidden point shows on the rim: its direction from the centre, at the globe's radius.
    private func rim(_ lon: Double, _ lat: Double, _ r: CGFloat, _ c: CGPoint) -> CGPoint {
        let φ = lat * .pi / 180, λ = lon * .pi / 180
        let φ0 = centre.lat * .pi / 180, λ0 = centre.lon * .pi / 180
        let x = cos(φ) * sin(λ - λ0)
        let y = cos(φ0) * sin(φ) - sin(φ0) * cos(φ) * cos(λ - λ0)
        let n = max(1e-9, hypot(x, y))
        return CGPoint(x: c.x + CGFloat(x / n) * r, y: c.y - CGFloat(y / n) * r)
    }

    var body: some View {
        Canvas { ctx, size in
            let r = size.width * 0.82
            let c = CGPoint(x: size.width / 2, y: size.height * 0.62 + r * 0.2)
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(red: 0.02, green: 0.03, blue: 0.06)))
            let disc = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
            ctx.fill(disc, with: .linearGradient(Gradient(colors: [Color(red: 0.06, green: 0.13, blue: 0.24),
                                                                  Color(red: 0.03, green: 0.07, blue: 0.14)]),
                                                 startPoint: CGPoint(x: c.x, y: c.y - r), endPoint: CGPoint(x: c.x, y: c.y + r)))
            // Points behind the globe are pulled onto its rim, so a coast that turns away follows the edge.
            let landColor = Color(red: 0.17, green: 0.22, blue: 0.27)
            for ring in WorldLand.shared.rings {
                guard ring.contains(where: { project($0.x, $0.y, r, c) != nil }) else { continue }
                var land = Path(), last: CGPoint?
                for p in ring {
                    let q = project(p.x, p.y, r, c) ?? rim(p.x, p.y, r, c)
                    if let l = last, hypot(q.x - l.x, q.y - l.y) < r * 0.5 { land.addLine(to: q) } else { land.move(to: q) }
                    last = q
                }
                ctx.fill(land, with: .color(landColor))
            }
            ctx.stroke(disc, with: .color(.white.opacity(0.08)), lineWidth: 1)
            for a in airports {
                guard let q = project(a.lon, a.lat, r, c) else { continue }
                let color = AirportStatusColor.of(status[a.id] ?? .normal)
                ctx.fill(Path(ellipseIn: CGRect(x: q.x - 9, y: q.y - 9, width: 18, height: 18)), with: .color(color.opacity(0.25)))
                ctx.fill(Path(ellipseIn: CGRect(x: q.x - 5, y: q.y - 5, width: 10, height: 10)), with: .color(color))
                ctx.stroke(Path(ellipseIn: CGRect(x: q.x - 5, y: q.y - 5, width: 10, height: 10)), with: .color(.white.opacity(0.7)),
                           lineWidth: 1)
            }
        }
    }
}
#endif
