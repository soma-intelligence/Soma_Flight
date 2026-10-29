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
        .accessibilityValue("\(routes.count) routes, \(airports.count) airports")
    }
}

/// The airport codes flown, a few small planes between each, sliding left in a loop (still with Reduce
/// Motion), coloured by a soft gradient across the row.
struct PassportTicker: View {
    var codes: [String]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var width: CGFloat = 0

    private var row: some View {
        HStack(spacing: 10) {
            ForEach(Array(codes.enumerated()), id: \.offset) { _, code in
                HStack(spacing: 4) {
                    Image(systemName: "airplane.circle.fill")
                    Text(code).scaledFont(13, weight: .semibold).monospaced()
                }
                ForEach(0..<4, id: \.self) { _ in Image(systemName: "airplane") }
            }
        }
        .scaledFont(12, weight: .semibold)
        .fixedSize()
        .padding(.trailing, 10)
    }

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let shift = width > 0 && !reduceMotion ? CGFloat((t * 24).truncatingRemainder(dividingBy: Double(width))) : 0
            LinearGradient(colors: PassportMap.tickerColors, startPoint: .leading, endPoint: .trailing)
                .mask(alignment: .leading) {
                    HStack(spacing: 0) {
                        row.onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
                        row
                        row
                    }
                    .offset(x: -shift)
                }
        }
        .frame(height: 20)
        .frame(maxWidth: .infinity)
        .clipped()
        .accessibilityElement()
        .accessibilityLabel("Airports flown")
        .accessibilityValue(codes.joined(separator: ", "))
    }
}

/// The visited countries' round flags, overlapping, centred; past 12 a "+N" closes the row.
struct FlagRow: View {
    var codes: [String]
    static let limit = 12

    var body: some View {
        HStack(spacing: -7) {
            ForEach(codes.prefix(Self.limit), id: \.self) { code in
                CountryFlag(code: code, size: 30, decorative: true)
                    .overlay(Circle().strokeBorder(Theme.passportPage, lineWidth: 1.5))
            }
            if codes.count > Self.limit {
                Text("+\(codes.count - Self.limit)")
                    .scaledFont(14, weight: .semibold)
                    .foregroundStyle(.white)
                    .frame(minWidth: 30, minHeight: 30)
                    .padding(.horizontal, 4)
                    .background(Capsule().fill(Theme.passportChip))
                    .padding(.leading, 10)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement()
        .accessibilityLabel("Countries visited")
        .accessibilityValue(codes.map { CountryFlag.accessibilityName($0) }.joined(separator: ", "))
    }
}
