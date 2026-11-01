import Foundation

/// Side views that ship with the app (Resources/SideViews, written by Scripts/bundle_side_views.py from the
/// reviewed aircraft-art renders): one WebP per airline and type, nose left, margins already cut. They
/// answer `.sideView` before the wrapped service is asked; every other kind, and a pair not in the bundle,
/// goes to the wrapped service. When that service has no side view either, the type's plain one answers
/// (`ZZZ-<TYPE>`: white, grey belly, no titles), so a known type never falls back to the vector drawing.
public struct BundledSideViews: BrandAssetService {
    private let base: any BrandAssetService
    private let catalog: Catalog

    /// The pairs ("UAL-B38M") and their version, read once from the bundle's index.
    struct Catalog: Sendable {
        var version: String
        var pairs: Set<String>

        static let bundled: Catalog = {
            struct Index: Decodable { var version: String; var pairs: [String] }
            guard let url = url("index", "json"), let data = try? Data(contentsOf: url),
                  let index = try? JSONDecoder().decode(Index.self, from: data)
            else { return Catalog(version: "", pairs: []) }
            return Catalog(version: index.version, pairs: Set(index.pairs))
        }()

        static func url(_ name: String, _ ext: String) -> URL? {
            Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "SideViews")
                ?? Bundle.module.url(forResource: name, withExtension: ext)
        }
    }

    public init(over base: any BrandAssetService) {
        self.base = base
        catalog = .bundled
    }

    /// The pairs in the bundle, "UAL-B38M".
    public static var pairs: Set<String> { Catalog.bundled.pairs }

    static func key(_ icao: String, _ type: String) -> String {
        "\(icao.trimmingCharacters(in: .whitespaces).uppercased())-\(type.trimmingCharacters(in: .whitespaces).uppercased())"
    }

    /// The bundled side view for this airline and type, nil when the bundle has none.
    func bundled(_ icao: String, type: String?) -> BrandAsset? {
        guard let type else { return nil }
        let key = Self.key(icao, type)
        guard catalog.pairs.contains(key), let url = Catalog.url(key, "webp"),
              let data = try? Data(contentsOf: url) else { return nil }
        return BrandAsset(data: data, format: "webp", version: catalog.version)
    }

    /// The airline code of the plain, unbranded side views ("ZZZ-A359"); ICAO's placeholder designator, no
    /// airline's.
    public static let plainAirline = "ZZZ"

    /// The plain side view of this type, nil when the bundle has none.
    func plain(type: String?) -> BrandAsset? { bundled(Self.plainAirline, type: type) }

    public func asset(_ icao: String, _ kind: BrandAssetKind, type: String?) async -> BrandAsset? {
        await lookup(icao, kind, type: type).asset
    }

    public func lookup(_ icao: String, _ kind: BrandAssetKind, type: String?) async -> BrandLookup {
        guard kind == .sideView else { return await base.lookup(icao, kind, type: type) }
        if let asset = bundled(icao, type: type) { return .found(asset) }
        let answer = await base.lookup(icao, kind, type: type)
        if case .found = answer { return answer }
        return plain(type: type).map { .found($0) } ?? answer
    }
}
