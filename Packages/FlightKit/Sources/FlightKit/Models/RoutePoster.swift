import CoreGraphics
import CoreLocation
import CoreText
import Foundation

/// The flat world map the Passport draws, as plain Core Graphics paths: the same equirectangular view as
/// `PassportMap` (83 N to 57 S, standard parallel 40 degrees), the land from `world_land.json` and each
/// route as its great circle (`greatCircle`, split at the antimeridian by `mapSegments`). Pure: no SwiftUI,
/// so the Year in Review cards and the route poster's PDF share it.
enum RouteMap {
    static let north = 83.0, south = -57.0
    static let parallel = cos(40.0 * .pi / 180)
    /// Height over width.
    static var aspect: CGFloat { CGFloat((north - south) / (360 * parallel)) }

    /// A longitude and latitude inside `rect`, y growing downwards (flip the context for PDF space).
    static func point(lon: Double, lat: Double, in rect: CGRect) -> CGPoint {
        CGPoint(x: rect.minX + (lon + 180) / 360 * rect.width,
                y: rect.minY + (north - lat) / (north - south) * rect.height)
    }

    /// Every land ring as one path (even-odd fill keeps lakes open).
    static func land(in rect: CGRect, rings: [[CGPoint]] = WorldLand.shared.rings) -> CGPath {
        let path = CGMutablePath()
        for ring in rings {
            guard let first = ring.first else { continue }
            path.move(to: point(lon: first.x, lat: first.y, in: rect))
            for p in ring.dropFirst() { path.addLine(to: point(lon: p.x, lat: p.y, in: rect)) }
            path.closeSubpath()
        }
        return path
    }

    /// The great circle from `a` to `b`, as runs that never cross the antimeridian (each ends on +/-180
    /// where the route crosses it).
    static func runs(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D, segments: Int = 64) -> [[CLLocationCoordinate2D]] {
        mapSegments(greatCircle(from: a, to: b, segments: segments))
    }

    /// The runs as one stroked path.
    static func arc(_ runs: [[CLLocationCoordinate2D]], in rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        for run in runs {
            guard let first = run.first else { continue }
            path.move(to: point(lon: first.longitude, lat: first.latitude, in: rect))
            for c in run.dropFirst() { path.addLine(to: point(lon: c.longitude, lat: c.latitude, in: rect)) }
        }
        return path
    }
}

/// A print poster of the traveller's routes: every route flown (all time or one year) as a great-circle arc
/// on the world map, with a title, the years and the counts under it. Drawn as vectors into a PDF page
/// (Core Graphics and Core Text, no bitmap), at A3, A2 or 18 x 24 inches, in one of three styles. Made on
/// the device; nothing is sent anywhere.
public struct RoutePoster: Sendable {
    public enum Format: String, CaseIterable, Sendable, Identifiable {
        case a3, a2, us18x24
        public var id: String { rawValue }

        /// Landscape page size in PDF points (1/72 in): A3 420 x 297 mm, A2 594 x 420 mm, 24 x 18 in.
        public var size: CGSize {
            switch self {
            case .a3: CGSize(width: Self.points(mm: 420), height: Self.points(mm: 297))
            case .a2: CGSize(width: Self.points(mm: 594), height: Self.points(mm: 420))
            case .us18x24: CGSize(width: 24 * 72, height: 18 * 72)
            }
        }

        static func points(mm: Double) -> CGFloat { CGFloat(mm / 25.4 * 72) }

        public var title: String {
            switch self {
            case .a3: "A3"
            case .a2: "A2"
            case .us18x24: "18 \u{00D7} 24 in"
            }
        }
    }

