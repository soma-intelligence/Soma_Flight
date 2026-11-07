import CoreGraphics
import Testing
@testable import FlightKit

/// What the square airline mark shows: tiles cut to rounded corners, bare marks, the fin before a
/// wordmark, the parent airline's mark, and the neutral glyph last (never letters).
struct AirlineMarkFaceTests {
    /// A 96 px RGBA image painted by `paint`.
    private func image(_ paint: (CGContext, CGRect) -> Void) -> CGImage {
        let side = 96
        let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 0, green: 0.2, blue: 0.63, alpha: 1))
        paint(ctx, CGRect(x: 0, y: 0, width: side, height: side))
        return ctx.makeImage()!
    }

    private func isTile(_ image: CGImage) -> Bool {
        AirlineLogo.isTile(cornerAlpha: BrandArt.measure(image).corners)
    }

    @Test func filledSquareIsATile() {
        #expect(isTile(image { ctx, r in ctx.fill(r) }))
    }

    @Test func roundedSquareIsATile() {
        // United's tile already has rounded corners (22%): still opaque 8% in from the corners.
        #expect(isTile(image { ctx, r in
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: r.width * 0.22, cornerHeight: r.width * 0.22, transform: nil))
            ctx.fillPath()
        }))
    }

    @Test func roundelAndBareMarksAreNotTiles() {
        // Air Canada's roundel, Flair's circle.
        #expect(!isTile(image { ctx, r in ctx.fillEllipse(in: r) }))
        // A mark with transparent margins.
        #expect(!isTile(image { ctx, r in ctx.fill(r.insetBy(dx: 20, dy: 20)) }))
        #expect(!isTile(image { _, _ in }))
        #expect(!AirlineLogo.isTile(cornerAlpha: []))
    }

    @Test func wordmarks() {
        #expect(AirlineLogo.isWordmark(version: "commons-2026-10-29-wordmark", aspect: 1))
        #expect(AirlineLogo.isWordmark(version: "v1", aspect: 192.0 / 30))
        #expect(!AirlineLogo.isWordmark(version: "commons-2026-10-29-symbol", aspect: 1))
        // Air France's stripe is wide but a symbol.
        #expect(!AirlineLogo.isWordmark(version: "commons-2026-10-29-symbol", aspect: 192.0 / 131))
    }

    @Test func faceOrder() {
        let symbol = (version: "v-symbol", aspect: CGFloat(1))
        let wordmark = (version: "v-wordmark", aspect: CGFloat(2.3))
        #expect(AirlineLogo.face(logo: symbol, hasFin: true) == .logo)
        #expect(AirlineLogo.face(logo: wordmark, hasFin: true) == .fin)
        #expect(AirlineLogo.face(logo: wordmark, hasFin: false) == .logo)
        #expect(AirlineLogo.face(logo: nil, hasFin: true) == .fin)
        #expect(AirlineLogo.face(logo: nil, hasFin: false) == .neutral)
    }

    /// An operator without a mark of its own takes its parent's (Lufthansa City Airlines shows the crane).
    @MainActor @Test func parentMarkBeforeNeutral() {
        let symbol = (version: "v-symbol", aspect: CGFloat(1))
        let wordmark = (version: "v-wordmark", aspect: CGFloat(2.3))
        #expect(AirlineLogo.pick([("LHX", nil, false), ("DLH", symbol, false)]) == ("DLH", .logo))
        #expect(AirlineLogo.pick([("EJU", nil, false), ("EZY", wordmark, true)]) == ("EZY", .fin))
        // The operator's own wordmark gives way to the parent's symbol, but beats nothing.
        #expect(AirlineLogo.pick([("AAA", wordmark, false), ("BBB", symbol, false)]) == ("BBB", .logo))
        #expect(AirlineLogo.pick([("AAA", wordmark, false), ("BBB", nil, false)]) == ("AAA", .logo))
        #expect(AirlineLogo.pick([("QQQ", nil, false)]).face == .neutral)
        // Every airline in the reference list has a mark of its own or through its parent: no neutral glyph.
        let reference = ReferenceData.bundled()
        let marked = BundledLogos.wordmarks.union(BundledLogos.symbols)
        let bare = reference.airlines.map(\.id).filter { code in
            !AirlineParents.chain(code).contains { marked.contains($0) || AirlineTailMark.fin($0) != nil }
        }
        // Four still lack one: BHA, FJL and RPB, and Airlink (LNK), whose fin the image model refuses to redraw.
        #expect(bare.count <= 4, "airlines with no mark at all: \(bare.sorted())")
    }

    /// The fin is found from either code: French bee (BF / FBU) and Flair (F8 / FLE) resolve to their
    /// ICAO, which names the bundled fin.
    @MainActor @Test func finsResolveFromIataOrIcao() {
        let reference = ReferenceData.bundled()
        for (iata, icao) in [("BF", "FBU"), ("F8", "FLE")] {
            for code in [iata, icao] {
                let airline = TravelFacts.badgeAirline(code: code, key: code, reference: reference)
                #expect(airline?.id == icao, "\(code)")
                let lookup = AirlineLogo.lookupCode(airline: airline, code: code)
                #expect(lookup == icao)
            }
        }
        #expect(AirlineTailMark.fin("FLE") != nil)
        #expect(AirlineTailMark.fin("fle") != nil)
        #expect(AirlineTailMark.fin("ZZQ") == nil)
    }
}

extension AirlineMarkFaceTests {
    /// Ink all in one luminance bin.
    private func ink(_ lum: Double) -> [Double] {
        var h = [Double](repeating: 0, count: BrandArt.bins)
        h[min(Int(lum * Double(BrandArt.bins)), BrandArt.bins - 1)] = 1
        return h
    }

    @Test func onlyLostMarksTurnOneColour() {
        let light = LogoSurface.page.luminance(dark: false), dark = LogoSurface.page.luminance(dark: true)
        let red = BrandArt.relativeLuminance(r: 1, g: 0, b: 0)
        let navy = BrandArt.relativeLuminance(r: 0.04, g: 0.1, b: 0.27)
        // Air France's red keeps its colour on both pages.
        #expect(!AirlineLogo.isLost(histogram: ink(red), surface: light))
        #expect(!AirlineLogo.isLost(histogram: ink(red), surface: dark))
        // Lufthansa's navy is lost on the dark page only.
        #expect(AirlineLogo.isLost(histogram: ink(navy), surface: dark))
        #expect(!AirlineLogo.isLost(histogram: ink(navy), surface: light))
        // White ink is lost on the light page.
        #expect(AirlineLogo.isLost(histogram: ink(1), surface: light))
    }
}
