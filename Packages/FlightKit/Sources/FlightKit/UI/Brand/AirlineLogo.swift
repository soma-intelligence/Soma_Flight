import CoreGraphics
import ImageIO
import SwiftUI

// MARK: - Environment

private struct BrandAssetsKey: EnvironmentKey {
    static var defaultValue: any BrandAssetService { FakeBrandAssetService() }
}

public extension EnvironmentValues {
    /// Where airline logos come from. The shells set the environment's `brand`; the default answers
    /// nothing, so previews and renders draw monograms unless they set one.
    var brandAssets: any BrandAssetService {
        get { self[BrandAssetsKey.self] }
        set { self[BrandAssetsKey.self] = newValue }
    }
}

// MARK: - Decoded logo

/// A logo decoded once, with what its pixels say: the mean luminance of its inked pixels and how much
/// of the square it covers. Kept with the version it came from.
struct BrandArt: @unchecked Sendable {
    // CGImage is immutable; it only crosses actors here.
    var image: CGImage
    var version: String
    /// Relative luminance (0 black, 1 white) averaged over the inked pixels, weighted by alpha.
    var luminance: Double
    /// Share of the image's area that is inked (alpha-weighted), 0 to 1.
    var coverage: Double

    var aspect: CGFloat { CGFloat(image.width) / CGFloat(max(image.height, 1)) }

    /// Decodes the asset and reads its pixels; nil when it does not decode.
    static func make(_ asset: BrandAsset) -> BrandArt? {
        guard asset.decodes, let source = CGImageSourceCreateWithData(asset.data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let (luminance, coverage) = measure(image)
        return BrandArt(image: image, version: asset.version, luminance: luminance, coverage: coverage)
    }

    /// Draws the image into a 48 x 48 sRGB bitmap and averages it.
    static func measure(_ image: CGImage) -> (luminance: Double, coverage: Double) {
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
        guard drawn else { return (0, 0) }
        var weight = 0.0, sum = 0.0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let a = Double(pixels[i + 3]) / 255
            guard a > 0.02 else { continue }
            // Premultiplied: divide the alpha back out.
            let r = Double(pixels[i]) / 255 / a, g = Double(pixels[i + 1]) / 255 / a, b = Double(pixels[i + 2]) / 255 / a
            sum += a * relativeLuminance(r: min(r, 1), g: min(g, 1), b: min(b, 1))
            weight += a
        }
        guard weight > 0 else { return (0, 0) }
        return (sum / weight, weight / Double(side * side))
    }

    /// WCAG relative luminance of an sRGB colour (components 0 to 1).
    static func relativeLuminance(r: Double, g: Double, b: Double) -> Double {
        func lin(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
    }
}

/// The logos decoded this run, by airline and kind, so a row drawn again (or rendered by ImageRenderer)
/// shows its logo at once. A miss is remembered as `.none` until the service says otherwise.
@MainActor
final class BrandArtMemo {
    static let shared = BrandArtMemo()
    enum Slot { case none, art(BrandArt) }
    private var slots: [String: Slot] = [:]

    static func key(_ icao: String, _ kind: BrandAssetKind) -> String { "\(icao.uppercased())/\(kind.rawValue)" }

    func slot(_ icao: String, _ kind: BrandAssetKind) -> Slot? { slots[Self.key(icao, kind)] }

    /// Stores what the service answered; a file with the version already held is not measured again.
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
/// A logo whose ink is too close to the background (contrast under 4.5:1, measured once per file) sits
/// on a plate: white for a dark logo, near black for a light one. A logo with its own opaque background
/// sits on the plate of its tone. Wide wordmarks are fitted inside the square
/// with padding.
public struct AirlineLogo: View {
    var airline: Airline?
    var code: String
    var size: CGFloat
    @Environment(\.brandAssets) private var service
    @Environment(\.colorScheme) private var scheme
    /// Bumped when the task stores a new logo, so the body reads the memo again.
    @State private var revision = 0

