import CoreGraphics
import ImageIO
import SwiftUI

// MARK: - Environment

private struct BrandAssetsKey: EnvironmentKey {
    static var defaultValue: any BrandAssetService { FakeBrandAssetService() }
}

/// The colour an airline mark sits on, light and dark, for its contrast check. Containers that are not the
/// page (cards, the delay page's red) set theirs with `.environment(\.logoSurface, ...)`.
public struct LogoSurface: Sendable, Equatable {
    public var light: UInt32
    public var dark: UInt32

    public init(light: UInt32, dark: UInt32) { self.light = light; self.dark = dark }

    /// `Theme.background`.
    public static let page = LogoSurface(light: 0xF2F2F7, dark: 0x18181A)
    /// `Theme.card`.
    public static let card = LogoSurface(light: 0xFFFFFF, dark: 0x202023)
    /// One colour in both schemes.
    public static func fixed(_ rgb: UInt32) -> LogoSurface { LogoSurface(light: rgb, dark: rgb) }

    /// Relative luminance of the surface in a scheme.
    func luminance(dark isDark: Bool) -> Double {
        let v = isDark ? dark : light
        return BrandArt.relativeLuminance(r: Double(v >> 16 & 0xFF) / 255, g: Double(v >> 8 & 0xFF) / 255,
                                          b: Double(v & 0xFF) / 255)
    }
}

private struct LogoSurfaceKey: EnvironmentKey {
    static let defaultValue = LogoSurface.page
}

public extension EnvironmentValues {
    /// Where airline logos come from. The shells set the environment's `brand`; the default answers
    /// nothing, so previews and renders draw monograms unless they set one.
    var brandAssets: any BrandAssetService {
        get { self[BrandAssetsKey.self] }
        set { self[BrandAssetsKey.self] = newValue }
    }

    /// The surface airline marks sit on; the page unless a container says otherwise.
    var logoSurface: LogoSurface {
        get { self[LogoSurfaceKey.self] }
        set { self[LogoSurfaceKey.self] = newValue }
    }
}

// MARK: - Decoded logo

/// A logo decoded once at display size, with what its pixels say: how its ink spreads over luminance, how
/// much of the square it covers, and the tone of its border (its own background, when it has one). Kept
/// with the version it came from.
struct BrandArt: @unchecked Sendable {
    // CGImage is immutable; it only crosses actors here.
    var image: CGImage
    var version: String
    /// The largest side it was decoded at, in pixels.
    var pixelSize: Int
    /// Ink (alpha-weighted) per luminance bin, `bins` bins from black to white, summing to 1.
    var histogram: [Double]
    /// Share of the image's area that is inked (alpha-weighted), 0 to 1.
    var coverage: Double
    /// Mean luminance of the outermost pixels.
    var borderLuminance: Double

    static let bins = 32
    var aspect: CGFloat { CGFloat(image.width) / CGFloat(max(image.height, 1)) }

