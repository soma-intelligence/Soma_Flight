import Foundation

/// Side views that ship with the app (Resources/SideViews, written by Scripts/bundle_side_views.py from the
/// reviewed aircraft-art renders): one WebP per airline and type, nose left, margins already cut. They
/// answer `.sideView` before the wrapped service is asked; every other kind, and a pair not in the bundle,
/// goes to the wrapped service. When that service has no side view either, `fallbackKey` picks the next
/// best bundled picture (the parent airline's, then the type's plain one, then a sibling type), so a flight
/// never shows a drawing: see `fallbackKey`.
public struct BundledSideViews: BrandAssetService {
    private let base: any BrandAssetService
    private let catalog: Catalog

    /// The pairs ("UAL-B38M") and their version, read once from the bundle's index.
    struct Catalog: Sendable {
        var version: String
        var pairs: Set<String>
        /// `pairs` in order, for the fallbacks that take an airline's first picture.
        var sorted: [String] = []

        static let bundled: Catalog = {
            struct Index: Decodable { var version: String; var pairs: [String] }
            guard let url = url("index", "json"), let data = try? Data(contentsOf: url),
                  let index = try? JSONDecoder().decode(Index.self, from: data)
            else { return Catalog(version: "", pairs: []) }
            return Catalog(version: index.version, pairs: Set(index.pairs), sorted: index.pairs.sorted())
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
        return Self.fallback(icao, type: type).map { .found($0) } ?? answer
    }

    // MARK: - Fallback chain

    /// Each family's most common type, for a type the bundle has no picture of under any airline.
    static let familyType: [AircraftFamily: String] = [
        .a220: "BCS3", .a320: "A320", .a330: "A333", .a350: "A359", .a380: "A388", .b737: "B738",
        .b737max: "B38M", .b747: "B748", .b757: "B752", .b767: "B763", .b777: "B77W", .b787: "B789",
        .ejet: "E190", .crj: "CRJ9", .atr: "AT76", .other: "A320",
    ]

    /// The closest bundled type of the same family, for variants the bundle may lack.
    static let sibling: [String: String] = [
        "A19N": "A20N", "A318": "A319", "B37M": "B38M", "B3XM": "B39M", "A338": "A339", "E75L": "E175",
        "E75S": "E175", "A220": "BCS3", "B736": "B737", "B733": "B735", "B734": "B738", "B762": "B763",
        "B773": "B77W", "B778": "B77W", "B779": "B77W", "AT43": "AT72", "AT45": "AT72", "AT46": "AT76",
        "E135": "E145", "E35L": "E145", "F70": "F100", "MD83": "MD82", "MD88": "MD82", "MD90": "MD82",
        "B461": "B462", "B463": "B462", "B744": "B748", "B74S": "B748",
    ]

    /// The bundled picture to show for this airline (nil: none known) and type (nil or empty: unknown)
    /// when the exact pair is missing, best first:
    /// 1. the exact pair, then the same type under each airline whose livery the operator flies
    ///    (`AirlineParents`: Lufthansa City Airlines gives Lufthansa's);
    /// 2. the type's plain white view (`ZZZ-<TYPE>`);
    /// 3. the closest type of the same family (`sibling`, then the family's common type), in the airline's
    ///    colours first, else plain;
    /// 4. with no type at all, the airline's (or its parent's) first bundled type, else a plain A320.
    /// nil only when the bundle is empty.
    public static func fallbackKey(_ icao: String?, type: String?) -> String? {
        let pairs = Catalog.bundled.pairs
        let codes = (icao.map { AirlineParents.chain($0) } ?? []).filter { $0 != plainAirline } + [plainAirline]
        func first(_ type: String) -> String? {
            codes.lazy.map { key($0, type) }.first { pairs.contains($0) }
        }
        let t = (type ?? "").trimmingCharacters(in: .whitespaces).uppercased()
        if !t.isEmpty {
            if let hit = first(t) { return hit }
            var near: [String] = []
            if let s = sibling[t] { near.append(s) }
            if let family = ReferenceData.bundled().type(t)?.family, let f = familyType[family] { near.append(f) }
            for n in near { if let hit = first(n) { return hit } }
        }
        for code in codes.dropLast() {
            if let hit = Catalog.bundled.sorted.first(where: { $0.hasPrefix(code + "-") }) { return hit }
        }
        return first("A320") ?? Catalog.bundled.sorted.first
    }

    /// The same, by family, for a type the reference list does not know ("" or a code of our own).
    public static func fallbackKey(_ icao: String?, family: AircraftFamily) -> String? {
        fallbackKey(icao, type: familyType[family])
    }

    /// The asset of `fallbackKey`, nil when the bundle has none.
    public static func fallback(_ icao: String?, type: String?) -> BrandAsset? {
        fallbackKey(icao, type: type).flatMap(asset(key:))
    }

    /// A bundled side view by key ("DLH-A320").
    static func asset(key: String) -> BrandAsset? {
        let catalog = Catalog.bundled
        guard catalog.pairs.contains(key), let url = Catalog.url(key, "webp"),
              let data = try? Data(contentsOf: url) else { return nil }
        return BrandAsset(data: data, format: "webp", version: catalog.version)
    }
}
