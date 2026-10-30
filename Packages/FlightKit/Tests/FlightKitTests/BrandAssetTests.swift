import CoreGraphics
import Foundation
import ImageIO
import SwiftUI
import Testing
import UniformTypeIdentifiers
@testable import FlightKit

/// The brand cache (`SupabaseBrandAssetService`) against a counting transport and an injected clock, and
/// the choices `AirlineLogo` makes (monogram, dark variant, plate).
struct BrandAssetTests {
    // MARK: Fixtures

    /// A PNG of `side` px: a centred bar in `gray` (0 black, 1 white) on transparency, or opaque all over.
    static func png(gray: CGFloat = 0.1, side: Int = 16, opaque: Bool = false) -> Data {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: gray, green: gray, blue: gray, alpha: 1))
        let s = CGFloat(side)
        ctx.fill(opaque ? CGRect(x: 0, y: 0, width: s, height: s) : CGRect(x: 0, y: s / 3, width: s, height: s / 3))
        let image = ctx.makeImage()!
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
        return data as Data
    }

    final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value = Date(timeIntervalSince1970: 1_800_000_000)
        var now: Date { lock.withLock { value } }
        func advance(_ seconds: TimeInterval) { lock.withLock { value += seconds } }
    }

    /// Answers `meta` from `answer` and downloads from `files`, counting both.
    actor Transport: BrandAssetTransport {
        var answer: Result<BrandAssetMeta, APIError>
        var files: [URL: Data] = [:]
        var failDownloads = false
        private(set) var metaCalls = 0
        private(set) var downloads = 0

        init(_ answer: Result<BrandAssetMeta, APIError>) { self.answer = answer }

        func set(_ answer: Result<BrandAssetMeta, APIError>) { self.answer = answer }
        func serve(_ url: URL, _ data: Data) { files[url] = data }

        func meta(airline: String, kind: BrandAssetKind, type: String?) async throws(APIError) -> BrandAssetMeta {
            metaCalls += 1
            return try answer.get()
        }

        func download(_ url: URL) async throws(APIError) -> Data {
            downloads += 1
            guard !failDownloads, let data = files[url] else { throw .providerUnavailable }
            return data
        }
    }

    static func meta(_ version: String) -> BrandAssetMeta {
        BrandAssetMeta(version: version, format: "png", width: 384,
                       url: URL(string: "https://example.supabase.co/storage/v1/object/sign/brand-assets/logos/UAL/logo-\(version).png")!,
                       smallUrl: URL(string: "https://example.supabase.co/storage/v1/object/sign/brand-assets/logos/UAL/logo-\(version)-192.png")!)
    }

    let dir = FileManager.default.temporaryDirectory.appending(path: "brand-tests-\(UUID().uuidString)")
    let clock = Clock()

    func service(_ transport: Transport) -> SupabaseBrandAssetService {
        let clock = clock
        return SupabaseBrandAssetService(backend: nil, cacheDir: dir, transport: transport, clock: { clock.now })
    }

    /// A transport serving version `v` of UAL's logo (the small rendition, as logos use).
    func transport(_ v: String = "v1", gray: CGFloat = 0.1) async -> Transport {
        let t = Transport(.success(Self.meta(v)))
        await t.serve(Self.meta(v).smallUrl!, Self.png(gray: gray))
        return t
    }

    func files() -> [String] {
        let ual = dir.appending(path: "UAL")
        return ((try? FileManager.default.contentsOfDirectory(atPath: ual.path)) ?? []).sorted()
    }

    // MARK: Monogram (Review Focus 1)

    @Test func monogramUsesIata() {
        let united = Airline(id: "UAL", iata: "UA", name: "United", colorPrimary: "#0033A0")
        #expect(AirlineLogo.monogram(airline: united, code: "UAL") == "UA")
        #expect(AirlineLogo.monogram(airline: united, code: "XX") == "UA")
        #expect(AirlineLogo.tintSource(airline: united, code: "UA") == .brand(r: 0, g: 0x33 / 255.0, b: 0xA0 / 255.0))
    }

    @Test func unknownAirlineMonogram() {
        #expect(AirlineLogo.monogram(airline: nil, code: "ZED") == "ZE")
        #expect(AirlineLogo.monogram(airline: nil, code: "Q") == "Q")
        // Known but without an IATA code: the code's first two letters.
        let noIata = Airline(id: "XAX", name: "Charter", colorPrimary: "not a colour")
        #expect(AirlineLogo.monogram(airline: noIata, code: "XAX") == "XA")
        #expect(AirlineLogo.tintSource(airline: nil, code: "ZED") == .palette("ZED"))
        #expect(AirlineLogo.tintSource(airline: noIata, code: "XA") == .palette("XAX"))
    }

    // MARK: Cache

    @Test func cacheHitSkipsNetwork() async throws {
        let t = await transport()
        let svc = service(t)
        let first = try #require(await svc.asset("ual", .logo))
        #expect(first.version == "v1" && first.format == "png")
        clock.advance(6 * 24 * 3600)
        let again = try #require(await svc.asset("UAL", .logo))
        #expect(again == first)
        #expect(await t.metaCalls == 1)
        #expect(await t.downloads == 1)
        // A new run reads the disk.
        let next = service(t)
        #expect(await next.asset("UAL", .logo) == first)
        #expect(await t.metaCalls == 1)
        #expect(await t.downloads == 1)
        #expect(files() == ["logo-v1.png"])
    }

    @Test func newVersionReplacesFile() async throws {
        let t = await transport()
        let svc = service(t)
        _ = try #require(await svc.asset("UAL", .logo))
        await t.set(.success(Self.meta("v2")))
        await t.serve(Self.meta("v2").smallUrl!, Self.png(gray: 0.9))
        clock.advance(SupabaseBrandAssetService.revalidateAfter + 1)
        let fresh = try #require(await svc.asset("UAL", .logo))
        #expect(fresh.version == "v2")
        #expect(fresh.data == Self.png(gray: 0.9))
        #expect(files() == ["logo-v2.png"])
        #expect(await t.metaCalls == 2)
        #expect(await t.downloads == 2)
        #expect(await svc.savedIndex().entries["UAL/logo"]?.version == "v2")
    }

    @Test func sameVersionOnlyTouches() async throws {
        let t = await transport()
        let svc = service(t)
        _ = try #require(await svc.asset("UAL", .logo))
        clock.advance(SupabaseBrandAssetService.revalidateAfter + 1)
        let same = try #require(await svc.asset("UAL", .logo))
        #expect(same.version == "v1")
        #expect(await t.metaCalls == 2)
        #expect(await t.downloads == 1)
        #expect(await svc.savedIndex().entries["UAL/logo"]?.checkedAt == clock.now)
        // Touched: the next week starts now.
        clock.advance(24 * 3600)
        _ = await svc.asset("UAL", .logo)
        #expect(await t.metaCalls == 2)
        #expect(files() == ["logo-v1.png"])
    }

    @Test func negativeCacheSkipsNetwork() async {
        let t = Transport(.failure(.notFound))
        let svc = service(t)
        #expect(await svc.asset("UAL", .logo) == nil)
        clock.advance(23 * 3600)
        #expect(await svc.asset("UAL", .logo) == nil)
        #expect(await t.metaCalls == 1)
        // Remembered across runs too.
        #expect(await service(t).asset("UAL", .logo) == nil)
        #expect(await t.metaCalls == 1)
        clock.advance(2 * 3600)
        #expect(await svc.asset("UAL", .logo) == nil)
        #expect(await t.metaCalls == 2)
        // Another kind is another key.
        #expect(await svc.asset("UAL", .logoDark) == nil)
        #expect(await t.metaCalls == 3)
    }

    @Test func networkFailureKeepsCachedFile() async throws {
        let t = await transport()
        let svc = service(t)
        let cached = try #require(await svc.asset("UAL", .logo))
        await t.set(.failure(.offline))
        clock.advance(SupabaseBrandAssetService.revalidateAfter + 1)
        #expect(await svc.asset("UAL", .logo) == cached)
        #expect(await t.metaCalls == 2)
        // Retried at most once a minute.
        clock.advance(30)
        #expect(await svc.asset("UAL", .logo) == cached)
        #expect(await t.metaCalls == 2)
        clock.advance(31)
        #expect(await svc.asset("UAL", .logo) == cached)
        #expect(await t.metaCalls == 3)
        #expect(files() == ["logo-v1.png"])
        // A failed download of a new version keeps the old file as well.
        await t.set(.success(Self.meta("v2")))
        clock.advance(61)
        #expect(await svc.asset("UAL", .logo) == cached)
        #expect(files() == ["logo-v1.png"])
        // Nothing cached and offline: nil, not a remembered miss.
        let other = Transport(.failure(.offline))
        #expect(await service(other).asset("DAL", .logo) == nil)
        #expect(await svc.savedIndex().misses["DAL/logo"] == nil)
    }

    @Test func corruptFileIsDropped() async throws {
        let t = await transport()
        _ = try #require(await service(t).asset("UAL", .logo))
        let file = dir.appending(path: "UAL/logo-v1.png")
        try Data("<svg xmlns='http://www.w3.org/2000/svg'/>".utf8).write(to: file)
        // A new run finds the file broken, deletes it and fetches again.
        let svc = service(t)
        let fetched = try #require(await svc.asset("UAL", .logo))
        #expect(fetched.decodes)
        #expect(await t.metaCalls == 2)
        #expect(await t.downloads == 2)
        #expect(try Data(contentsOf: file) == fetched.data)

        // A download that does not decode is never written and counts as a miss.
        let bad = Transport(.success(Self.meta("v9")))
        await bad.serve(Self.meta("v9").smallUrl!, Data("not an image".utf8))
        let svc2 = SupabaseBrandAssetService(backend: nil, cacheDir: dir.appending(path: "other"), transport: bad,
                                             clock: { [clock] in clock.now })
        #expect(await svc2.asset("UAL", .logo) == nil)
        #expect(await svc2.savedIndex().entries.isEmpty)
        #expect(await svc2.savedIndex().misses["UAL/logo"] != nil)
        // An SVG answer is refused as well, whatever its bytes.
        #expect(!BrandAsset(data: Self.png(), format: "svg", version: "1").decodes)
    }

    @Test func badCodesNeverReachTheNetwork() async {
        let t = await transport()
        let svc = service(t)
        #expect(await svc.asset("UA", .logo) == nil)
        #expect(await svc.asset("../X", .logo) == nil)
        #expect(await svc.asset("UAL", .sideView, type: nil) == nil)
        #expect(await svc.asset("UAL", .sideView, type: "B3/8") == nil)
        #expect(await t.metaCalls == 0)
        #expect(SupabaseBrandAssetService.key("ual", .sideView, "b38m") == "UAL/side_view-B38M")
        #expect(SupabaseBrandAssetService.fileName(key: "UAL/logo", version: "../a b", format: "png") == "UAL/logo-.._a_b.png")
    }

    @Test func concurrentRequestsShareOneCall() async {
        let t = await transport()
        let svc = service(t)
        await withTaskGroup(of: BrandAsset?.self) { group in
            for _ in 0..<12 { group.addTask { await svc.asset("UAL", .logo) } }
            for await a in group { #expect(a?.version == "v1") }
        }
        #expect(await t.metaCalls == 1)
    }

    // MARK: AirlineLogo choices

    /// Uses codes no other test draws: the memo is shared with the snapshot suite.
    @MainActor @Test func darkModePicksDarkVariant() async throws {
        let light = BrandAsset(data: Self.png(gray: 0.1), format: "png", version: "light-1")
        let dark = BrandAsset(data: Self.png(gray: 0.95), format: "png", version: "dark-1")
        let both = FakeBrandAssetService(seeded: [("QQA", .logo, light), ("QQA", .logoDark, dark)])
        #expect(await AirlineLogo.load(icao: "QQA", dark: true, service: both)?.version == "dark-1")
        #expect(await AirlineLogo.load(icao: "QQA", dark: false, service: both)?.version == "light-1")
        #expect(AirlineLogo.held(icao: "QQA", dark: true)?.version == "dark-1")
        #expect(AirlineLogo.held(icao: "QQA", dark: false)?.version == "light-1")
        // No dark variant: the logo in both schemes.
        let one = FakeBrandAssetService(seeded: [("QQB", .logo, light)])
        #expect(await AirlineLogo.load(icao: "QQB", dark: true, service: one)?.version == "light-1")
        // Nothing at all: the monogram.
        #expect(await AirlineLogo.load(icao: "ZZZ", dark: true, service: FakeBrandAssetService()) == nil)
        #expect(AirlineLogo.held(icao: "ZZZ", dark: true) == nil)
    }

    @Test func plateFollowsContrast() throws {
        let darkInk = try #require(BrandArt.make(BrandAsset(data: Self.png(gray: 0.1), format: "png", version: "1")))
        #expect(darkInk.luminance < 0.05)
        #expect(darkInk.coverage > 0.2 && darkInk.coverage < 0.5)
        // Dark ink vanishes on the dark page: white plate. On the light page it reads alone.
        #expect(AirlineLogo.plate(luminance: darkInk.luminance, coverage: darkInk.coverage, dark: true) == .light)
        #expect(AirlineLogo.plate(luminance: darkInk.luminance, coverage: darkInk.coverage, dark: false) == nil)
        // White ink on the light page: dark plate.
        let whiteInk = try #require(BrandArt.make(BrandAsset(data: Self.png(gray: 1), format: "png", version: "1")))
        #expect(AirlineLogo.plate(luminance: whiteInk.luminance, coverage: whiteInk.coverage, dark: false) == .dark)
        #expect(AirlineLogo.plate(luminance: whiteInk.luminance, coverage: whiteInk.coverage, dark: true) == nil)
        // A logo with its own background sits on the plate of its tone, on either page.
        let tile = try #require(BrandArt.make(BrandAsset(data: Self.png(gray: 0.1, opaque: true), format: "png", version: "1")))
        #expect(tile.coverage > 0.95)
        #expect(AirlineLogo.plate(luminance: tile.luminance, coverage: tile.coverage, dark: true) == .dark)
        let box = try #require(BrandArt.make(BrandAsset(data: Self.png(gray: 1, opaque: true), format: "png", version: "1")))
        #expect(AirlineLogo.plate(luminance: box.luminance, coverage: box.coverage, dark: true) == .light)
        #expect(AirlineLogo.plate(luminance: box.luminance, coverage: box.coverage, dark: false) == .light)
        // Mid green ink (Frontier's) is under 4.5:1 on the dark page.
        #expect(AirlineLogo.plate(luminance: 0.15, coverage: 0.3, dark: true) == .light)
    }

    @Test func bundledFakesCoverTheFakeHistory() async {
        let fake = FakeBrandAssetService.bundled()
        for icao in FakeBrandAssetService.bundledAirlines {
            let logo = await fake.asset(icao, .logo)
            #expect(logo?.decodes == true, "\(icao)")
        }
        #expect(await FakeBrandAssetService().asset("UAL", .logo) == nil)
        #expect(await fake.asset("UAL", .logoDark) == nil)
        let ref = ReferenceData.bundled()
        for name in Set(FakeSeed.load("past_flights", as: [PastFlight].self).compactMap(\.airline)) {
            let icao = ref.airline(name)?.id
            #expect(icao.map(FakeBrandAssetService.bundledAirlines.contains) == true, "\(name)")
        }
    }
}
