import CoreGraphics
import Foundation
import ImageIO
import SwiftUI
import Testing
import UniformTypeIdentifiers
@testable import FlightKit

/// Liveries (seed, derived, plain), the fin art choice and where `AircraftImage` takes its picture from.
struct LiveryTests {
    /// A PNG of `width` by `height` px, a grey block on transparency.
    static func png(width: Int, height: Int) -> Data {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 0.2, green: 0.2, blue: 0.2, alpha: 1))
        ctx.fill(CGRect(x: 1, y: 1, width: width - 2, height: height - 2))
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
        return data as Data
    }

    static func asset(width: Int, height: Int) -> BrandAsset {
        BrandAsset(data: png(width: width, height: height), format: "png", version: "v1")
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
        #expect(livery.tail == .solid("#00B140"))
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
        let symbol = Self.asset(width: 64, height: 60)
        #expect(FinArt.choose(tail: nil, logo: symbol) == symbol)
        let tail = Self.asset(width: 40, height: 80)
        #expect(FinArt.choose(tail: tail, logo: symbol) == tail)
        // A flag tail is its own art.
        let afr = LiveryRenderer(livery: LiverySeed.all["AFR"]!, geometry: .geometry(.a320), scale: 1, toView: .identity)
        #expect(!afr.finTakesArt)
    }

    @MainActor @Test func finArtLoadsOnlyWhenThereIsArt() async {
        AircraftArtMemo.shared.removeAll()
        let none = await FinArt.load(icao: "UAL", service: FakeBrandAssetService.bundled())
        #expect(none == nil, "UAL's bundled logo is a wordmark")
        let symbolService = FakeBrandAssetService(seeded: [("AAL", .logo, Self.asset(width: 64, height: 64))])
        #expect(await FinArt.load(icao: "AAL", service: symbolService) != nil)
        AircraftArtMemo.shared.removeAll()
    }

    @Test func aircraftImagePrefersProvider() async {
        let reference = ReferenceData.bundled()
        let side = Self.asset(width: 400, height: 100)
        let service = FakeBrandAssetService(seeded: [("UAL", .sideView, side)], type: "B77W")
        let source = await AircraftImage.source(airline: reference.airline("UAL"), type: reference.type("B77W"),
                                                service: service, reference: reference)
        #expect(source == .provider(side))
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
    }
}
