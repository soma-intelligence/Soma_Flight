import Foundation

/// The Wikimedia Commons logo library that ships with the app (Resources/Logos, written by
/// Scripts/logos/bundle_logos.py from assets/logos/commons): every airline's wordmark and, when it has one,
/// its symbol, 192 px lossless WebP. Every file is credited in Settings > Acknowledgements.
///
/// The wrapped service answers first, so the backend (and a licensed provider behind it) keeps the last
/// word. When it has nothing (`.missing`) or cannot answer (`.unavailable`: offline, backend down), the
/// bundled mark answers `.logo` (the symbol, else the wordmark, as the backend serves it) and `.wordmark`.
/// Every other kind, and an airline outside the library, gets the wrapped service's answer unchanged.
public struct BundledLogos: BrandAssetService {
    private let base: any BrandAssetService
    private let catalog: Catalog

    /// The airlines in the bundle and the library's version, read once from the bundle's index.
    struct Catalog: Sendable {
        var version: String
        var wordmarks: Set<String>
        var symbols: Set<String>

        static let bundled: Catalog = {
            struct Index: Decodable { var version: String; var wordmarks: [String]; var symbols: [String] }
            guard let url = url("commons-logos", "json"), let data = try? Data(contentsOf: url),
                  let index = try? JSONDecoder().decode(Index.self, from: data)
            else { return Catalog(version: "", wordmarks: [], symbols: []) }
            return Catalog(version: index.version, wordmarks: Set(index.wordmarks), symbols: Set(index.symbols))
        }()

        static func url(_ name: String, _ ext: String) -> URL? {
            Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Logos")
                ?? Bundle.module.url(forResource: name, withExtension: ext)
        }
    }

    public init(over base: any BrandAssetService) {
        self.base = base
        catalog = .bundled
    }

    /// The airlines with a bundled wordmark, and those with a bundled symbol (ICAO codes).
    public static var wordmarks: Set<String> { Catalog.bundled.wordmarks }
    public static var symbols: Set<String> { Catalog.bundled.symbols }

    /// The bundled mark for this airline and kind, nil when the bundle has none.
    func bundled(_ icao: String, _ kind: BrandAssetKind) -> BrandAsset? {
        let key = icao.trimmingCharacters(in: .whitespaces).uppercased()
        let file: String
        switch kind {
        case .logo where catalog.symbols.contains(key): file = "commons-symbol-\(key)"
        case .logo, .wordmark:
            guard catalog.wordmarks.contains(key) else { return nil }
            file = "commons-wordmark-\(key)"
        default: return nil
        }
        guard let url = Catalog.url(file, "webp"), let data = try? Data(contentsOf: url) else { return nil }
        let suffix = file.hasPrefix("commons-symbol") ? "symbol" : "wordmark"
        return BrandAsset(data: data, format: "webp", version: "\(catalog.version)-\(suffix)")
    }

    public func asset(_ icao: String, _ kind: BrandAssetKind, type: String?) async -> BrandAsset? {
        await lookup(icao, kind, type: type).asset
    }

    public func lookup(_ icao: String, _ kind: BrandAssetKind, type: String?) async -> BrandLookup {
        let answer = await base.lookup(icao, kind, type: type)
        if case .found = answer { return answer }
        return bundled(icao, kind).map { .found($0) } ?? answer
    }
}
