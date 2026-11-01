import Foundation
import Observation

/// Favourite airports, kept on this device only (UserDefaults). There is no favourites table in Supabase
/// yet, so they do not follow the account to another device (docs/airports.md).
@MainActor @Observable
public final class AirportFavorites {
    public private(set) var codes: [String]
    @ObservationIgnored private let defaults: UserDefaults?
    static let key = "favoriteAirports"

    /// - Parameter defaults: where they persist; nil keeps them in memory (fakes, tests), starting from `seed`.
    public init(defaults: UserDefaults? = .standard, seed: [String] = []) {
        self.defaults = defaults
        codes = defaults?.stringArray(forKey: Self.key) ?? seed
    }

    public func contains(_ icao: String) -> Bool { codes.contains(icao) }

    public func toggle(_ icao: String) {
        if let i = codes.firstIndex(of: icao) { codes.remove(at: i) } else { codes.append(icao) }
        defaults?.set(codes, forKey: Self.key)
    }
}

/// The groups of the list's filter pills.
public enum AirportRegionFilter: String, CaseIterable, Sendable, Hashable {
    case all, northAmerica, europe, asia, middleEast, latinAmerica, oceania, africa

    public var title: String {
        switch self {
        case .all: "All"
        case .northAmerica: "North America"
        case .europe: "Europe"
        case .asia: "Asia"
        case .middleEast: "Middle East"
        case .latinAmerica: "Latin America"
        case .oceania: "Oceania"
        case .africa: "Africa"
        }
    }

    public func contains(_ region: WorldRegion?) -> Bool {
        guard let region else { return self == .all }
        switch self {
        case .all: return true
        case .northAmerica: return region == .northAmerica
        case .europe: return region == .europe
        case .asia: return region == .asia
        case .middleEast: return region == .middleEast
        case .latinAmerica: return [.centralAmerica, .southAmerica, .caribbean].contains(region)
        case .oceania: return region == .oceania
        case .africa: return region == .africa
        }
    }
}

/// When the list looks: only now for the moment; later and the whole day come with the schedules feed.
public enum AirportTimeframe: String, CaseIterable, Sendable, Hashable {
    case now
    public var title: String { "Now" }
}

/// One airport in the list.
public struct AirportListRow: Sendable, Hashable, Identifiable {
    public var airport: Airport
    public var region: WorldRegion?
    public var status: AirportStatus
    public var overview: AirportOverview?
    public var live: AirportLiveSummary?
    public var isFavorite: Bool
    /// An airport of one of the user's flights today.
    public var isOnTrip: Bool

    public var id: String { airport.id }
}

/// The Airports list: the user's airports and a set of large hubs around the world, each with its status
/// (FAA programs, weather and, with a board provider, the on-time numbers), grouped by how they are doing.
@MainActor @Observable
public final class AirportsListStore {
    public var region: AirportRegionFilter = .all
    public var timeframe: AirportTimeframe = .now
    public private(set) var overviews: [String: AirportOverview] = [:]
    public private(set) var live: [String: AirportLiveSummary] = [:]
    /// False once the backend said it has no board provider: the columns then say so instead of numbers.
    public private(set) var liveAvailable = true
    public private(set) var loadedAt: Date?
    public private(set) var isLoading = false
    public private(set) var error: APIError?

    @ObservationIgnored private let service: any AirportOverviewService
    @ObservationIgnored private let lookup: (String) -> Airport?
    @ObservationIgnored private let reference: ReferenceData
    public let favorites: AirportFavorites
    /// The airports of the user's active flights (ICAO), read at each load and each redraw.
    @ObservationIgnored public var tripAirports: () -> [String]

    public init(service: any AirportOverviewService, lookup: @escaping (String) -> Airport?,
                reference: ReferenceData = .bundled(), favorites: AirportFavorites,
                tripAirports: @escaping () -> [String] = { [] }) {
        self.service = service; self.lookup = lookup; self.reference = reference; self.favorites = favorites
        self.tripAirports = tripAirports
    }

