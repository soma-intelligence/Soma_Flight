import CoreLocation
import Foundation
import Synchronization

/// What the plane is flying over, at the "over the North Atlantic, over Greenland, over Ireland" level.
public struct OverflownRegion: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        /// Land in a country (ISO 3166-1 alpha-2).
        case country(String)
        /// Land with no country to name (Antarctica).
        case land
        /// A sea or an ocean from `sea_regions.json`.
        case sea
    }

    public var kind: Kind
    /// The name as it reads after "over": "the North Atlantic", "Ireland", "the United States".
    public var name: String

    public init(kind: Kind, name: String) { self.kind = kind; self.name = name }

    /// "over the North Atlantic".
    public var phrase: String { "over \(name)" }
    /// "Over the North Atlantic".
    public var line: String { "Over \(name)" }
    public var isSea: Bool { kind == .sea }
}

/// Names the region under a point, all from bundled tables, offline:
/// 1. land or sea from `world_land.json` (Natural Earth 1:110m land, public domain);
/// 2. on land, the country of the nearest airport in `airports.tsv`, named from `countries.json` (the land
///    outline carries no country codes; near a border the nearest airport can sit across it);
///    south of 60 S, Antarctica;
/// 3. at sea, the first outline of `sea_regions.json` holding the point (small seas listed before oceans).
public struct RegionNamer: Sendable {
    struct Ring: Sendable {
        var points: [(lon: Double, lat: Double)]
        var minLon, maxLon, minLat, maxLat: Double

        init(flat: [Double]) {
            points = stride(from: 0, to: flat.count - 1, by: 2).map { (flat[$0], flat[$0 + 1]) }
            minLon = points.map(\.lon).min() ?? 0; maxLon = points.map(\.lon).max() ?? 0
            minLat = points.map(\.lat).min() ?? 0; maxLat = points.map(\.lat).max() ?? 0
        }

        /// Even-odd ray test in plain (longitude, latitude).
        func contains(lon: Double, lat: Double) -> Bool {
            guard lon >= minLon, lon <= maxLon, lat >= minLat, lat <= maxLat, points.count >= 3 else { return false }
            var inside = false
            var j = points.count - 1
            for i in 0..<points.count {
                let a = points[i], b = points[j]
                if (a.lat > lat) != (b.lat > lat),
                   lon < (b.lon - a.lon) * (lat - a.lat) / (b.lat - a.lat) + a.lon {
                    inside.toggle()
                }
                j = i
            }
            return inside
        }

        /// Also tries the longitude a turn east and west, for outlines drawn past 180.
        func containsWrapped(lon: Double, lat: Double) -> Bool {
            contains(lon: lon, lat: lat) || contains(lon: lon + 360, lat: lat) || contains(lon: lon - 360, lat: lat)
        }
    }

    struct Sea: Sendable {
        var name: String
        var ring: Ring
    }

    struct Place: Sendable {
        var lat: Double, lon: Double, country: String
    }

    let land: [Ring]
    let seas: [Sea]
    let places: [Place]
    let countryName: @Sendable (String) -> String?
    /// Answers already worked out, so a view that asks again on every redraw does not rescan the tables.
    let memo = Memo()

    init(land: [Ring], seas: [Sea], places: [Place], countryName: @escaping @Sendable (String) -> String?) {
        self.land = land; self.seas = seas; self.places = places; self.countryName = countryName
    }

    /// The last answers by point, to about 1 km (0.01 degree), dropped all at once when full.
    final class Memo: Sendable {
        struct Key: Hashable { var lat: Int, lon: Int }
        static let limit = 256
        private let store = Mutex<[Key: OverflownRegion?]>([:])

        static func key(_ c: CLLocationCoordinate2D) -> Key {
            Key(lat: Int((c.latitude * 100).rounded()), lon: Int((normalizedLongitude(c.longitude) * 100).rounded()))
        }

        func value(_ key: Key, compute: () -> OverflownRegion?) -> OverflownRegion? {
            if let hit = store.withLock({ $0[key] }) { return hit }
            let fresh = compute()
            store.withLock {
                if $0.count >= Self.limit { $0.removeAll(keepingCapacity: true) }
                $0[key] = .some(fresh)
            }
            return fresh
        }

        var count: Int { store.withLock { $0.count } }
    }

    /// The bundled tables, read once.
    public static let bundled: RegionNamer = {
        let reference = ReferenceData.bundled()
        let places = AirportDirectory.bundled().all.map { Place(lat: $0.lat, lon: $0.lon, country: $0.country) }
        return RegionNamer(land: readLand(), seas: readSeas(), places: places,
                           countryName: { reference.country($0)?.name })
    }()

    /// The region under `c`, nil when no table names it. Kept per point (`Memo`), so asking again is cheap.
    public func region(at c: CLLocationCoordinate2D) -> OverflownRegion? {
        memo.value(Memo.key(c)) { lookUp(c) }
    }

    func lookUp(_ c: CLLocationCoordinate2D) -> OverflownRegion? {
        let lon = normalizedLongitude(c.longitude), lat = c.latitude
        if isLand(c) {
            if lat < -60 { return OverflownRegion(kind: .land, name: "Antarctica") }
            guard let iso = nearestCountry(lat: lat, lon: lon), let name = countryName(iso) else { return nil }
            return OverflownRegion(kind: .country(iso), name: Self.withArticle(name))
        }
        guard let sea = seas.first(where: { $0.ring.containsWrapped(lon: lon, lat: lat) }) else { return nil }
        return OverflownRegion(kind: .sea, name: sea.name)
    }

    /// True on land, from the 1:110m outline (small islands are sea at this scale).
    public func isLand(_ c: CLLocationCoordinate2D) -> Bool {
        let lon = normalizedLongitude(c.longitude), lat = c.latitude
        // Natural Earth closes Antarctica along the edge of the map: everything that far south is land.
        if lat <= -85 { return true }
        return land.contains { $0.contains(lon: lon, lat: lat) }
    }

    func nearestCountry(lat: Double, lon: Double) -> String? {
        let p = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        var best: (Double, String)?
        for place in places where !place.country.isEmpty {
            let d = RouteEstimator.angle(p, CLLocationCoordinate2D(latitude: place.lat, longitude: place.lon))
            if best == nil || d < best!.0 { best = (d, place.country) }
        }
        return best?.1
    }

    /// "the United States", "the Netherlands", "Ireland".
    static func withArticle(_ name: String) -> String {
        let plural: Set<String> = ["Bahamas", "Gambia", "Comoros", "Maldives", "Netherlands", "Caribbean Netherlands",
                                   "Philippines", "Seychelles", "DR Congo", "Republic of the Congo"]
        if plural.contains(name) || name.hasPrefix("United ") || name.hasSuffix(" Islands") || name.hasSuffix(" Republic") {
            return "the \(name)"
        }
        return name
    }

    // MARK: Tables

    private static func url(_ name: String) -> URL? {
        Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Reference")
            ?? Bundle.module.url(forResource: name, withExtension: "json")
    }

    static func readLand() -> [Ring] {
        struct File: Decodable { var rings: [[Double]] }
        guard let url = url("world_land"), let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data) else { return [] }
        return file.rings.map(Ring.init(flat:))
    }

    static func readSeas() -> [Sea] {
        struct File: Decodable {
            struct Region: Decodable { var name: String; var ring: [Double] }
            var regions: [Region]
        }
        guard let url = url("sea_regions"), let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data) else { return [] }
        return file.regions.map { Sea(name: $0.name, ring: Ring(flat: $0.ring)) }
    }
}
