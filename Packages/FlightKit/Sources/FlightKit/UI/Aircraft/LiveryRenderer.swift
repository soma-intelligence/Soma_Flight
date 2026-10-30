import CoreGraphics
import ImageIO
import SwiftUI

/// Paints a livery's own layers on a side view: the stripes (clipped to the hull), the fin, the title over
/// the windows and the brand art on the fin. `AircraftCanvas` calls it part by part, in its draw order.
struct LiveryRenderer {
    var livery: Livery
    var geometry: AircraftGeometry
    /// Points per metre.
    var scale: CGFloat
    var toView: CGAffineTransform

    func y(_ metres: Double) -> CGFloat { (geometry.heightM - metres) * scale }

    static func color(_ hex: HexColor?, _ fallback: Color) -> Color {
        hex.flatMap { Color(hexString: $0) } ?? fallback
    }

    // MARK: Stripes

    /// A stripe as a closed path in metres: a band between two fractions of the barrel's height, its aft
    /// part tilted up by `sweep` degrees from 55% of the length on. Clip it to the hull.
    static func stripePath(_ stripe: Stripe, geometry g: AircraftGeometry) -> Path {
        let yb = g.fuselageBottomM, d = g.fuselageTopM - g.fuselageBottomM
        let lo = yb + d * min(stripe.from, stripe.to), hi = yb + d * max(stripe.from, stripe.to)
        let x0 = g.lengthM * 0.55
        let rise = tan(stripe.sweep * .pi / 180) * (g.lengthM - x0)
        var path = Path()
        path.move(to: CGPoint(x: -1, y: lo))
        path.addLine(to: CGPoint(x: x0, y: lo))
        path.addLine(to: CGPoint(x: g.lengthM + 1, y: lo + rise))
        path.addLine(to: CGPoint(x: g.lengthM + 1, y: hi + rise))
        path.addLine(to: CGPoint(x: x0, y: hi))
        path.addLine(to: CGPoint(x: -1, y: hi))
        path.closeSubpath()
        return path
    }

    func paintStripes(_ ctx: inout GraphicsContext, hull: Path) {
        guard !livery.cheatline.isEmpty else { return }
        ctx.drawLayer { inner in
            inner.clip(to: hull)
            for stripe in livery.cheatline {
                let path = Self.stripePath(stripe, geometry: geometry).applying(toView)
                let base = Self.color(stripe.color, .gray)
                let box = path.boundingRect
                inner.fill(path, with: .linearGradient(
                    Gradient(colors: [base.mix(with: .white, by: 0.12), base, base.mix(with: .black, by: 0.10)]),
                    startPoint: CGPoint(x: 0, y: box.minY), endPoint: CGPoint(x: 0, y: box.maxY)))
            }
        }
    }

    // MARK: Fin

