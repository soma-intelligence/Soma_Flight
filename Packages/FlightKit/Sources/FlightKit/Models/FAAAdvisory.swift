import Foundation

/// The FAA's live programs at a US airport, from `faa-status` (the FAA's public NAS status feed): ground
/// stops, ground delay programs, departure and arrival delays, a closure, deicing. Most serious first.
public struct AirportPrograms: Sendable, Hashable {
    public var airportIcao: String
    public var iata: String?
    /// True when the FAA did not answer and these are from an older read (at most 30 minutes).
    public var isStale: Bool
    /// When the feed was read.
    public var fetchedAt: Date
    public var programs: [AirportProgram]

    public init(airportIcao: String, iata: String?, isStale: Bool = false, fetchedAt: Date,
                programs: [AirportProgram]) {
        self.airportIcao = airportIcao; self.iata = iata; self.isStale = isStale
        self.fetchedAt = fetchedAt; self.programs = programs
    }
}

/// One FAA program at one airport.
public struct AirportProgram: Sendable, Hashable, Identifiable {
    /// Most serious first: the order `AirportProgram.sorted` keeps.
    public enum Kind: String, Sendable, Hashable, CaseIterable {
        case closure
        case groundStop = "ground_stop"
        case groundDelay = "ground_delay"
        case departureDelay = "departure_delay"
        case arrivalDelay = "arrival_delay"
        case deicing
    }

    public enum Trend: String, Sendable, Hashable { case increasing, decreasing, steady }

    /// Ground stops: how likely the FAA thinks it is to run past its end time.
    public enum Extension: String, Sendable, Hashable { case low, medium, high }

    /// The FAA's code for the airport (its IATA code at every airline airport).
    public var airport: String
    public var kind: Kind
    /// The cause in plain words ("low clouds"); nil when the FAA gave none.
    public var reason: String?
    /// The cause as the FAA wrote it ("WEATHER / LOW CEILINGS").
    public var reasonRaw: String?
    public var averageMinutes: Int?
    public var trend: Trend?
    public var extensionChance: Extension?
    public var startsAt: Date?
    /// The planned end; nil when open ended.
    public var endsAt: Date?
    public var updatedAt: Date?
    /// The FAA advisory that announced it.
    public var advisoryURL: URL?

    public var id: String { "\(kind.rawValue):\(airport):\(startsAt?.timeIntervalSince1970 ?? 0)" }

    public init(airport: String, kind: Kind, reason: String? = nil, reasonRaw: String? = nil,
                averageMinutes: Int? = nil, trend: Trend? = nil, extensionChance: Extension? = nil,
                startsAt: Date? = nil, endsAt: Date? = nil, updatedAt: Date? = nil, advisoryURL: URL? = nil) {
        self.airport = airport; self.kind = kind; self.reason = reason; self.reasonRaw = reasonRaw
        self.averageMinutes = averageMinutes; self.trend = trend; self.extensionChance = extensionChance
        self.startsAt = startsAt; self.endsAt = endsAt; self.updatedAt = updatedAt; self.advisoryURL = advisoryURL
    }

    /// How hard it hits: a closure or ground stop is major, the rest moderate.
    public var severity: Severity {
        switch kind {
        case .closure, .groundStop: .major
        default: .moderate
        }
    }

    /// Most serious first.
    public static func sorted(_ ps: [AirportProgram]) -> [AirportProgram] {
        let order = Kind.allCases
        return ps.sorted { order.firstIndex(of: $0.kind)! < order.firstIndex(of: $1.kind)! }
    }
}

/// The FAA advisories of both ends of one flight, as the flight sheet keeps them. Each part is nil until
/// it loads and stays nil when its call fails or there is nothing to give.
public struct FlightAdvisories: Sendable, Hashable {
    public var originPrograms: AirportPrograms?
    public var destinationPrograms: AirportPrograms?
    public var originNotams: NotamReport?
    public var destinationNotams: NotamReport?

    public init(originPrograms: AirportPrograms? = nil, destinationPrograms: AirportPrograms? = nil,
                originNotams: NotamReport? = nil, destinationNotams: NotamReport? = nil) {
        self.originPrograms = originPrograms; self.destinationPrograms = destinationPrograms
        self.originNotams = originNotams; self.destinationNotams = destinationNotams
    }

    /// Asks `service` for both airports at once; each failure leaves its own part nil.
    static func load(_ service: any FAAService, origin: String, destination: String) async -> FlightAdvisories {
        async let op = try? service.programs(airport: origin)
        async let dp = try? service.programs(airport: destination)
        async let on = try? service.notams(airport: origin)
        async let dn = try? service.notams(airport: destination)
        let (a, b, c, d) = await (op, dp, on, dn)
        return FlightAdvisories(originPrograms: a ?? nil, destinationPrograms: b ?? nil,
                                originNotams: c ?? nil, destinationNotams: d ?? nil)
    }
}

/// The NOTAMs of an airport a passenger can feel, decoded by `faa-notams`, most felt first. The app gets
/// none (nil) until the owner sets the FAA NOTAM key on the backend.
public struct NotamReport: Sendable, Hashable {
    public var airportIcao: String
    public var iata: String?
    public var isStale: Bool
    public var fetchedAt: Date
    public var notams: [Notam]

    public init(airportIcao: String, iata: String?, isStale: Bool = false, fetchedAt: Date, notams: [Notam]) {
        self.airportIcao = airportIcao; self.iata = iata; self.isStale = isStale
        self.fetchedAt = fetchedAt; self.notams = notams
    }
}

/// One notice in plain English, with the text as published.
public struct Notam: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable, Hashable {
        case airportClosed = "airport_closed"
        case runwayClosed = "runway_closed"
        case ilsOut = "ils_out"
        case construction
        case taxiwayClosed = "taxiway_closed"
        case obstacleLight = "obstacle_light"
    }

    /// The FAA's number ("10/101").
    public var number: String
    public var kind: Kind
    /// "Runway 10L/28R closed".
    public var title: String
    /// "For construction work."; nil when the notice says nothing more.
    public var detail: String?
    /// How much it matters to a passenger, 0 to 100 (the backend's ranking).
    public var relevance: Int
    /// The notice as published.
    public var raw: String
    public var startsAt: Date?
    /// nil when permanent.
    public var endsAt: Date?
    /// The end is the FAA's estimate.
    public var endsEstimated: Bool

    public var id: String { number.isEmpty ? raw : number }

    public init(number: String, kind: Kind, title: String, detail: String? = nil, relevance: Int, raw: String,
                startsAt: Date? = nil, endsAt: Date? = nil, endsEstimated: Bool = false) {
        self.number = number; self.kind = kind; self.title = title; self.detail = detail
        self.relevance = relevance; self.raw = raw; self.startsAt = startsAt; self.endsAt = endsAt
        self.endsEstimated = endsEstimated
    }

    /// A closed airport (not one closed to private flights only): relevance 100 on the backend's scale.
    public var closesAirport: Bool { kind == .airportClosed && relevance >= 100 }
    /// A whole runway closed (not in part).
    public var closesRunway: Bool { kind == .runwayClosed && relevance >= 80 }
}
