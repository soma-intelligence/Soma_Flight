import SwiftUI
import CoreLocation

/// The land outline the Passport map draws: Natural Earth 1:110m land (public domain), simplified by
/// `Scripts/world/build_land.py` into `Resources/Reference/world_land.json`. Points are (longitude, latitude).
struct WorldLand: Sendable {
    var rings: [[CGPoint]]

    static var url: URL? {
        Bundle.module.url(forResource: "world_land", withExtension: "json", subdirectory: "Reference")
            ?? Bundle.module.url(forResource: "world_land", withExtension: "json")
    }

    /// Read once; an unreadable file draws no land rather than failing the page.
    static let shared = load()

    static func load() -> WorldLand {
        struct File: Decodable { var rings: [[Double]] }
        guard let url, let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data) else { return WorldLand(rings: []) }
        let rings = file.rings.map { flat in
            stride(from: 0, to: flat.count - 1, by: 2).map { CGPoint(x: flat[$0], y: flat[$0 + 1]) }
        }
        return WorldLand(rings: rings)
    }
}

/// The Passport header: a flat equirectangular world map (standard parallel 40 degrees, Antarctica and the
/// far north cut) with the great-circle arcs of the routes flown and a dot per airport, a ticker of the
/// flown airport codes above it and the visited countries' flags under it.
struct PassportMap: View {
    var routes: [(Airport, Airport)]
    var airports: [Airport]
    var countries: [String]

    static let land = Color(red: 0x52 / 255, green: 0x0B / 255, blue: 0xF5 / 255)
    static let dot = Color(red: 0xD8 / 255, green: 0xA2 / 255, blue: 0x4F / 255)
    static let tickerColors = [Color(red: 0.96, green: 0.68, blue: 0.80), Color(red: 0.76, green: 0.40, blue: 0.87),
                               Color(red: 0.55, green: 0.88, blue: 0.95), Color(red: 0.80, green: 0.62, blue: 0.98)]

    /// The latitudes shown, top and bottom, and the standard parallel's cosine that sets the aspect.
    static let north = 83.0, south = -57.0
    static let parallel = cos(40.0 * .pi / 180)
    static var aspect: CGFloat { CGFloat((north - south) / (360 * parallel)) }

    var body: some View {
        VStack(spacing: 0) {
            if !airports.isEmpty {
                PassportTicker(codes: airports.compactMap(\.iata))
                    .scaledPadding(.top, 14)
            }
            map
                .scaledPadding(.top, 18)
            if !countries.isEmpty {
                FlagRow(codes: countries)
                    .scaledPadding(.top, 14)
            }
        }
    }

    /// "12 routes, 18 airports. Top routes: SFO to CDG, JFK to BOS, ..." (five routes at most).
    nonisolated static func accessibilityValue(routes: [(Airport, Airport)], airports: Int) -> String {
        let top = routes.prefix(5).map { "\($0.0.iata ?? $0.0.id) to \($0.1.iata ?? $0.1.id)" }
        let head = "\(routes.count) routes, \(airports) airports"
        return top.isEmpty ? head : head + ". Top routes: " + top.joined(separator: ", ")
    }

    static func point(lon: Double, lat: Double, in size: CGSize) -> CGPoint {
        CGPoint(x: (lon + 180) / 360 * size.width,
                y: (north - lat) / (north - south) * size.height)
    }

    private var map: some View {
        Canvas { ctx, size in
            var land = Path()
            for ring in WorldLand.shared.rings {
                guard let first = ring.first else { continue }
                land.move(to: Self.point(lon: first.x, lat: first.y, in: size))
                for p in ring.dropFirst() { land.addLine(to: Self.point(lon: p.x, lat: p.y, in: size)) }
                land.closeSubpath()
            }
            ctx.fill(land, with: .color(Self.land), style: FillStyle(eoFill: true))

            // Most flown first: the first arcs are the brightest.
            for (i, route) in routes.enumerated() {
                let from = CLLocationCoordinate2D(latitude: route.0.lat, longitude: route.0.lon)
                let to = CLLocationCoordinate2D(latitude: route.1.lat, longitude: route.1.lon)
                var arc = Path()
                for run in mapSegments(greatCircle(from: from, to: to, segments: 64)) {
                    guard let first = run.first else { continue }
                    arc.move(to: Self.point(lon: first.longitude, lat: first.latitude, in: size))
                    for c in run.dropFirst() { arc.addLine(to: Self.point(lon: c.longitude, lat: c.latitude, in: size)) }
                }
                let opacity = max(0.45, 0.95 - Double(i) * 0.03)
                ctx.stroke(arc, with: .color(.white.opacity(opacity)), style: StrokeStyle(lineWidth: 1.3, lineCap: .round))
            }

            for a in airports {
                let c = Self.point(lon: a.lon, lat: a.lat, in: size)
                let r: CGFloat = 3.6
                let dot = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
                ctx.fill(dot, with: .color(Self.dot))
                ctx.stroke(dot, with: .color(.white.opacity(0.55)), lineWidth: 0.8)
            }
        }
        .aspectRatio(1 / Self.aspect, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .accessibilityElement()
        .accessibilityLabel("Map of your routes")
        .accessibilityValue(Self.accessibilityValue(routes: routes, airports: airports.count))
    }
}

/// The airport codes flown (the most visited first, `limit` at most), a few small planes between each,
/// sliding left in a loop. The row is rendered to one bitmap when the codes or the text size change; each
/// frame only moves the copies of that bitmap. Still with Reduce Motion, and paused while scrolled off screen.
struct PassportTicker: View {
    var codes: [String]
    static let limit = 20

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var displayScale
    @ScaledMetric(relativeTo: .footnote) private var codeSize: CGFloat = 13
    @State private var strip: Image?
    @State private var stripWidth: CGFloat = 0
    @State private var visible = true