    /// Fills the fin with the tail paint, then a soft light from the leading edge and a cooler trailing edge.
    func paintFin(_ ctx: inout GraphicsContext, fin: Path) {
        let box = fin.boundingRect
        let le = CGPoint(x: box.minX, y: box.minY), te = CGPoint(x: box.maxX, y: box.maxY)
        // Across the fin proper (not the dorsal fillet): from the upper leading edge of the logo box to its
        // lower trailing edge, so band edges run up and aft like the leading edge.
        let logo = geometry.finBox.applying(toView).standardized
        let across = (start: CGPoint(x: logo.minX - logo.width * 0.25, y: logo.minY - logo.height * 0.2),
                      end: CGPoint(x: logo.maxX + logo.width * 0.1, y: logo.maxY + logo.height * 0.35))
        switch livery.tail {
        case .solid(let hex):
            ctx.fill(fin, with: .color(Self.color(hex, .white)))
        case .gradient(let hexes):
            let colors = hexes.map { Self.color($0, .white) }
            ctx.fill(fin, with: .linearGradient(Gradient(colors: colors.isEmpty ? [.white] : colors),
                                                startPoint: CGPoint(x: box.maxX, y: box.minY),
                                                endPoint: CGPoint(x: box.minX + box.width * 0.4, y: box.maxY)))
        case .split(let top, let bottom, let at):
            ctx.fill(fin, with: .color(Self.color(bottom, .white)))
            let cut = box.maxY - box.height * CGFloat(min(max(at, 0), 1))
            ctx.drawLayer { inner in
                inner.clip(to: fin)
                inner.fill(Path(CGRect(x: box.minX, y: box.minY, width: box.width, height: cut - box.minY)),
                           with: .color(Self.color(top, .white)))
            }
        case .bands(let hexes):
            var stops: [Gradient.Stop] = []
            let n = max(hexes.count, 1)
            for (i, hex) in hexes.enumerated() {
                let c = Self.color(hex, .white)
                stops.append(.init(color: c, location: CGFloat(i) / CGFloat(n)))
                stops.append(.init(color: c, location: CGFloat(i + 1) / CGFloat(n)))
            }
            ctx.fill(fin, with: .linearGradient(Gradient(stops: stops.isEmpty ? [.init(color: .white, location: 0)] : stops),
                                                startPoint: across.start, endPoint: across.end))
        }
        ctx.fill(fin, with: .linearGradient(
            Gradient(stops: [.init(color: .white.opacity(0.22), location: 0), .init(color: .white.opacity(0), location: 0.35),
                             .init(color: .black.opacity(0), location: 0.7), .init(color: .black.opacity(0.10), location: 1)]),
            startPoint: le, endPoint: te))
    }

    /// The fin's base colour, for the brand art's contrast check.
    var finColor: HexColor {
        switch livery.tail {
        case .solid(let v): v
        case .gradient(let v): v.last ?? livery.fuselageTop
        case .split(_, let bottom, _): bottom
        case .bands(let v): v.first ?? livery.fuselageTop
        }
    }

    /// True when the tail paint takes brand art. A flag tail (`bands`) is the art itself.
    var finTakesArt: Bool {
        if case .bands = livery.tail { return false }
        return true
    }

    /// The brand art fitted inside `finBox`. Art that would vanish on the fin (contrast under 2:1) is drawn
    /// as a white silhouette, the way most airlines paint a mark on a coloured tail.
    func paintFinArt(_ ctx: inout GraphicsContext, art: BrandArt) {
        guard finTakesArt else { return }
        let box = geometry.finBox.applying(toView).standardized
        guard box.width > 2, box.height > 2 else { return }
        let aspect = art.aspect
        var w = box.width, h = box.width / aspect
        if h > box.height { h = box.height; w = h * aspect }
        let rect = CGRect(x: box.midX - w / 2, y: box.midY - h / 2, width: w, height: h)
        let image = Image(decorative: art.image, scale: 1)
        let finLum = TravelFacts.rgb(finColor).map { BrandArt.relativeLuminance(r: $0.r, g: $0.g, b: $0.b) } ?? 1
        let inkLum = art.histogram.indices.reduce(0.0) { $0 + art.histogram[$1] * (Double($1) + 0.5) / Double(art.histogram.count) }
        if BrandArt.contrast(finLum, inkLum) < 2 {
            ctx.drawLayer { inner in
                inner.draw(image, in: rect)
                inner.blendMode = .sourceAtop
                inner.fill(Path(rect), with: .color(finLum > 0.5 ? Color(white: 0.12) : .white))
            }
        } else {
            ctx.draw(image, in: rect)
        }
    }

    // MARK: Title

    static func weight(_ name: String) -> Font.Weight {
        switch name.lowercased() {
        case "heavy": .heavy
        case "semibold": .semibold
        default: .bold
        }
    }