    /// Large airports across the world regions, the list's base.
    public static let hubs = [
        // North America
        "KATL", "KLAX", "KORD", "KDFW", "KDEN", "KJFK", "KSFO", "KSEA", "KLAS", "KMCO", "KEWR", "KMIA", "KBOS",
        "KPHX", "KIAH", "CYYZ", "CYVR",
        // Europe
        "EGLL", "LFPG", "EHAM", "EDDF", "LEMD", "LIRF", "LSZH", "EIDW", "LTFM",
        // Asia
        "RJTT", "RKSI", "VHHH", "WSSS", "ZBAA", "VTBS", "VIDP",
        // Middle East
        "OMDB", "OTHH",
        // Latin America
        "MMMX", "SBGR", "SCEL", "SKBO",
        // Oceania, Africa
        "YSSY", "NZAA", "FAOR", "HECA",
    ]

    /// Every code the list shows: the user's first (favourites, then trips), then the hubs.
    public var codes: [String] {
        var seen: Set<String> = []
        return (favorites.codes + tripAirports() + Self.hubs).compactMap { lookup($0)?.id }
            .filter { seen.insert($0).inserted }
    }

    public func load() async {
        isLoading = true
        defer { isLoading = false }
        let codes = codes
        var failure: APIError?
        do {
            let found = try await service.overviews(codes)
            overviews = Dictionary(found.map { ($0.icao, $0) }, uniquingKeysWith: { a, _ in a })
        } catch { failure = error }
        do {
            let list = try await service.liveSummaries(codes)
            liveAvailable = list.available
            live = Dictionary(list.airports.map { ($0.icao, $0) }, uniquingKeysWith: { a, _ in a })
        } catch { if failure == nil { failure = error } }
        error = failure
        loadedAt = .now
    }

    // MARK: Rows

    public var rows: [AirportListRow] {
        let favs = Set(favorites.codes), trips = Set(tripAirports().compactMap { lookup($0)?.id })
        return codes.compactMap { code in
            guard let a = lookup(code) else { return nil }
            let o = overviews[a.id], l = live[a.id]
            return AirportListRow(airport: a, region: reference.country(a.country)?.region,
                                  status: AirportStatus.of(o, live: l), overview: o, live: l,
                                  isFavorite: favs.contains(a.id), isOnTrip: trips.contains(a.id))
        }
    }

    /// The rows of the region on show.
    public var filtered: [AirportListRow] { rows.filter { region.contains($0.region) } }

    public struct Section: Identifiable, Sendable {
        public enum Kind: Sendable { case yours, major, minor, normal }
        public var kind: Kind
        public var title: String
        public var subtitle: String?
        public var rows: [AirportListRow]
        public var id: String { title }
    }

    /// The user's airports first, then the rest by how they are doing, worst first.
    public var sections: [Section] {
        let all = filtered
        let yours = all.filter { $0.isFavorite || $0.isOnTrip }
        let rest = all.filter { !($0.isFavorite || $0.isOnTrip) }
        var out: [Section] = []
        if !yours.isEmpty {
            out.append(Section(kind: .yours, title: "Your Airports", subtitle: "Favorites and today's trips",
                               rows: yours.sorted { $0.status.level > $1.status.level }))
        }
        let groups: [(Section.Kind, String, AirportStatusLevel)] = [
            (.major, "Major Disruption", .major), (.minor, "Some Delays", .minor), (.normal, "Running Normally", .normal),
        ]
        for (kind, title, level) in groups {
            let rows = rest.filter { $0.status.level == level }
            if !rows.isEmpty { out.append(Section(kind: kind, title: title, subtitle: nil, rows: rows)) }
        }
        return out
    }

    /// The globe's dots while the list is open: the airports of the region on show, coloured by status.
    public var globe: GlobeContent {
        let rows = filtered
        return GlobeContent(airports: rows.map(\.airport),
                            status: Dictionary(rows.map { ($0.airport.id, $0.status.level) }, uniquingKeysWith: { a, _ in a }))
    }
}
