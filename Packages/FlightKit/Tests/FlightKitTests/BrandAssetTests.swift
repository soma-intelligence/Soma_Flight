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
        /// Every call waits this long first (a slow link).
        var delay: Duration = .zero
        private(set) var metaCalls = 0
        private(set) var downloads = 0

        init(_ answer: Result<BrandAssetMeta, APIError>) { self.answer = answer }

        func set(_ answer: Result<BrandAssetMeta, APIError>) { self.answer = answer }
        func slow(_ d: Duration) { delay = d }
        func serve(_ url: URL, _ data: Data) { files[url] = data }

        func meta(airline: String, kind: BrandAssetKind, type: String?) async throws(APIError) -> BrandAssetMeta {
            metaCalls += 1
            if delay > .zero { try? await Task.sleep(for: delay) }
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
        return SupabaseBrandAssetService(transport: transport, cacheDir: dir, clock: { clock.now })
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
        // Stale: the cached file at once, the new version fetched behind it.
        #expect(await svc.asset("UAL", .logo)?.version == "v1")
        await svc.settle()
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
        await svc.settle()
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
        await svc.settle()
        #expect(await t.metaCalls == 2)
        // Retried at most once a minute.
        clock.advance(30)
        #expect(await svc.asset("UAL", .logo) == cached)
        await svc.settle()
        #expect(await t.metaCalls == 2)
        clock.advance(31)
        #expect(await svc.asset("UAL", .logo) == cached)
        await svc.settle()
        #expect(await t.metaCalls == 3)
        #expect(files() == ["logo-v1.png"])
        // A failed download of a new version keeps the old file as well.
        await t.set(.success(Self.meta("v2")))
        clock.advance(61)
        #expect(await svc.asset("UAL", .logo) == cached)
        await svc.settle()
        #expect(await svc.asset("UAL", .logo) == cached)
        #expect(files() == ["logo-v1.png"])
        // Nothing cached and offline: unavailable, not a remembered miss.
        let other = Transport(.failure(.offline))
        let fresh = service(other)
        #expect(await fresh.lookup("DAL", .logo, type: nil) == .unavailable)
        #expect(await fresh.savedIndex().misses["DAL/logo"] == nil)
        // A 404 is a known absence.
        #expect(await service(Transport(.failure(.notFound))).lookup("KLM", .logo, type: nil) == .missing)
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
        let svc2 = SupabaseBrandAssetService(transport: bad, cacheDir: dir.appendingPathExtension("other"),
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
        func art(_ gray: CGFloat, opaque: Bool = false) throws -> BrandArt {
            try #require(BrandArt.make(BrandAsset(data: Self.png(gray: gray, opaque: opaque), format: "png", version: "1"),
                                       maxPixel: 64))
        }
        let page = LogoSurface.page, card = LogoSurface.card
        let darkInk = try art(0.1)
        #expect(darkInk.coverage > 0.2 && darkInk.coverage < 0.5)
        // Dark ink vanishes on the dark page: white plate. On the light page and card it reads alone.
        #expect(AirlineLogo.plate(darkInk, surface: page.luminance(dark: true)) == .light)
        #expect(AirlineLogo.plate(darkInk, surface: page.luminance(dark: false)) == nil)
        #expect(AirlineLogo.plate(darkInk, surface: card.luminance(dark: false)) == nil)
        // White ink: dark plate on light surfaces, bare on dark ones.
        let whiteInk = try art(1)
        #expect(AirlineLogo.plate(whiteInk, surface: page.luminance(dark: false)) == .dark)
        #expect(AirlineLogo.plate(whiteInk, surface: card.luminance(dark: false)) == .dark)
        #expect(AirlineLogo.plate(whiteInk, surface: page.luminance(dark: true)) == nil)
        // The surface decides: mid grey ink reads on the white card but not on the dark red delay page.
        let mid = try art(0.35)
        #expect(AirlineLogo.plate(mid, surface: LogoSurface.fixed(0xFFFFFF).luminance(dark: false)) == nil)
        #expect(AirlineLogo.plate(mid, surface: LogoSurface.fixed(0x330D0F).luminance(dark: true)) == .light)
        // A logo with its own background sits on the plate of its tone in both schemes.
        let tile = try art(0.1, opaque: true)
        #expect(tile.coverage > 0.95)
        #expect(AirlineLogo.plate(tile, surface: page.luminance(dark: true)) == .dark)
        #expect(AirlineLogo.plate(tile, surface: page.luminance(dark: false)) == .dark)
        let box = try art(1, opaque: true)
        #expect(AirlineLogo.plate(box, surface: page.luminance(dark: true)) == .light)
        #expect(AirlineLogo.plate(box, surface: page.luminance(dark: false)) == .light)
        // Two tones: half the ink white, half dark. The white half is faint on the light page, so it gets
        // the plate that keeps the most ink readable (dark).
        var split = [Double](repeating: 0, count: BrandArt.bins)
        split[0] = 0.5; split[BrandArt.bins - 1] = 0.5
        #expect(AirlineLogo.plate(histogram: split, coverage: 0.3, border: 0, surface: page.luminance(dark: false)) != nil)
        // Mid green ink (Frontier's) is faint on the dark page.
        var green = [Double](repeating: 0, count: BrandArt.bins)
        green[Int(0.15 * Double(BrandArt.bins))] = 1
        #expect(AirlineLogo.plate(histogram: green, coverage: 0.3, border: 0, surface: page.luminance(dark: true)) == .light)
    }

    @Test func decodeIsAThumbnailAtDisplaySize() throws {
        let big = BrandAsset(data: Self.png(gray: 0.1, side: 1200), format: "png", version: "1")
        let art = try #require(BrandArt.make(big, maxPixel: 102))
        #expect(art.pixelSize <= 102)
        #expect(max(art.image.width, art.image.height) <= 102)
        // Headers only: a truncated file is refused without a decode.
        #expect(!BrandAsset(data: big.data.prefix(big.data.count / 2), format: "png", version: "1").decodes)
    }

    // MARK: Fix round 1

    @Test func staleFileReturnsAtOnceOnASlowLink() async throws {
        let t = await transport()
        let svc = SupabaseBrandAssetService(transport: t, cacheDir: dir, clock: { [clock] in clock.now },
                                            limit: .milliseconds(300))
        let cached = try #require(await svc.asset("UAL", .logo))
        await t.slow(.seconds(5))
        clock.advance(SupabaseBrandAssetService.revalidateAfter + 1)
        let started = ContinuousClock.now
        // Many callers, one background request; none waits for the link.
        for _ in 0..<5 { #expect(await svc.asset("UAL", .logo) == cached) }
        #expect(ContinuousClock.now - started < .milliseconds(250))
        await svc.settle()
        // The time limit gave up on the slow call: counted as a failure, the file kept.
        #expect(await t.metaCalls == 2)
        #expect(await svc.asset("UAL", .logo) == cached)
        #expect(ContinuousClock.now - started < .seconds(3))
    }

    @Test func cacheStaysUnderItsByteCap() async throws {
        let one = Self.png(gray: 0.1).count
        let t = Transport(.success(Self.meta("v1")))
        await t.serve(Self.meta("v1").smallUrl!, Self.png(gray: 0.1))
        // Room for two files.
        let svc = SupabaseBrandAssetService(transport: t, cacheDir: dir, clock: { [clock] in clock.now },
                                            maxBytes: one * 2 + one / 2)
        for icao in ["UAL", "DAL"] { _ = await svc.asset(icao, .logo); clock.advance(60) }
        // UAL used again: DAL is now the least recently used.
        _ = await svc.asset("UAL", .logo)
        clock.advance(60)
        _ = await svc.asset("AAL", .logo)
        let kept = Set(await svc.savedIndex().entries.keys)
        #expect(kept == ["UAL/logo", "AAL/logo"])
        #expect(!FileManager.default.fileExists(atPath: dir.appending(path: "DAL/logo-v1.png").path))
        // Files the index does not name are swept by the next run.
        let stray = dir.appending(path: "UAL/logo-v0.png")
        try Self.png().write(to: stray)
        _ = await service(t).asset("UAL", .logo)
        #expect(!FileManager.default.fileExists(atPath: stray.path))
        #expect(FileManager.default.fileExists(atPath: dir.appending(path: "UAL/logo-v1.png").path))
    }

    @Test func unwritableCacheDoesNotDownloadAgain() async throws {
        // The cache directory is a file: nothing can be written under it.
        let blocked = dir.appendingPathExtension("blocked")
        try Data("x".utf8).write(to: blocked)
        let t = await transport()
        let svc = SupabaseBrandAssetService(transport: t, cacheDir: blocked, clock: { [clock] in clock.now })
        let first = try #require(await svc.asset("UAL", .logo))
        #expect(await svc.asset("UAL", .logo) == first)
        #expect(await t.downloads == 1)
        #expect(await t.metaCalls == 1)
    }

    @Test func redirectOffTheProjectHostIsRefused() async throws {
        let project = URL(string: "https://proj.supabase.co")!
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RedirectStub.self]
        let downloader = BrandDownloader(projectURL: project, configuration: config, maxBytes: 64)
        RedirectStub.reset()
        // Same host redirect: followed.
        let same = try await downloader.download(URL(string: "https://proj.supabase.co/storage/v1/object/sign/a?to=same")!)
        #expect(same == Data("ok".utf8))
        // Off host: refused, the other host never asked.
        await #expect(throws: APIError.self) {
            try await downloader.download(URL(string: "https://proj.supabase.co/storage/v1/object/sign/a?to=evil")!)
        }
        #expect(!RedirectStub.hosts().contains("evil.example"))
        // A first URL off host, or http to an https project, never leaves.
        await #expect(throws: APIError.self) { try await downloader.download(URL(string: "https://evil.example/x")!) }
        await #expect(throws: APIError.self) { try await downloader.download(URL(string: "http://proj.supabase.co/x")!) }
        // Bigger than the cap while streaming: refused.
        await #expect(throws: APIError.self) {
            try await downloader.download(URL(string: "https://proj.supabase.co/storage/v1/object/sign/big")!)
        }
    }

    @Test func wordmarkFallsBackToTheName() {
        let ual = Airline(id: "UAL", iata: "UA", name: "United Airlines", colorPrimary: "#0033A0")
        #expect(AirlineWordmark.fallbackText(airline: ual, code: "UA") == "United Airlines")
        #expect(AirlineWordmark.fallbackText(airline: nil, code: "ZZ") == "ZZ")
        #expect(AirlineLogo.kinds(dark: false) == [.logo] && AirlineLogo.kinds(dark: true) == [.logoDark, .logo])
    }

    @Test func bundledFakesCoverTheFakeHistory() async {
        let fake = FakeBrandAssetService.bundled()
        for icao in FakeBrandAssetService.bundledAirlines {
            let logo = await fake.asset(icao, .logo)
            #expect(logo?.decodes == true, "\(icao)")
        }
        #expect(await FakeBrandAssetService().asset("UAL", .logo) == nil)
        #expect(await fake.asset("UAL", .logoDark) == nil)
        // Wide slots: every bundled airline has a wordmark; a symbol airline's logo is a different, smaller file.
        for icao in FakeBrandAssetService.bundledAirlines {
            let word = await fake.asset(icao, .wordmark)
            #expect(word?.decodes == true, "\(icao) wordmark")
            let logo = await fake.asset(icao, .logo)
            if FakeBrandAssetService.bundledSymbols.contains(icao) {
                #expect(logo?.data != word?.data, "\(icao) symbol is not the wordmark")
            } else {
                #expect(logo?.data == word?.data, "\(icao) has no symbol: logo is the wordmark")
            }
        }
        let ref = ReferenceData.bundled()
        for name in Set(FakeSeed.load("past_flights", as: [PastFlight].self).compactMap(\.airline)) {
            let icao = ref.airline(name)?.id
            #expect(icao.map(FakeBrandAssetService.bundledAirlines.contains) == true, "\(name)")
        }
    }
}

/// Answers for the redirect test: `?to=same` redirects on the project host, `?to=evil` to another host,
/// `/big` sends 1 KB with no length, anything else "ok". Records every host asked.
final class RedirectStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) private static var seen: [String] = []
    private static let lock = NSLock()
    static func reset() { lock.withLock { seen = [] } }
    static func hosts() -> [String] { lock.withLock { seen } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let client else { return }
        Self.lock.withLock { Self.seen.append(url.host() ?? "") }
        let query = url.query() ?? ""
        if query.contains("to=") {
            let target = query.contains("to=evil") ? "https://evil.example/stolen" : "https://proj.supabase.co/storage/v1/object/sign/b"
            let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": target])!
            client.urlProtocol(self, wasRedirectedTo: URLRequest(url: URL(string: target)!), redirectResponse: response)
            client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client.urlProtocolDidFinishLoading(self)
            return
        }
        let body = url.path().hasSuffix("/big") ? Data(repeating: 1, count: 1024) : Data("ok".utf8)
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!
        client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client.urlProtocol(self, didLoad: body)
        client.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
