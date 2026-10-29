#if os(macOS)
import AppKit
import ImageIO
import SwiftUI
import Testing
import UniformTypeIdentifiers
@testable import FlightKit

/// Renders each shared component from seed data (dark, 393 pt wide, @3x, default Dynamic Type)
/// into docs/screens/components/<Name>.png for visual review. Map views cannot go through
/// ImageRenderer, so GlobeMap is not here.
///
/// Off by default so a normal test run leaves the tree clean. Refresh the PNGs, then the
/// side-by-side reference comparisons, with:
///
///     SNAPSHOTS=1 swift test --package-path Packages/FlightKit --filter ComponentSnapshotTests
///     python3 Scripts/compare.py
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["SNAPSHOTS"] == "1"))
struct ComponentSnapshotTests {
    static let width: CGFloat = 393
    static let outDir: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "docs/screens/components")

    static let screensDir: URL = outDir.deletingLastPathComponent().appending(path: "screens")

    @discardableResult
    func render<V: View>(_ name: String, to dir: URL = outDir, write: Bool = true, light: Bool = false,
                                 @ViewBuilder _ content: () -> V) throws -> CGImage {
        let view = content()
            .frame(width: Self.width)
            .background(Theme.background)
            .environment(\.colorScheme, light ? .light : .dark)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 3
        var image: CGImage?
        NSAppearance(named: light ? .aqua : .darkAqua)!.performAsCurrentDrawingAppearance { image = renderer.cgImage }
        let cg = try #require(image, "no image for \(name)")
        #expect(cg.width == Int(Self.width * 3))
        if write { try save(cg, name, to: dir) }
        return cg
    }

    func save(_ cg: CGImage, _ name: String, to dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: "\(name).png")
        let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, cg, nil)
        #expect(CGImageDestinationFinalize(dest))
    }

    let now = PreviewData.now
    let tz = PreviewData.kaus.timeZone

    @Test func boardRow() throws {
        let flights = Array(PreviewData.board("KAUS", .departures).flights[2..<8])
        try render("BoardRow") {
            VStack(spacing: 0) {
                ForEach(Array(flights.enumerated()), id: \.element.id) { i, f in
                    BoardRow(flight: f, kind: .departures, airport: PreviewData.airport(f.destinationIcao),
                             timeZone: tz, now: now, striped: !i.isMultiple(of: 2))
                }
            }
        }
        let arrivals = Array(PreviewData.board("KAUS", .arrivals).flights[0..<6])
        try render("BoardRow-arrivals") {
            VStack(spacing: 0) {
                ForEach(Array(arrivals.enumerated()), id: \.element.id) { i, f in
                    BoardRow(flight: f, kind: .arrivals, airport: PreviewData.airport(f.originIcao),
                             timeZone: tz, now: now, striped: !i.isMultiple(of: 2))
                }
                BoardRow(flight: PreviewData.sparse, kind: .departures, airport: nil, timeZone: tz, now: now, striped: true)
            }
        }
    }

    @Test func performanceSplit() throws {
        try render("PerformanceSplit") {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader("Departures", subtitle: "How today is going so far")
                PerformanceSplit(stats: PreviewData.stats("KAUS"))
            }
            .padding(20)
        }
    }

    @Test func delayChart() throws {
        try render("DelayChart") {
            VStack(alignment: .leading, spacing: 2) {
                SectionHeader("Departures per hour", info: true)
                DelayChart(perHour: PreviewData.stats("KAUS").perHour, timeZone: tz, now: now)
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
        }
    }

    @Test func delayTrendChart() throws {
        try render("DelayTrendChart") {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader("Departure delays", subtitle: "Average, actual then estimated", info: true)
                DelayTrendChart(flights: PreviewData.board("KAUS", .departures).flights.filter {
                    abs(($0.scheduledOut ?? .distantPast).timeIntervalSince(now)) < 4 * 3600
                }, kind: .departures, timeZone: tz, now: now, binMinutes: 20, windowMinutes: 60)
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
        }
    }

    @Test func weatherBlock() throws {
        try render("WeatherBlock") {
            VStack(alignment: .leading, spacing: 0) {
                SectionHeader("Current Weather", subtitle: "Observed at AUS", large: true)
                    .padding(.bottom, 10)
                WeatherBlock(weather: PreviewData.weather["KAUS"]!, timeZone: tz, now: now)
            }
            .padding(20)
        }
    }

    @Test func flightCard() throws {
        try render("FlightCard") {
            VStack(spacing: 12) {
                ForEach(PreviewData.followed) { f in
                    FlightCard(flight: f, origin: PreviewData.airport(f.originIcao),
                               destination: PreviewData.airport(f.destinationIcao), now: now)
                }
            }
            .padding(16)
        }
    }

    @Test func flightTimeline() throws {
        try render("FlightTimeline") {
            VStack(alignment: .leading, spacing: 28) {
                FlightTimeline(flight: PreviewData.enRoute, origin: PreviewData.airport("LFPG"),
                               destination: PreviewData.airport("KSFO"), now: now)
                FlightTimeline(flight: PreviewData.sparse, origin: PreviewData.airport("KSEA"),
                               destination: PreviewData.airport("KSFO"), now: now)
            }
            .padding(20)
        }
    }

    /// The whole airport sheet for Austin (a disrupted day), sliced into phone-height PNGs in
    /// docs/screens/screens. Board rows are capped so the last slice stays readable.
    @Test func airportScreen() async throws {
        let store = AirportStore(code: "KAUS", airports: FakeAirportService(now: now))
        await store.load()
        let full = try render("airport-full", write: false) {
            AirportView(store: store, lookup: PreviewData.airport, now: now, scrolls: false, rowLimit: 22)
                .environment(\.airportStaticControls, true)
        }
        // Cut at fixed heights (pt) so each slice lines up with a reference screen.
        let cuts: [CGFloat] = [0, 1010, 1930, 2840, CGFloat(full.height) / 3]
        for i in 0..<(cuts.count - 1) where cuts[i] < cuts[i + 1] {
            let rect = CGRect(x: 0, y: cuts[i] * 3, width: CGFloat(full.width), height: (cuts[i + 1] - cuts[i]) * 3)
            let slice = try #require(full.cropping(to: rect))
            try save(slice, "airport-\(i + 1)", to: Self.screensDir)
        }
        // Light mode: the top of the sheet.
        let light = try render("airport-light", write: false, light: true) {
            AirportView(store: store, lookup: PreviewData.airport, now: now, scrolls: false, rowLimit: 22)
                .environment(\.airportStaticControls, true)
        }
        try save(try #require(light.cropping(to: CGRect(x: 0, y: 0, width: light.width, height: 1010 * 3))),
                 "airport-light-1", to: Self.screensDir)
    }

    /// Twenty round flags, the fallback among them, at 44 pt.
    @Test func countryFlags() throws {
        let codes: [String?] = ["US", "GB", "FR", "DE", "JP", "BR", "IN", "AU", "CA", "ES",
                                "IT", "MX", "ZA", "XK", "TW", "CH", "AE", "NZ", "ZZ", nil]
        try render("flags") {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 5), spacing: 16) {
                ForEach(Array(codes.enumerated()), id: \.offset) { _, code in
                    VStack(spacing: 6) {
                        CountryFlag(code: code, size: 44)
                        Text(code ?? "nil").themeFont(.chip).foregroundStyle(Theme.secondary)
                    }
                }
            }
            .padding(20)
        }
    }

    @Test func acknowledgements() throws {
        try render("Acknowledgements") { AcknowledgementsView(scrolls: false, onDone: {}, textLimit: 2) }
        try render("Acknowledgements-light", light: true) { AcknowledgementsView(scrolls: false, onDone: {}, textLimit: 2) }
    }

    @Test func badgesAndBanners() throws {
        try render("StaleBadge") {
            HStack(spacing: 10) {
                StaleBadge(fetchedAt: now.addingTimeInterval(-120), ttl: .seconds(600), now: now)
                StaleBadge(fetchedAt: now.addingTimeInterval(-3 * 3600), ttl: .seconds(600), now: now)
            }
            .padding(20)
        }
        try render("ErrorBanner") {
            VStack(spacing: 10) {
                let errors: [APIError] = [.providerUnavailable, .notFound, .rateLimited, .planLimit, .unauthorized, .offline]
                ForEach(errors.indices, id: \.self) { i in
                    ErrorBanner(error: errors[i], retry: [.providerUnavailable, .offline, .unauthorized].contains(errors[i]) ? {} : nil)
                }
            }
            .padding(16)
        }
    }
}
#endif
