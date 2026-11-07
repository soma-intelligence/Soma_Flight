import CoreGraphics
import ImageIO
import Synchronization
import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

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

    /// How fin art is drawn: as it is, or as a one-colour silhouette when its ink would vanish on the fin
    /// (contrast under 2:1), white on a dark fin and near black on a pale one, the way airlines paint a mark
    /// on a coloured tail.
    enum ArtInk: Equatable { case asIs, white, dark }

    static func artInk(finLuminance: Double, inkLuminance: Double) -> ArtInk {
        guard BrandArt.contrast(finLuminance, inkLuminance) < 2 else { return .asIs }
        return finLuminance > 0.5 ? .dark : .white
    }

    /// Mean luminance of the art's ink.
    static func inkLuminance(_ art: BrandArt) -> Double {
        art.histogram.indices.reduce(0.0) { $0 + art.histogram[$1] * (Double($1) + 0.5) / Double(art.histogram.count) }
    }

    /// The brand art fitted inside `finBox`, as `artInk` says.
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
        switch Self.artInk(finLuminance: finLum, inkLuminance: Self.inkLuminance(art)) {
        case .asIs:
            ctx.draw(image, in: rect)
        case let ink:
            ctx.drawLayer { inner in
                inner.draw(image, in: rect)
                inner.blendMode = .sourceAtop
                inner.fill(Path(rect), with: .color(ink == .dark ? Color(white: 0.12) : .white))
            }
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

    /// Where the title goes, in metres (y up, `minY` the bottom of its line box), and its type size.
    struct TitleLayout: Equatable {
        var frame: CGRect
        var size: Double
    }

    /// The nominal type size, as a share of the barrel's height.
    static let titleShare = 0.24
    /// Clear space kept around a door outline, in metres.
    static let doorMargin = 0.25

    /// The title's place: from `titleAnchor` aft, in the first space between door outlines that holds it at
    /// 70% of its nominal size or more (else the roomiest one), never past a third of the length from the
    /// anchor (ahead of the wing). Shrinks to fit its space; never crosses a door.
    static func titleLayout(_ title: LiveryTitle, geometry g: AircraftGeometry) -> TitleLayout? {
        guard !title.text.isEmpty else { return nil }
        let d = g.fuselageTopM - g.fuselageBottomM
        let nominal = d * titleShare
        let m = TitleMetrics.of(title)
        let bottom = g.titleAnchor.y + d * 0.03, top = bottom + nominal * m.lineHeight
        let start = g.titleAnchor.x
        let end = start + g.lengthM * (g.family.isWidebody ? 0.30 : 0.34)
        // Doors, and on the near side any engine part at title height (a turboprop's nacelle and propeller).
        let blocks = g.shapes.filter { $0.part == .door || $0.layer == .engine && [.nacelle, .propeller, .spinner].contains($0.part) }
            .map { $0.path.boundingRect }
            .filter { $0.maxY > bottom && $0.minY < top }
            .map { ($0.minX - doorMargin, $0.maxX + doorMargin) }
            .sorted { $0.0 < $1.0 }
        var gaps: [(Double, Double)] = []
        var cursor = start
        for (lo, hi) in blocks {
            if hi <= cursor { continue }
            if lo > cursor { gaps.append((cursor, min(lo, end))) }
            cursor = max(cursor, hi)
            if cursor >= end { break }
        }
        if cursor < end { gaps.append((cursor, end)) }
        let fits = gaps.filter { $0.1 > $0.0 }.map { gap in (gap, min(nominal, (gap.1 - gap.0) / m.width)) }
        guard let pick = fits.first(where: { $0.1 >= nominal * 0.7 }) ?? fits.max(by: { $0.1 < $1.1 }),
              pick.1 > 0 else { return nil }
        let size = pick.1
        return TitleLayout(frame: CGRect(x: pick.0.0, y: bottom, width: size * m.width, height: size * m.lineHeight),
                           size: size)
    }

    /// The title over the windows where `titleLayout` puts it.
    func paintTitle(_ ctx: inout GraphicsContext) {
        guard let title = livery.title, let layout = Self.titleLayout(title, geometry: geometry) else { return }
        let size = layout.size * scale
        guard size >= 2.5 else { return }
        let text = Text(ui: title.text)
            .font(.system(size: size, weight: Self.weight(title.weight)))
            .tracking(size * title.tracking)
            .foregroundColor(Self.color(title.color, .black))
        ctx.draw(ctx.resolve(text), at: CGPoint(x: layout.frame.minX * scale, y: y(layout.frame.minY)), anchor: .bottomLeading)
    }
}

/// A title's width and line height per unit of type size, in the system font, measured once.
struct TitleMetrics: Sendable {
    var width: Double
    var lineHeight: Double

    private static let memo = Mutex<[String: TitleMetrics]>([:])

    static func of(_ title: LiveryTitle) -> TitleMetrics {
        let key = "\(title.weight)|\(title.tracking)|\(title.text)"
        if let held = memo.withLock({ $0[key] }) { return held }
        let unit: CGFloat = 100
        #if canImport(UIKit)
        let w: UIFont.Weight = switch title.weight { case "heavy": .heavy; case "semibold": .semibold; default: .bold }
        let font = UIFont.systemFont(ofSize: unit, weight: w)
        #else
        let w: NSFont.Weight = switch title.weight { case "heavy": .heavy; case "semibold": .semibold; default: .bold }
        let font = NSFont.systemFont(ofSize: unit, weight: w)
        #endif
        let measured = NSAttributedString(string: title.text, attributes: [.font: font, .kern: unit * title.tracking]).size()
        let metrics = TitleMetrics(width: measured.width / unit, lineHeight: (font.ascender - font.descender) / unit)
        memo.withLock { $0[key] = metrics }
        return metrics
    }
}