    private var shown: [String] { Array(codes.prefix(Self.limit)) }
    /// Copies of the strip side by side: the widest window (a Mac sheet, an iPad) plus one.
    private var copies: Int { stripWidth > 1 ? Int((1_400 / stripWidth).rounded(.up)) + 1 : 0 }

    /// One pass of the row, coloured by a gradient that cycles along it.
    static func row(_ shown: [String], size: CGFloat) -> some View {
        let content = HStack(spacing: 10) {
            ForEach(Array(shown.enumerated()), id: \.offset) { _, code in
                HStack(spacing: 4) {
                    Image(systemName: "airplane.circle.fill")
                    Text(ui: code).font(.system(size: size, weight: .semibold, design: .monospaced))
                }
                ForEach(0..<4, id: \.self) { _ in Image(systemName: "airplane") }
            }
        }
        .font(.system(size: size * 0.92, weight: .semibold))
        .fixedSize()
        .padding(.trailing, 10)
        return content
            .hidden()
            .frame(height: size * 1.5)
            // The colours cycle about every screen width along the long row.
            .overlay(LinearGradient(colors: Array(repeating: PassportMap.tickerColors, count: max(1, shown.count / 4)).flatMap { $0 },
                                    startPoint: .leading, endPoint: .trailing))
            .mask(content)
    }

    /// The widest bitmap the GPU draws (8,192 px textures), with a margin.
    static let maxPixels: CGFloat = 8_000

    /// The row as one bitmap and its width in points; nil when nothing could be drawn. A long row is drawn at
    /// a lower scale so the bitmap stays under `maxPixels` wide (a wider one is not drawn at all on iOS).
    @MainActor static func strip(_ shown: [String], size: CGFloat, scale: CGFloat) -> (image: CGImage, width: CGFloat)? {
        guard !shown.isEmpty else { return nil }
        let renderer = ImageRenderer(content: row(shown, size: size))
        renderer.scale = 1
        guard let points = renderer.cgImage.map({ CGFloat($0.width) }), points > 0 else { return nil }
        // Text does not scale exactly linearly, so measure and step down until the bitmap fits.
        var s = min(scale, maxPixels / points)
        for _ in 0..<4 {
            renderer.scale = s
            guard let cg = renderer.cgImage else { return nil }
            if CGFloat(cg.width) <= maxPixels { return (cg, CGFloat(cg.width) / s) }
            s *= maxPixels / CGFloat(cg.width) * 0.99
        }
        return nil
    }

    @MainActor private func render() {
        let scale = max(displayScale, 2)
        guard let made = Self.strip(shown, size: codeSize, scale: scale) else { strip = nil; return }
        strip = Image(decorative: made.image, scale: CGFloat(made.image.width) / made.width)
        stripWidth = made.width
    }

    var body: some View {
        TimelineView(.animation(paused: reduceMotion || !visible || strip == nil)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let shift = reduceMotion || stripWidth <= 1 ? 0 : CGFloat((t * 24).truncatingRemainder(dividingBy: Double(stripWidth)))
            // The same bitmap a few times over, enough to cover the width while it slides by one, in an
            // overlay so the long row never sizes the page.
            Color.clear.overlay(alignment: .leading) {
                HStack(spacing: 0) {
                    if let strip {
                        ForEach(0..<copies, id: \.self) { _ in strip }
                    }
                }
                .fixedSize()
                .offset(x: -shift)
            }
        }
        .frame(height: codeSize * 1.5)
        .frame(maxWidth: .infinity)
        .clipped()
        .onScrollVisibilityChange(threshold: 0.01) { visible = $0 }
        .task(id: TickerKey(codes: shown, size: codeSize, scale: displayScale)) { render() }
        .accessibilityElement()
        .accessibilityLabel("Airports flown")
        .accessibilityValue(shown.joined(separator: ", "))
    }

    private struct TickerKey: Hashable { var codes: [String]; var size: CGFloat; var scale: CGFloat }
}

/// The visited countries' round flags, overlapping, centred; past `limit` a "+N" closes the row. The row
/// falls back to fewer flags when it does not fit the width (narrow screens, large text).
struct FlagRow: View {
    var codes: [String]
    static let limits = [12, 8, 5, 3]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            ForEach(Self.limits, id: \.self) { flags($0) }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement()
        .accessibilityLabel("Countries visited")
        .accessibilityValue(codes.map { CountryFlag.accessibilityName($0) }.joined(separator: ", "))
    }

    private func flags(_ limit: Int) -> some View {
        HStack(spacing: -7) {
            ForEach(codes.prefix(limit), id: \.self) { code in
                CountryFlag(code: code, size: 30, decorative: true)
                    .overlay(Circle().strokeBorder(Theme.passportPage, lineWidth: 1.5))
            }
            if codes.count > limit {
                Text("+\(codes.count - limit)")
                    .scaledFont(14, weight: .semibold)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .fixedSize()
                    .frame(minWidth: 30, minHeight: 30)
                    .padding(.horizontal, 4)
                    .background(Capsule().fill(Theme.passportChip))
                    .padding(.leading, 10)
            }
        }
        .fixedSize()
    }
}