    /// The title over the windows, from `titleAnchor`, type size about a quarter of the barrel; a long name
    /// shrinks to stay ahead of the wing.
    func paintTitle(_ ctx: inout GraphicsContext) {
        guard let title = livery.title, !title.text.isEmpty else { return }
        let g = geometry
        let d = g.fuselageTopM - g.fuselageBottomM
        var size = d * 0.24 * scale
        guard size >= 2.5 else { return }
        let maxWidth = g.lengthM * (g.family.isWidebody ? 0.30 : 0.34) * scale
        func text(_ size: CGFloat) -> GraphicsContext.ResolvedText {
            ctx.resolve(Text(title.text)
                .font(.system(size: size, weight: Self.weight(title.weight)))
                .tracking(size * title.tracking)
                .foregroundColor(Self.color(title.color, .black)))
        }
        var resolved = text(size)
        let measured = resolved.measure(in: CGSize(width: CGFloat.infinity, height: CGFloat.infinity)).width
        if measured > maxWidth {
            size *= maxWidth / measured
            resolved = text(size)
        }
        let anchor = CGPoint(x: g.titleAnchor.x * scale, y: y(g.titleAnchor.y + d * 0.03))
        ctx.draw(resolved, at: anchor, anchor: .bottomLeading)
    }
}

// MARK: - Brand art for side views

extension BrandAsset {
    /// Pixel width over height, read from the header; nil when the bytes are not an image.
    var pixelAspect: CGFloat? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int,
              w > 0, h > 0 else { return nil }
        return CGFloat(w) / CGFloat(h)
    }
}

/// Decoded brand images for aircraft (fin art, provider side views), by key, so a view drawn again or
/// rendered by ImageRenderer shows them at once. `.none` is a known absence.
@MainActor
final class AircraftArtMemo {
    static let shared = AircraftArtMemo()
    enum Slot { case none, art(BrandArt) }
    private var slots: [String: Slot] = [:]

    func slot(_ key: String) -> Slot? { slots[key] }
    func set(_ key: String, _ slot: Slot) { slots[key] = slot }
    func art(_ key: String) -> BrandArt? {
        if case .art(let a) = slots[key] { return a }
        return nil
    }
    func removeAll() { slots = [:] }

    static func finKey(_ icao: String) -> String { "fin/\(icao.uppercased())" }
    static func sideKey(_ icao: String, _ type: String) -> String { "side/\(icao.uppercased())/\(type.uppercased())" }
}

enum FinArt {
    /// A logo this close to square is a symbol; wider or taller ones are wordmarks and never go on a fin.
    static let symbolAspect: ClosedRange<CGFloat> = 0.6...1.6

    /// What goes on the fin: the tail asset when there is one, else the logo when it is a symbol (near
    /// square), else nothing. Never a monogram, never a wordmark.
    static func choose(tail: BrandAsset?, logo: BrandAsset?) -> BrandAsset? {
        if let tail, tail.decodes { return tail }
        if let logo, logo.decodes, let aspect = logo.pixelAspect, symbolAspect.contains(aspect) { return logo }
        return nil
    }

    /// Looks the airline's fin art up and decodes it into the memo. A lookup that failed on both kinds
    /// leaves the memo as it was so the next view asks again.
    @MainActor @discardableResult
    static func load(icao: String, service: any BrandAssetService, maxPixel: Int = 256) async -> BrandArt? {
        let key = AircraftArtMemo.finKey(icao)
        let tail = await service.lookup(icao, .tail, type: nil)
        let logo = await service.lookup(icao, .logo, type: nil)
        if tail == .unavailable && logo == .unavailable { return AircraftArtMemo.shared.art(key) }
        guard let chosen = choose(tail: tail.asset, logo: logo.asset) else {
            AircraftArtMemo.shared.set(key, .none)
            return nil
        }
        if let held = AircraftArtMemo.shared.art(key), held.version == chosen.version, held.pixelSize >= maxPixel {
            return held
        }
        let art = await decode(chosen, maxPixel: maxPixel)
        AircraftArtMemo.shared.set(key, art.map { .art($0) } ?? .none)
        return art
    }

    @concurrent static func decode(_ asset: BrandAsset, maxPixel: Int) async -> BrandArt? {
        BrandArt.make(asset, maxPixel: maxPixel)
    }
}