    public enum Style: String, CaseIterable, Sendable, Identifiable {
        case paper, night, blueprint
        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .paper: "Paper"
            case .night: "Night"
            case .blueprint: "Blueprint"
            }
        }
    }

    /// One route, both ways together, and how many flights flew it.
    public struct Arc: Sendable {
        public var from: CLLocationCoordinate2D
        public var to: CLLocationCoordinate2D
        public var flights: Int
    }

    public var title: String
    /// "2025" or "2014 to 2026".
    public var period: String
    /// "214 flights · 1,234,567 km · 38 countries · 96 airports".
    public var counts: String
    public var arcs: [Arc]
    public var airports: [CLLocationCoordinate2D]
    public var flights: Int

    /// The poster of `year` (nil: all time), nil when no flight there has two known airports. Canceled
    /// flights are left out, as everywhere in the Passport.
    /// - Parameter name: the traveller's name for the title; nil or blank gives "My flights".
    public static func make(_ flights: [PastFlight], year: Int?, name: String?, unit: DistanceUnit,
                            airport: (String) -> Airport?) -> RoutePoster? {
        var pairs: [String: Arc] = [:]
        var order: [String] = []
        var airportIDs: [String: CLLocationCoordinate2D] = [:]
        var countries = Set<String>()
        var years = Set<Int>()
        var counted = 0, km = 0
        for f in flights where f.status != .canceled && (year == nil || f.localYear == year) {
            guard let a = airport(f.originIcao), let b = airport(f.destinationIcao) else { continue }
            counted += 1
            km += max(0, f.distanceKm)
            years.insert(f.localYear)
            for x in [a, b] {
                airportIDs[x.id] = CLLocationCoordinate2D(latitude: x.lat, longitude: x.lon)
                if !x.country.isEmpty { countries.insert(x.country.uppercased()) }
            }
            guard a.id != b.id else { continue }
            let key = [a.id, b.id].sorted().joined(separator: "-")
            if pairs[key] == nil {
                order.append(key)
                pairs[key] = Arc(from: CLLocationCoordinate2D(latitude: a.lat, longitude: a.lon),
                                 to: CLLocationCoordinate2D(latitude: b.lat, longitude: b.lon), flights: 0)
            }
            pairs[key]?.flights += 1
        }
        guard counted > 0 else { return nil }
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return RoutePoster(
            title: trimmed.isEmpty ? RoutePosterFacts.defaultTitle : trimmed,
            period: RoutePosterFacts.period(years),
            counts: RoutePosterFacts.counts(flights: counted, km: km, unit: unit, countries: countries.count,
                                            airports: airportIDs.count),
            // Least flown first, so the busiest routes are drawn on top.
            arcs: order.compactMap { pairs[$0] }.sorted { $0.flights < $1.flights },
            airports: airportIDs.keys.sorted().compactMap { airportIDs[$0] },
            flights: counted)
    }

    /// Whether the history makes a poster at all: the Passport shows the entry only then.
    public static func isAvailable(_ flights: [PastFlight], airport: (String) -> Airport?) -> Bool {
        flights.contains { $0.status != .canceled && airport($0.originIcao) != nil && airport($0.destinationIcao) != nil }
    }

    public func fileName(_ format: Format, style: Style) -> String {
        "Soma Flight Routes \(period) \(format.rawValue.uppercased()) \(style.title).pdf"
    }

    /// The poster as a one-page vector PDF at `format`'s size.
    public func pdf(_ format: Format, style: Style) -> Data {
        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: format.size)
        let info: [CFString: Any] = [kCGPDFContextTitle: "\(title) \(period)", kCGPDFContextCreator: "Soma Flight"]
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &box, info as CFDictionary) else { return Data() }
        ctx.beginPDFPage(nil)
        draw(in: ctx, size: format.size, style: style)
        ctx.endPDFPage()
        ctx.closePDF()
        return data as Data
    }

    /// A small bitmap of the page for the preview, `width` pixels wide.
    public func preview(_ format: Format, style: Style, width: Int = 1_200) -> CGImage? {
        let size = format.size
        let scale = CGFloat(width) / size.width
        let height = Int((size.height * scale).rounded())
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        draw(in: ctx, size: size, style: style)
        return ctx.makeImage()
    }

    /// Draws the page into `ctx`, whose origin is at the bottom left (PDF space).
    public func draw(in ctx: CGContext, size: CGSize, style: Style) {
        let ink = Ink(style)
        let w = size.width, h = size.height
        let margin = w * 0.05
        ctx.setFillColor(ink.page)
        ctx.fill(CGRect(origin: .zero, size: size))

        // The map, in top-down coordinates under a flip.
        let mapWidth = w - 2 * margin
        let mapHeight = mapWidth * RouteMap.aspect
        let map = CGRect(x: margin, y: margin * 0.9, width: mapWidth, height: mapHeight)
        ctx.saveGState()
        ctx.translateBy(x: 0, y: h)
        ctx.scaleBy(x: 1, y: -1)
        if style == .blueprint { drawGraticule(ctx, map: map, ink: ink, unit: w) }
        // The far north and Antarctica are cut, as on the Passport map.
        ctx.clip(to: map.insetBy(dx: -w * 0.01, dy: 0))
        let land = RouteMap.land(in: map)
        ctx.addPath(land)
        if let fill = ink.land {
            ctx.setFillColor(fill)
            ctx.fillPath(using: .evenOdd)
        }
        if let stroke = ink.coast {
            ctx.addPath(land)
            ctx.setStrokeColor(stroke)
            ctx.setLineWidth(w * 0.0006)
            ctx.setLineJoin(.round)
            ctx.strokePath()
        }
        let busiest = Double(arcs.map(\.flights).max() ?? 1)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        for arc in arcs {
            let weight = log2(Double(arc.flights) + 1) / log2(busiest + 1)
            ctx.addPath(RouteMap.arc(RouteMap.runs(arc.from, arc.to), in: map))
            ctx.setStrokeColor(ink.arc.copy(alpha: 0.55 + 0.4 * weight) ?? ink.arc)
            ctx.setLineWidth(w * (0.0009 + 0.0016 * weight))
            ctx.strokePath()
        }
        let r = w * 0.0024
        for c in airports {
            let p = RouteMap.point(lon: c.longitude, lat: c.latitude, in: map)
            let dot = CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)
            ctx.setFillColor(ink.dot)
            ctx.fillEllipse(in: dot)
            ctx.setStrokeColor(ink.page)
            ctx.setLineWidth(r * 0.5)
            ctx.strokeEllipse(in: dot)
        }
        ctx.restoreGState()

        // The words under the map, in PDF space (y up).
        let textTop = h - (map.maxY + margin * 0.6)
        let titleSize = w * 0.036
        let lineSize = w * 0.0125
        let textWidth = w - 2 * margin
        let block = Self.text([(title, titleSize, true, ink.text), (period, lineSize * 1.3, false, ink.text),
                               (counts, lineSize, false, ink.soft)])
        let blockHeight = min(textTop - margin * 0.5, ceil(titleSize * 1.3 + lineSize * 4))
        Self.draw(block, in: CGRect(x: margin, y: textTop - blockHeight, width: textWidth * 0.75, height: blockHeight), ctx)
        let mark = Self.text([(RoutePosterFacts.mark, lineSize * 0.9, true, ink.soft)])
        let markWidth = textWidth * 0.2
        Self.draw(mark, in: CGRect(x: w - margin - markWidth, y: margin * 0.5, width: markWidth, height: lineSize * 2),
                  ctx, alignment: .right)
    }

    /// Meridians and parallels every 15 degrees, for the blueprint.
    private func drawGraticule(_ ctx: CGContext, map: CGRect, ink: Ink, unit: CGFloat) {
        let grid = CGMutablePath()
        for lon in stride(from: -180.0, through: 180.0, by: 15) {
            grid.move(to: RouteMap.point(lon: lon, lat: RouteMap.north, in: map))
            grid.addLine(to: RouteMap.point(lon: lon, lat: RouteMap.south, in: map))
        }
        for lat in stride(from: -45.0, through: 75.0, by: 15) {
            grid.move(to: RouteMap.point(lon: -180, lat: lat, in: map))
            grid.addLine(to: RouteMap.point(lon: 180, lat: lat, in: map))
        }
        ctx.addPath(grid)
        ctx.setStrokeColor(ink.grid)
        ctx.setLineWidth(unit * 0.0004)
        ctx.strokePath()
        ctx.stroke(map, width: unit * 0.0008)
    }

    static func text(_ lines: [(String, CGFloat, Bool, CGColor)]) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for (i, l) in lines.enumerated() {
            let base = CTFontCreateUIFontForLanguage(.system, l.1, nil) ?? CTFontCreateWithName("Helvetica" as CFString, l.1, nil)
            let font = l.2 ? (CTFontCreateCopyWithSymbolicTraits(base, l.1, nil, .traitBold, .traitBold) ?? base) : base
            out.append(NSAttributedString(string: l.0 + (i == lines.count - 1 ? "" : "\n"), attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): l.3,
            ]))
        }
        return out
    }

    static func draw(_ text: NSAttributedString, in rect: CGRect, _ ctx: CGContext,
                     alignment: CTTextAlignment = .left) {
        let aligned = NSMutableAttributedString(attributedString: text)
        var align = alignment
        let style: CTParagraphStyle = withUnsafeBytes(of: &align) { raw in
            var setting = CTParagraphStyleSetting(spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size,
                                                  value: raw.baseAddress!)
            return CTParagraphStyleCreate(&setting, 1)
        }
        aligned.addAttribute(NSAttributedString.Key(kCTParagraphStyleAttributeName as String), value: style,
                             range: NSRange(location: 0, length: aligned.length))
        ctx.saveGState()
        ctx.textMatrix = .identity
        let setter = CTFramesetterCreateWithAttributedString(aligned)
        let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), CGPath(rect: rect, transform: nil), nil)
        CTFrameDraw(frame, ctx)
        ctx.restoreGState()
    }

    /// The colours of a style.
    struct Ink {
        var page: CGColor
        var land: CGColor?
        var coast: CGColor?
        var grid: CGColor
        var arc: CGColor
        var dot: CGColor
        var text: CGColor
        var soft: CGColor

        init(_ style: Style) {
            func c(_ hex: Int, _ a: CGFloat = 1) -> CGColor {
                CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                        blue: CGFloat(hex & 0xFF) / 255, alpha: a)
            }
            switch style {
            case .paper:
                page = c(0xF5F0E6); land = c(0xE3DACA); coast = nil; grid = c(0x000000, 0)
                arc = c(0x520BF5); dot = c(0xB4561F); text = c(0x1C1A17); soft = c(0x6B6459)
            case .night:
                // The Passport's violet page and the map's gold airports.
                page = c(0x10003F); land = c(0x2A0C86); coast = nil; grid = c(0x000000, 0)
                arc = c(0xFFFFFF); dot = c(0xD8A24F); text = c(0xFFFFFF); soft = c(0xB8B0E0)
            case .blueprint:
                // Theme.blueprint, blueprintGrid and blueprintInk.
                page = c(0x2F6BBA); land = nil; coast = c(0xF4F8FC, 0.85); grid = c(0x4883C5)
                arc = c(0xF4F8FC); dot = c(0xF4F8FC); text = c(0xF4F8FC); soft = c(0xD3E2F3)
            }
        }
    }
}

/// The poster's words, English source with French in Localizable.xcstrings.
enum RoutePosterFacts {
    static var defaultTitle: String { String(localized: "My flights", bundle: .main) }
    static let mark = "SOMA FLIGHT"

    /// "2025", "2014 to 2026".
    static func period(_ years: Set<Int>) -> String {
        guard let lo = years.min(), let hi = years.max() else { return "" }
        return lo == hi ? String(lo) : String(localized: "\(String(lo)) to \(String(hi))", bundle: .main)
    }

    static func counts(flights: Int, km: Int, unit: DistanceUnit, countries: Int, airports: Int) -> String {
        let f = flights == 1 ? String(localized: "1 flight", bundle: .main) : String(localized: "\(PassportFacts.count(flights)) flights", bundle: .main)
        let c = countries == 1 ? String(localized: "1 country", bundle: .main) : String(localized: "\(countries) countries", bundle: .main)
        let a = airports == 1 ? String(localized: "1 airport", bundle: .main) : String(localized: "\(airports) airports", bundle: .main)
        return [f, TravelFacts.distance(km, unit), c, a].joined(separator: "  \u{00B7}  ")
    }
}