// MARK: - Brand art for side views

extension BrandAsset {
    /// Pixel width and height, read from the header; nil when the bytes are not an image.
    var pixelSize: CGSize? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int,
              w > 0, h > 0 else { return nil }
        return CGSize(width: w, height: h)
    }

    /// Pixel width over height; nil when the bytes are not an image.
    var pixelAspect: CGFloat? { pixelSize.map { $0.width / $0.height } }
}

/// Decoded brand images for aircraft (fin art, provider side views) and rasterised side views for list
/// rows, by key, so a view drawn again or rendered by ImageRenderer shows them at once. `.none` is a known
/// absence.
@MainActor
final class AircraftArtMemo {
    static let shared = AircraftArtMemo()
    enum Slot { case none, art(BrandArt) }
    private var slots: [String: Slot] = [:]
    private var rendered: [String: CGImage] = [:]
    /// Rasterised rows kept before the memo starts over.
    static let renderedLimit = 160

    func slot(_ key: String) -> Slot? { slots[key] }
    func set(_ key: String, _ slot: Slot) { slots[key] = slot }
    func art(_ key: String) -> BrandArt? {
        if case .art(let a) = slots[key] { return a }
        return nil
    }

    func image(_ key: String) -> CGImage? { rendered[key] }
    func setImage(_ key: String, _ image: CGImage) {
        if rendered.count >= Self.renderedLimit { rendered = [:] }
        rendered[key] = image
    }

    func removeAll() { slots = [:]; rendered = [:] }

    static func finKey(_ icao: String) -> String { "fin/\(icao.uppercased())" }
    static func sideKey(_ icao: String, _ type: String) -> String { "side/\(icao.uppercased())/\(type.uppercased())" }
}

enum FinArt {
    /// Without a wordmark to compare against, a logo this close to square is taken for a symbol.
    static let symbolAspect: ClosedRange<CGFloat> = 0.6...1.6
    /// A logo whose version differs from the airline's wordmark is its symbol: the backend's `.logo` is
    /// the symbol when there is one, else the wordmark file itself, and both rows carry the source file's
    /// content version. The bytes are no guide (`.logo` is the 192 px rendition, `.wordmark` the 384 px
    /// one). A symbol still has to be roughly compact.
    static let knownSymbolAspect: ClosedRange<CGFloat> = 0.4...2.5
    /// Smaller art would blur on a fin.
    static let minPixelHeight: CGFloat = 64

    /// What goes on the fin: the tail asset when there is one, else the logo when it is the airline's
    /// symbol (its version differs from the `.wordmark`'s; when the wordmark is unknown, a near square),
    /// else nothing.
    /// Never a monogram, never a wordmark, nothing under `minPixelHeight`.
    static func choose(tail: BrandAsset?, logo: BrandAsset?, wordmark: BrandAsset? = nil) -> BrandAsset? {
        func tallEnough(_ a: BrandAsset) -> Bool { (a.pixelSize?.height ?? 0) >= minPixelHeight }
        if let tail, tail.decodes, tallEnough(tail) { return tail }
        guard let logo, logo.decodes, tallEnough(logo), let aspect = logo.pixelAspect else { return nil }
        if let wordmark {
            // Same source file: the airline has no symbol, and a wordmark never goes on the fin.
            guard wordmark.version != logo.version else { return nil }
            return knownSymbolAspect.contains(aspect) ? logo : nil
        }
        return symbolAspect.contains(aspect) ? logo : nil
    }

    /// Looks the airline's fin art up and decodes it into the memo. A lookup that failed on every kind
    /// leaves the memo as it was so the next view asks again.
    @MainActor @discardableResult
    static func load(icao: String, service: any BrandAssetService, maxPixel: Int = 256) async -> BrandArt? {
        let key = AircraftArtMemo.finKey(icao)
        let tail = await service.lookup(icao, .tail, type: nil)
        let logo = await service.lookup(icao, .logo, type: nil)
        let wordmark = await service.lookup(icao, .wordmark, type: nil)
        if tail == .unavailable && logo == .unavailable { return AircraftArtMemo.shared.art(key) }
        guard let chosen = choose(tail: tail.asset, logo: logo.asset, wordmark: wordmark.asset) else {
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

/// A provider's side view, checked: transparent margins cropped, and only a profile's proportions
/// (`aspect`) accepted, so a square or padded image never stands in for an aircraft.
enum ProviderSideView {
    static let aspect: ClosedRange<CGFloat> = 2.5...7

    /// The decoded, cropped image, or nil when it is not a usable profile.
    static func prepare(_ asset: BrandAsset, maxPixel: Int = 1200) -> BrandArt? {
        guard var art = BrandArt.make(asset, maxPixel: maxPixel) else { return nil }
        if let cropped = cropTransparent(art.image) { art.image = cropped }
        return aspect.contains(art.aspect) ? art : nil
    }

    @concurrent static func prepareOff(_ asset: BrandAsset) async -> BrandArt? { prepare(asset) }

    /// The image cut to the box of its pixels with alpha above 2%; nil when nothing needs cutting or the
    /// image is empty.
    static func cropTransparent(_ image: CGImage) -> CGImage? {
        let w = image.width, h = image.height
        guard w > 0, h > 0, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h {
            for x in 0..<w where pixels[(y * w + x) * 4 + 3] > 5 {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        if minX == 0, minY == 0, maxX == w - 1, maxY == h - 1 { return nil }
        // The bitmap's rows run top down, as CGImage.cropping expects.
        return image.cropping(to: CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1))
    }
}
