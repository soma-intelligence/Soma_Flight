import CoreGraphics
import Foundation
import ImageIO
import SwiftUI
import Testing
import UniformTypeIdentifiers
@testable import FlightKit

/// Liveries (seed, derived, plain), the fin art choice and where `AircraftImage` takes its picture from.
struct LiveryTests {
    /// A PNG of `width` by `height` px, a grey block on transparency (`inset` px of clear margin).
    static func png(width: Int, height: Int, inset: Int = 1, gray: CGFloat = 0.2) -> Data {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: gray, green: gray, blue: gray, alpha: 1))
        ctx.fill(CGRect(x: inset, y: inset, width: width - 2 * inset, height: height - 2 * inset))
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
        return data as Data
    }

    static func asset(width: Int, height: Int, inset: Int = 1, gray: CGFloat = 0.2) -> BrandAsset {
        BrandAsset(data: png(width: width, height: height, inset: inset, gray: gray), format: "png", version: "v1")
    }

    @Test func seedDecodes() throws {
        let seed = LiverySeed.all
        #expect(Set(seed.keys) == ["UAL", "AFR", "RYR"])
        let reference = ReferenceData.bundled()
        for (icao, livery) in seed {
            #expect(reference.livery(icao) == livery)
            #expect(reference.airline(icao) != nil, "\(icao) not in the airline list")
            let colors = [livery.fuselageTop, livery.belly, livery.engines] + livery.tail.colors
                + livery.cheatline.map(\.color) + [livery.winglets, livery.title?.color].compactMap { $0 }
            for c in colors { #expect(Livery.normalized(c) != nil, "\(icao): bad colour \(c)") }
            #expect((0...1).contains(livery.bellySplit))
        }
        // Round trip through JSON keeps every case.
        let all = Array(seed.values)
        let back = try JSONDecoder().decode([Livery].self, from: JSONEncoder().encode(all))
        #expect(back == all)
        #expect(reference.livery("UA") == seed["UAL"])
    }

    @Test func derivedUsesBrandColors() {
        let afr = Airline(id: "XYZ", name: "Test Air", colorPrimary: "#112233", colorSecondary: "#ee0000")
        let livery = Livery.derived(from: afr)
        #expect(livery.airline == "XYZ")
        #expect(livery.fuselageTop == "#F7F7F8")
        #expect(livery.belly == "#D5D8DC")
        #expect(livery.bellySplit == 0.3)
        #expect(livery.tail == .solid("#112233"))
        #expect(livery.engines == "#112233")
        #expect(livery.cheatline == [Stripe(color: "#EE0000", from: 0.30, to: 0.36, sweep: 0)])
        #expect(livery.title?.text == "Test Air")
        #expect(livery.title?.color == "#112233")
        // A listed airline without a seed entry is derived.
        let reference = ReferenceData.bundled()
        let dlh = reference.airline("DLH")!
        #expect(reference.livery("DLH") == .derived(from: dlh))
    }

    @Test func derivedWithoutSecondaryHasNoStripe() {
        let livery = Livery.derived(from: Airline(id: "ABC", name: "Mono", colorPrimary: "#00B140"))
        #expect(livery.cheatline.isEmpty)
        // Transavia green is under 3:1 on white: darkened until it reads.
        #expect(livery.tail == .solid(Livery.readable("#00B140", else: nil)))
        #expect(livery.tail != .solid("#00B140"))
    }

    @Test func unknownAirlineIsPlain() {
        #expect(ReferenceData.bundled().livery("ZZZQ") == .plain)
        #expect(ReferenceData.bundled().livery("") == .plain)
    }

    @Test func stripesInsideFuselage() {
        let reference = ReferenceData.bundled()
        var liveries = Array(LiverySeed.all.values)
        liveries += reference.airlines.map { reference.livery($0.id) }
        for livery in liveries {
            for s in livery.cheatline {
                #expect(0 <= s.from && s.from < s.to && s.to <= 1, "\(livery.airline): \(s)")
            }
        }
        // The stripe path sits between its fractions of the barrel ahead of the sweep.
        let g = AircraftGeometry.geometry(.b777)
        let stripe = Stripe(color: "#000000", from: 0.30, to: 0.36)
        let box = LiveryRenderer.stripePath(stripe, geometry: g).boundingRect
        let d = g.fuselageTopM - g.fuselageBottomM
        #expect(abs(box.minY - (g.fuselageBottomM + 0.30 * d)) < 0.001)
        #expect(abs(box.maxY - (g.fuselageBottomM + 0.36 * d)) < 0.001)
    }

    @Test func noFinLogoWithoutAsset() {
        #expect(FinArt.choose(tail: nil, logo: nil) == nil)
        // A wordmark (wide) never goes on the fin.
        #expect(FinArt.choose(tail: nil, logo: Self.asset(width: 192, height: 30)) == nil)
        // A symbol (near square) does; a tail asset wins over it.
        let symbol = Self.asset(width: 80, height: 76)
        #expect(FinArt.choose(tail: nil, logo: symbol) == symbol)
        let tail = Self.asset(width: 40, height: 80)
        #expect(FinArt.choose(tail: tail, logo: symbol) == tail)
        // A flag tail is its own art.
        let afr = LiveryRenderer(livery: LiverySeed.all["AFR"]!, geometry: .geometry(.a320), scale: 1, toView: .identity)
        #expect(!afr.finTakesArt)
        // Too small to hold up on a fin.
        #expect(FinArt.choose(tail: nil, logo: Self.asset(width: 40, height: 40)) == nil)
        // The logo is the wordmark (same version): no fin art whatever its shape.
        let squareWord = Self.asset(width: 96, height: 96)
        #expect(FinArt.choose(tail: nil, logo: squareWord, wordmark: squareWord) == nil)
        // The logo's version differs from the wordmark's: it is the symbol, taken up to 2.5:1.
        var wideSymbol = Self.asset(width: 180, height: 80)
        wideSymbol.version = "symbol"
        #expect(FinArt.choose(tail: nil, logo: wideSymbol, wordmark: Self.asset(width: 300, height: 60)) == wideSymbol)
        #expect(FinArt.choose(tail: nil, logo: wideSymbol) == nil, "without a wordmark only near squares pass")
    }

    /// Live builds: an airline with only a wordmark gets the 192 px rendition as `.logo` and the 384 px
    /// one as `.wordmark`. The bytes differ, the version (the source file's) does not: no fin art.
    @Test func wordmarkOnlyAirlineGetsNoTailLogo() {
        let small = BrandAsset(data: Self.png(width: 192, height: 120, inset: 1, gray: 0.2), format: "png", version: "abc123")
        let large = BrandAsset(data: Self.png(width: 384, height: 240, inset: 1, gray: 0.2), format: "png", version: "abc123")
        #expect(small.data != large.data)
        #expect(FinArt.choose(tail: nil, logo: small, wordmark: large) == nil)
        // The same shapes from a symbol file (its own version) do go on the fin.
        var symbol = small
        symbol.version = "def456"
        #expect(FinArt.choose(tail: nil, logo: symbol, wordmark: large) == symbol)
    }

    @Test func finArtInkFlipsOnLowContrast() {
        // Dark navy art on a navy fin turns white; on a white fin it stays as it is.
        let navy = BrandArt.relativeLuminance(r: 0.02, g: 0.09, b: 0.30)
        #expect(LiveryRenderer.artInk(finLuminance: navy, inkLuminance: navy) == .white)
        #expect(LiveryRenderer.artInk(finLuminance: 1, inkLuminance: navy) == .asIs)
        #expect(LiveryRenderer.artInk(finLuminance: 0.95, inkLuminance: 0.9) == .dark)
    }

    @Test func derivedTitleAndFinReadOnWhite() {
        let reference = ReferenceData.bundled()
        for airline in reference.airlines {
            let livery = Livery.derived(from: airline)
            #expect(Livery.contrastOnWhite(livery.title!.color) >= 3, "\(airline.id) title \(livery.title!.color)")
            for c in livery.tail.colors { #expect(Livery.contrastOnWhite(c) >= 3, "\(airline.id) fin \(c)") }
        }
        // A pale primary gives way to a readable secondary, else to itself darkened.
        let yellow = Livery.derived(from: Airline(id: "YEL", name: "Yellow", colorPrimary: "#FFE600", colorSecondary: "#1A2B88"))
        #expect(yellow.title?.color == "#1A2B88")
        let pale = Livery.derived(from: Airline(id: "PAL", name: "Pale", colorPrimary: "#FFE600"))
        #expect(pale.tail.colors.first != "#FFE600")
        #expect(Livery.contrastOnWhite(pale.tail.colors[0]) >= 3)
    }

    @Test func titleNeverCrossesADoor() throws {
        let titles = Array(LiverySeed.all.values.compactMap(\.title)) + [
            LiveryTitle(text: "Lufthansa Cargo", color: "#000000", weight: "bold", tracking: 0.02),
            LiveryTitle(text: "Aerolineas Argentinas", color: "#000000", weight: "bold", tracking: 0.02),
            LiveryTitle(text: "Brussels Airlines", color: "#000000", weight: "heavy", tracking: 0.1),
        ]
        let reference = ReferenceData.bundled()
        let types: [AircraftType?] = [nil] + ["A319", "A320", "A321", "B737", "B738", "B739", "B37M", "B38M", "B3XM",
                                             "B772", "B77W", "B788", "B789", "B78X", "A359", "A35K", "A333", "E190",
                                             "BCS1", "BCS3", "A332", "A339", "A388", "B744", "B748", "B74S", "B752", "B753",
                                             "B762", "B763", "B764", "E170", "E295", "CRJ2", "CRJ9", "AT45", "AT76"]
            .map { reference.type($0) }
        for type in types {
            let g = AircraftGeometry.geometry(type: type)
            let doors = g.shapes.filter { $0.part == .door || $0.layer == .engine && $0.part == .propeller }
                .map { $0.path.boundingRect }
            for title in titles {
                let layout = try #require(LiveryRenderer.titleLayout(title, geometry: g), "\(title.text) on \(type?.id ?? "-")")
                for door in doors {
                    #expect(!layout.frame.intersects(door), "\(title.text) crosses a door on \(type?.id ?? "generic")")
                }
                #expect(layout.frame.maxY < g.fuselageTopM, "\(title.text) above the crown on \(type?.id ?? "-")")
                #expect(layout.size > 0)
            }
        }
    }

    @Test func badLiveryJSONIsRefused() {
        let twoKeys = ##"{"solid": "#000000", "gradient": ["#000000"]}"##
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(TailPaint.self, from: Data(twoKeys.utf8)) }
        let weight = ##"{"text": "X", "color": "#000000", "weight": "light", "tracking": 0}"##
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(LiveryTitle.self, from: Data(weight.utf8)) }
        let steep = ##"{"color": "#000000", "from": 0.1, "to": 0.2, "sweep": 70}"##
        #expect((try? JSONDecoder().decode(Stripe.self, from: Data(steep.utf8)))?.sweep == Stripe.maxSweep)
    }

    @Test func accessibilityLabelNamesTheColours() {
        let reference = ReferenceData.bundled()
        #expect(AircraftImage.label(airline: reference.airline("DAL"), type: reference.type("A321")) == "Airbus A321 in Delta colours")
        #expect(AircraftImage.label(airline: reference.airline("AFR"), type: reference.type("A359")).hasSuffix("in Air France colours"))
        #expect(AircraftImage.label(airline: nil, type: reference.type("A321")) == "Airbus A321")
    }

    @MainActor @Test func finArtLoadsOnlyWhenThereIsArt() async {
        AircraftArtMemo.shared.removeAll()
        let none = await FinArt.load(icao: "UAL", service: FakeBrandAssetService.bundled())
        #expect(none == nil, "UAL's bundled logo is a wordmark")
        let symbolService = FakeBrandAssetService(seeded: [("AAL", .logo, Self.asset(width: 64, height: 64))])
        #expect(await FinArt.load(icao: "AAL", service: symbolService) != nil)
        AircraftArtMemo.shared.removeAll()
    }

    /// The KLM crown once sat on a canvas twice its width (192 by 54 px): too wide and too short for the fin.
    /// Cropped to the crown it passes, told apart from the wordmark.
    @MainActor @Test func klmCrownGoesOnTheFin() async {
        AircraftArtMemo.shared.removeAll()
        let art = await FinArt.load(icao: "KLM", service: FakeBrandAssetService.bundled())
        #expect(art != nil)
        AircraftArtMemo.shared.removeAll()
    }

    @Test func aircraftImagePrefersProvider() async {
        let reference = ReferenceData.bundled()
        let side = Self.asset(width: 400, height: 100)
        let service = FakeBrandAssetService(seeded: [("UAL", .sideView, side)], type: "B77W")
        let source = await AircraftImage.source(airline: reference.airline("UAL"), type: reference.type("B77W"),
                                                service: service, reference: reference)
        #expect(source == .provider(side))
        // Clear margins are cropped before the shape is judged: a 400 x 200 canvas holding a 380 x 80 plane.
        let padded = BrandAsset(data: Self.png(width: 400, height: 200, inset: 0), format: "png", version: "v1")
        #expect(ProviderSideView.prepare(padded) == nil, "2:1 is no profile")
        let plane = Self.paddedPlane()
        let art = ProviderSideView.prepare(plane)
        #expect(art != nil)
        #expect(abs((art?.aspect ?? 0) - 380.0 / 80) < 0.1)
    }

    /// 400 x 200 transparent canvas with a 380 x 80 block in it (5:1 once cropped).
    static func paddedPlane() -> BrandAsset {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: 400, height: 200, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 0.8, green: 0.8, blue: 0.8, alpha: 1))
        ctx.fill(CGRect(x: 10, y: 60, width: 380, height: 80))
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
        return BrandAsset(data: data as Data, format: "png", version: "v1")
    }

    @Test func aircraftImageFallsBackToRenderer() async {
        let reference = ReferenceData.bundled()
        let service = FakeBrandAssetService(seeded: [("UAL", .sideView, Self.asset(width: 400, height: 100))], type: "B77W")
        // Another type: no provider picture, the UAL seed livery.
        let other = await AircraftImage.source(airline: reference.airline("UAL"), type: reference.type("B789"),
                                               service: service, reference: reference)
        #expect(other == .renderer(LiverySeed.all["UAL"]!))
        // Derived livery for an airline without a seed entry, plain without an airline.
        let dlh = await AircraftImage.source(airline: reference.airline("DLH"), type: reference.type("A320"),
                                             service: service, reference: reference)
        #expect(dlh == .renderer(.derived(from: reference.airline("DLH")!)))
        let none = await AircraftImage.source(airline: nil, type: nil, service: service, reference: reference)
        #expect(none == .renderer(.plain))
        // A square "side view" is no profile: the renderer draws instead.
        let square = FakeBrandAssetService(seeded: [("UAL", .sideView, Self.asset(width: 200, height: 200))], type: "B77W")
        let fallback = await AircraftImage.source(airline: reference.airline("UAL"), type: reference.type("B77W"),
                                                  service: square, reference: reference)
        #expect(fallback == .renderer(LiverySeed.all["UAL"]!))
    }
}