    /// Decodes a thumbnail no larger than `maxPixel` on its long side and reads its pixels; nil when the
    /// bytes are not a usable image.
    static func make(_ asset: BrandAsset, maxPixel: Int) -> BrandArt? {
        guard asset.decodes, let source = CGImageSourceCreateWithData(asset.data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: max(maxPixel, 16),
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let m = measure(image)
        return BrandArt(image: image, version: asset.version, pixelSize: max(image.width, image.height),
                        histogram: m.histogram, coverage: m.coverage, borderLuminance: m.border)
    }

    /// Draws the image into a 48 x 48 sRGB bitmap and reads it.
    static func measure(_ image: CGImage) -> (histogram: [Double], coverage: Double, border: Double) {
        let side = 48
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let ctx = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                      bytesPerRow: side * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        var histogram = [Double](repeating: 0, count: bins)
        guard drawn else { return (histogram, 0, 0) }
        var weight = 0.0, borderSum = 0.0, borderWeight = 0.0
        for y in 0..<side {
            for x in 0..<side {
                let i = (y * side + x) * 4
                let a = Double(pixels[i + 3]) / 255
                guard a > 0.02 else { continue }
                // Premultiplied: divide the alpha back out.
                let r = min(Double(pixels[i]) / 255 / a, 1), g = min(Double(pixels[i + 1]) / 255 / a, 1)
                let b = min(Double(pixels[i + 2]) / 255 / a, 1)
                let lum = relativeLuminance(r: r, g: g, b: b)
                histogram[min(Int(lum * Double(bins)), bins - 1)] += a
                weight += a
                if x == 0 || y == 0 || x == side - 1 || y == side - 1 { borderSum += a * lum; borderWeight += a }
            }
        }
        guard weight > 0 else { return (histogram, 0, 0) }
        return (histogram.map { $0 / weight }, weight / Double(side * side),
                borderWeight > 0 ? borderSum / borderWeight : 0)
    }

    /// WCAG relative luminance of an sRGB colour (components 0 to 1).
    static func relativeLuminance(r: Double, g: Double, b: Double) -> Double {
        func lin(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
    }

    static func contrast(_ a: Double, _ b: Double) -> Double { (max(a, b) + 0.05) / (min(a, b) + 0.05) }

    /// Share of the ink under `minimum` contrast against a surface of luminance `surface`.
    static func faintShare(_ histogram: [Double], surface: Double, minimum: Double) -> Double {
        histogram.indices.reduce(0) { sum, i in
            let lum = (Double(i) + 0.5) / Double(histogram.count)
            return contrast(lum, surface) < minimum ? sum + histogram[i] : sum
        }
    }
}

/// The logos decoded this run, by airline and kind, so a row drawn again (or rendered by ImageRenderer)
/// shows its logo at once. `.none` is a known absence; a failed request stores nothing, so the next view
/// asks again.
@MainActor
final class BrandArtMemo {
    static let shared = BrandArtMemo()
    enum Slot { case none, art(BrandArt) }
    private var slots: [String: Slot] = [:]

    static func key(_ icao: String, _ kind: BrandAssetKind) -> String { "\(icao.uppercased())/\(kind.rawValue)" }

    func slot(_ icao: String, _ kind: BrandAssetKind) -> Slot? { slots[Self.key(icao, kind)] }
    func set(_ icao: String, _ kind: BrandAssetKind, _ slot: Slot) { slots[Self.key(icao, kind)] = slot }

    func art(_ icao: String, _ kind: BrandAssetKind) -> BrandArt? {
        if case .art(let a) = slots[Self.key(icao, kind)] { return a }
        return nil
    }

    func removeAll() { slots = [:] }
}

// MARK: - AirlineLogo

/// The airline's logo in a rounded square of `size`: the dark variant in dark mode when there is one,
/// else the logo, else the monogram (IATA code, white and bold, on the brand colour).
///
/// The logo sits on a plate when more than a quarter of its ink is under 4.5:1 against the surface it is
/// drawn on (`logoSurface`): white or near black, whichever leaves less ink faint. A logo with its own
/// opaque background always sits on the plate of that background's tone, in both schemes.
public struct AirlineLogo: View {
    var airline: Airline?
    var code: String
    var size: CGFloat
    /// True next to text that already names the airline: VoiceOver skips the mark.
    var decorative: Bool
    @Environment(\.brandAssets) private var service
    @Environment(\.colorScheme) private var scheme
    @Environment(\.logoSurface) private var surface
    @Environment(\.displayScale) private var displayScale
    /// Bumped when the task stores a new logo, so the body reads the memo again.
    @State private var revision = 0

    /// Corner radius as a share of the side.
    nonisolated static let cornerRatio: CGFloat = 0.22
    /// The monogram's text size as a share of the side (12 pt on a 34 pt badge).
    nonisolated static let textRatio: CGFloat = 12 / 34
    /// Inset of the logo inside the square, as a share of the side: on a plate, and with no plate.
    nonisolated static let platePadding: CGFloat = 0.14
    nonisolated static let barePadding: CGFloat = 0.06
    /// Ink under this contrast against its surface counts as faint (WCAG's 4.5:1: most logos are wordmarks).
    nonisolated static let minContrast = 4.5
    /// More faint ink than this share puts the logo on a plate.
    nonisolated static let maxFaint = 0.25
    /// A logo inking more than this share of its square carries its own background.
    nonisolated static let selfBacked = 0.9
    /// The plates' luminance: white, and the near black (white 0.11) one.
    nonisolated static let lightPlate = 1.0
    nonisolated static let darkPlate = BrandArt.relativeLuminance(r: 0.11, g: 0.11, b: 0.11)

    public init(airline: Airline?, code: String, size: CGFloat, decorative: Bool = false) {
        self.airline = airline; self.code = code; self.size = size; self.decorative = decorative
    }

    /// The letters of the fallback: the IATA code, else the first two letters of `code`.
    public nonisolated static func monogram(airline: Airline?, code: String) -> String {
        airline?.iata ?? String(code.prefix(2))
    }

    /// Where the fallback's fill comes from: the brand colour, else the hash palette keyed on the ICAO
    /// code when the airline is known, on `code` when not.
    enum TintSource: Equatable, Sendable {
        case brand(r: Double, g: Double, b: Double)
        case palette(String)
    }

    nonisolated static func tintSource(airline: Airline?, code: String) -> TintSource {
        if let rgb = airline.flatMap({ TravelFacts.rgb($0.colorPrimary) }) { return .brand(r: rgb.r, g: rgb.g, b: rgb.b) }
        return .palette(airline?.id ?? code)
    }

    nonisolated static func tint(airline: Airline?, code: String) -> Color {
        switch tintSource(airline: airline, code: code) {
        case .brand(let r, let g, let b): Color(red: r, green: g, blue: b)
        case .palette(let key): TravelFacts.airlineTint(key)
        }
    }

    /// The kinds to try for a scheme, best first. Square slots never take the wide `.wordmark`.
    nonisolated static func kinds(dark: Bool) -> [BrandAssetKind] { dark ? [.logoDark, .logo] : [.logo] }

    enum Plate: Equatable, Sendable { case light, dark }

    /// The plate behind a logo on a surface of luminance `surface`; nil when it reads on its own.
    nonisolated static func plate(histogram: [Double], coverage: Double, border: Double, surface: Double) -> Plate? {
        if coverage > selfBacked { return border < 0.5 ? .dark : .light }
        let faint = BrandArt.faintShare(histogram, surface: surface, minimum: minContrast)
        guard faint > maxFaint else { return nil }
        let onLight = BrandArt.faintShare(histogram, surface: lightPlate, minimum: minContrast)
        let onDark = BrandArt.faintShare(histogram, surface: darkPlate, minimum: minContrast)
        return onLight <= onDark ? .light : .dark
    }

    nonisolated static func plate(_ art: BrandArt, surface: Double) -> Plate? {
        plate(histogram: art.histogram, coverage: art.coverage, border: art.borderLuminance, surface: surface)
    }

    /// Asks the service for the kinds the scheme wants and decodes the answers at `maxPixel` into the memo.
    /// Returns the art to draw (the first kind that has one). A failed request leaves the memo as it was.
    @discardableResult
    static func load(icao: String, dark: Bool, service: any BrandAssetService, maxPixel: Int = 192) async -> BrandArt? {
        await load(icao: icao, kinds: kinds(dark: dark), service: service, maxPixel: maxPixel)
    }

    /// `load` for an explicit list of kinds, best first.
    @discardableResult
    static func load(icao: String, kinds: [BrandAssetKind], service: any BrandAssetService,
                     maxPixel: Int = 192) async -> BrandArt? {
        var best: BrandArt?
        for kind in kinds {
            let memo = BrandArtMemo.shared
            switch await service.lookup(icao, kind, type: nil) {
            case .unavailable:
                if best == nil, let held = memo.art(icao, kind) { best = held }
            case .missing:
                memo.set(icao, kind, .none)
            case .found(let asset):
                let art: BrandArt?
                if let held = memo.art(icao, kind), held.version == asset.version, held.pixelSize >= maxPixel {
                    art = held
                } else {
                    art = await decode(asset, maxPixel: maxPixel)
                }
                memo.set(icao, kind, art.map { .art($0) } ?? .none)
                if best == nil, let art { best = art }
            }
        }
        return best
    }

    @concurrent private static func decode(_ asset: BrandAsset, maxPixel: Int) async -> BrandArt? {
        BrandArt.make(asset, maxPixel: maxPixel)
    }

    /// Fills the memo for these airlines in both schemes (renders that cannot wait for a task).
    public static func preload(_ icaos: [String], service: any BrandAssetService, maxPixel: Int = 192) async {
        for icao in Set(icaos.map { $0.uppercased() }) {
            await load(icao: icao, dark: true, service: service, maxPixel: maxPixel)
            await load(icao: icao, kinds: [.wordmark], service: service, maxPixel: maxPixel)
        }
    }

    /// The art the memo holds for this scheme, best kind first.
    static func held(icao: String, dark: Bool) -> BrandArt? {
        for kind in kinds(dark: dark) { if let a = BrandArtMemo.shared.art(icao, kind) { return a } }
        return nil
    }

    public var body: some View {
        let dark = scheme == .dark
        let icao = airline?.id
        let pixels = Int((size * displayScale).rounded(.up))
        // Read so a stored logo redraws the view.
        let _ = revision
        let art = icao.flatMap { Self.held(icao: $0, dark: dark) }
        Group {
            if let art {
                logo(art, dark: dark)
            } else {
                monogramTile
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(airline?.name ?? code)
        .accessibilityAddTraits(.isImage)
        .accessibilityHidden(decorative)
        .task(id: icao.map { "\($0)-\(dark)-\(pixels)" }) {
            guard let icao else { return }
            let before = Self.held(icao: icao, dark: dark)
            let after = await Self.load(icao: icao, dark: dark, service: service, maxPixel: pixels)
            if after?.version != before?.version || after?.pixelSize != before?.pixelSize { revision += 1 }
        }
    }

    private var radius: CGFloat { size * Self.cornerRatio }

    private var monogramTile: some View {
        Text(Self.monogram(airline: airline, code: code))
            .font(.system(size: size * Self.textRatio, weight: .bold))
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Self.tint(airline: airline, code: code)))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(.white.opacity(0.14), lineWidth: 1))
    }

    @ViewBuilder private func logo(_ art: BrandArt, dark: Bool) -> some View {
        let plate = Self.plate(art, surface: surface.luminance(dark: dark))
        let inset = size * (plate == nil ? Self.barePadding : Self.platePadding)
        let image = Image(decorative: art.image, scale: 1)
            .resizable()
            .interpolation(.high)
            .antialiased(true)
            .aspectRatio(art.aspect, contentMode: .fit)
            .padding(inset)
            .frame(width: size, height: size)
        switch plate {
        case .light:
            image.background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Color.white))
                .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Theme.separator, lineWidth: 0.5))
        case .dark:
            image.background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Color(white: 0.11)))
        case nil:
            image
        }
    }
}