    /// Corner radius as a share of the side.
    nonisolated static let cornerRatio: CGFloat = 0.22
    /// The monogram's text size as a share of the side (12 pt on a 34 pt badge).
    nonisolated static let textRatio: CGFloat = 12 / 34
    /// Inset of the logo inside the square, as a share of the side: on a plate, and with no plate.
    nonisolated static let platePadding: CGFloat = 0.14
    nonisolated static let barePadding: CGFloat = 0.06
    /// Below this contrast against the page the logo gets a plate (WCAG's 4.5:1 for text: most logos
    /// are wordmarks).
    nonisolated static let minContrast = 4.5
    /// A logo inking more than this share of its square carries its own background: it always sits on
    /// the plate of that background's tone, so a white box reads as a white tile.
    nonisolated static let selfBacked = 0.9

    public init(airline: Airline?, code: String, size: CGFloat) {
        self.airline = airline; self.code = code; self.size = size
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

    /// The kinds to try for a scheme, best first.
    nonisolated static func kinds(dark: Bool) -> [BrandAssetKind] { dark ? [.logoDark, .logo] : [.logo] }

    /// The plate behind a logo of `luminance` and `coverage` on a light or dark page; nil when it reads
    /// on its own.
    enum Plate: Equatable, Sendable { case light, dark }
    nonisolated static func plate(luminance: Double, coverage: Double, dark: Bool) -> Plate? {
        if coverage > selfBacked { return luminance < 0.5 ? .dark : .light }
        let page = dark ? BrandArt.relativeLuminance(r: 0x18 / 255, g: 0x18 / 255, b: 0x1A / 255)
            : BrandArt.relativeLuminance(r: 0xF2 / 255, g: 0xF2 / 255, b: 0xF7 / 255)
        let contrast = (max(luminance, page) + 0.05) / (min(luminance, page) + 0.05)
        if contrast >= minContrast { return nil }
        return luminance < 0.5 ? .light : .dark
    }

    /// Asks the service for the kinds the scheme wants and decodes the answers into the memo. Returns the
    /// art to draw (the first kind that has one).
    @discardableResult
    static func load(icao: String, dark: Bool, service: any BrandAssetService) async -> BrandArt? {
        var best: BrandArt?
        for kind in kinds(dark: dark) {
            let memo = BrandArtMemo.shared
            guard let asset = await service.asset(icao, kind) else {
                memo.set(icao, kind, .none)
                continue
            }
            let art: BrandArt?
            if let held = memo.art(icao, kind), held.version == asset.version {
                art = held
            } else {
                art = await decode(asset)
            }
            memo.set(icao, kind, art.map { .art($0) } ?? .none)
            if best == nil, let art { best = art }
        }
        return best
    }

    @concurrent private static func decode(_ asset: BrandAsset) async -> BrandArt? { BrandArt.make(asset) }

    /// Fills the memo for these airlines in both schemes (renders that cannot wait for a task).
    public static func preload(_ icaos: [String], service: any BrandAssetService) async {
        for icao in Set(icaos.map { $0.uppercased() }) {
            await load(icao: icao, dark: true, service: service)
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
        .accessibilityHidden(true)
        .task(id: icao.map { "\($0)-\(dark)" }) {
            guard let icao else { return }
            let before = Self.held(icao: icao, dark: dark)?.version
            let after = await Self.load(icao: icao, dark: dark, service: service)
            if after?.version != before || (after == nil) != (before == nil) { revision += 1 }
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
        let plate = Self.plate(luminance: art.luminance, coverage: art.coverage, dark: dark)
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

// MARK: - AirlineMark

/// An airline's logo from a name or code (`key`) and a flight designator (`code`), resolved through the
/// reference list. `size` nil keeps 34 pt under Dynamic Type.
struct AirlineMark: View {
    var code: String
    var key: String
    var size: CGFloat?
    @ScaledMetric(relativeTo: .body) private var scaled: CGFloat = 34
    @Environment(\.reference) private var reference

    init(code: String, key: String, size: CGFloat? = nil) {
        self.code = code; self.key = key; self.size = size
    }

    /// From an airline name or code alone (Passport rankings, tails).
    init(airline: String, size: CGFloat) {
        self.code = airline; self.key = airline; self.size = size
    }

    var body: some View {
        let airline = TravelFacts.badgeAirline(code: code, key: key, reference: reference)
        AirlineLogo(airline: airline, code: airline?.iata ?? code, size: size ?? scaled)
    }
}
