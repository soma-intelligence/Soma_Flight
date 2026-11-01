import Foundation
import Testing
@testable import FlightKit

/// The Commons logo library in the bundle (`BundledLogos`): what ships, that it matches the credits in
/// Acknowledgements, and that it answers when the backend cannot.
@Suite struct BundledLogosTests {
    /// A backend that never answers (offline), or answers one fixed asset.
    struct Remote: BrandAssetService {
        var answer: BrandLookup = .unavailable
        func asset(_ icao: String, _ kind: BrandAssetKind, type: String?) async -> BrandAsset? { answer.asset }
        func lookup(_ icao: String, _ kind: BrandAssetKind, type: String?) async -> BrandLookup { answer }
    }

    @MainActor @Test func everyBundledMarkDecodesAndIsCredited() async throws {
        let words = BundledLogos.wordmarks, symbols = BundledLogos.symbols
        #expect(words.count == 109)
        #expect(symbols.count == 37)
        #expect(symbols.isSubset(of: words))
        // What ships is exactly what Settings > Acknowledgements credits.
        let credits = AcknowledgementsView.logoCredits
        #expect(Set(credits.map(\.icao)) == words)
        #expect(Set(credits.filter { $0.symbol != nil }.map(\.icao)) == symbols)

        let service = BundledLogos(over: Remote())
        for icao in words.sorted() {
            let word = try #require(await service.asset(icao, .wordmark), "\(icao)")
            #expect(word.format == "webp" && word.decodes, "\(icao)")
            let logo = try #require(await service.asset(icao, .logo), "\(icao)")
            #expect(logo.decodes, "\(icao)")
            // The square slot gets the symbol when there is one, else the wordmark (as the backend serves it).
            #expect((logo == word) == !symbols.contains(icao), "\(icao)")
        }
    }

    @Test func answersOfflineOnlyForKindsAndAirlinesItHas() async {
        let service = BundledLogos(over: Remote())
        #expect(await service.lookup(" aal ", .logo, type: nil).asset?.version.hasSuffix("symbol") == true)
        #expect(await service.lookup("QTR", .logo, type: nil).asset?.version.hasSuffix("wordmark") == true)
        #expect(await service.lookup("AAL", .logoDark, type: nil) == .unavailable)
        #expect(await service.lookup("AAL", .tail, type: nil) == .unavailable)
        #expect(await service.lookup("ZZZ", .logo, type: nil) == .unavailable)
        // A known absence on the backend still falls back to the library.
        let missing = BundledLogos(over: Remote(answer: .missing))
        #expect(await missing.lookup("QTR", .wordmark, type: nil).asset != nil)
        #expect(await missing.lookup("ZZZ", .wordmark, type: nil) == .missing)
    }

    @Test func theBackendWinsWhenItAnswers() async {
        let remote = BrandAsset(data: Data([1]), format: "png", version: "airhex-1")
        let service = BundledLogos(over: Remote(answer: .found(remote)))
        #expect(await service.asset("AAL", .logo) == remote)
        #expect(await service.asset("QTR", .wordmark) == remote)
    }

    /// A bundled airline gets its mark in the app with no network: through the app's own stack and the
    /// loader `AirlineLogo` draws from.
    @MainActor @Test func aBundledAirlineResolvesWithoutNetwork() async throws {
        let service = BundledSideViews(over: BundledLogos(over: Remote()))
        BrandArtMemo.shared.set("QTR", .logo, .none)
        BrandArtMemo.shared.set("QTR", .logoDark, .none)
        let light = try #require(await AirlineLogo.load(icao: "QTR", dark: false, service: service, maxPixel: 144))
        #expect(light.version.hasPrefix("commons-"))
        #expect(light.pixelSize > 0 && light.pixelSize <= 192)
        let dark = try #require(await AirlineLogo.load(icao: "QTR", dark: true, service: service, maxPixel: 144))
        #expect(dark.version == light.version)
        #expect(AirlineLogo.held(icao: "QTR", dark: true) != nil)
    }
}