// MARK: - AirlineWordmark

/// The airline's wordmark (its full logo, set wide) in a slot of `height`, as wide as the mark is: for wide
/// places such as the airline card. Falls back to the airline's name in text while there is no wordmark or
/// when the airline has none. Sits on the same plate as `AirlineLogo` when its ink does not read.
public struct AirlineWordmark: View {
    var airline: Airline?
    var code: String
    var height: CGFloat
    @Environment(\.brandAssets) private var service
    @Environment(\.colorScheme) private var scheme
    @Environment(\.logoSurface) private var surface
    @Environment(\.displayScale) private var displayScale
    @State private var revision = 0

    /// The widest a wordmark gets, in heights (a very wide mark is fitted, not stretched).
    nonisolated static let maxAspect: CGFloat = 5

    public init(airline: Airline?, code: String, height: CGFloat) {
        self.airline = airline; self.code = code; self.height = height
    }

    /// The text shown when there is no wordmark: the airline's name, else the code.
    public nonisolated static func fallbackText(airline: Airline?, code: String) -> String { airline?.name ?? code }

    public var body: some View {
        let dark = scheme == .dark
        let icao = airline?.id
        let pixels = Int((height * 4 * displayScale).rounded(.up))
        let _ = revision
        let art = icao.flatMap { BrandArtMemo.shared.art($0, .wordmark) }
        Group {
            if let art {
                wordmark(art, dark: dark)
            } else {
                Text(Self.fallbackText(airline: airline, code: code))
                    .font(.system(size: height * 0.5, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .foregroundStyle(Theme.primary)
                    .frame(height: height)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(airline?.name ?? code)
        .accessibilityAddTraits(.isImage)
        .task(id: icao.map { "\($0)-\(pixels)" }) {
            guard let icao else { return }
            let before = BrandArtMemo.shared.art(icao, .wordmark)
            let after = await AirlineLogo.load(icao: icao, kinds: [.wordmark], service: service, maxPixel: pixels)
            if after?.version != before?.version || after?.pixelSize != before?.pixelSize { revision += 1 }
        }
    }

    @ViewBuilder private func wordmark(_ art: BrandArt, dark: Bool) -> some View {
        let plate = AirlineLogo.plate(art, surface: surface.luminance(dark: dark))
        let pad = height * (plate == nil ? AirlineLogo.barePadding : AirlineLogo.platePadding)
        let radius = height * AirlineLogo.cornerRatio
        let image = Image(decorative: art.image, scale: 1)
            .resizable()
            .interpolation(.high)
            .antialiased(true)
            .aspectRatio(min(art.aspect, Self.maxAspect), contentMode: .fit)
            .padding(pad)
            .frame(height: height)
        switch plate {
        case .light:
            image.background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Color.white))
                .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Theme.separator, lineWidth: 0.5))
        case .dark:
            image.background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Color(white: 0.11)))
        case nil:
            image
        }
    }
}

// MARK: - AirlineMark

/// An airline's logo from a name or code (`key`) and a flight designator (`code`), resolved through the
/// reference list. `size` nil keeps 34 pt under Dynamic Type. `decorative` when the row already names it.
struct AirlineMark: View {
    var code: String
    var key: String
    var size: CGFloat?
    var decorative: Bool
    @ScaledMetric(relativeTo: .body) private var scaled: CGFloat = 34
    @Environment(\.reference) private var reference

    init(code: String, key: String, size: CGFloat? = nil, decorative: Bool = false) {
        self.code = code; self.key = key; self.size = size; self.decorative = decorative
    }

    /// From an airline name or code alone (Passport rankings, tails).
    init(airline: String, size: CGFloat, decorative: Bool = false) {
        self.code = airline; self.key = airline; self.size = size; self.decorative = decorative
    }

    var body: some View {
        let airline = TravelFacts.badgeAirline(code: code, key: key, reference: reference)
        AirlineLogo(airline: airline, code: airline?.iata ?? code, size: size ?? scaled, decorative: decorative)
    }
}
