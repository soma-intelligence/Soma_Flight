import Foundation

// The Airports list and the airport card's live layer. Two halves, kept apart on purpose:
// - free and real today: the METAR (`airport-weather`, aviationweather.gov) and the FAA's programs at US
//   airports, plus Runway Regulars from our own Passport data (`airport_regulars`);
// - paid: on-time, delay and traffic numbers from a board provider (`airport-stats`), which answers
//   `available: false` while the backend has none. The app then says so and never makes numbers up.

/// One airport's latest METAR, decoded by `airport-weather`.
public struct AirportConditions: Codable, Sendable, Hashable {
    public var category: FlightCategory
    public var ceilingFt: Int?
    public var visibilitySm: Double?
    public var windDirDeg: Int?
    public var windKt: Int?
    public var gustKt: Int?
    public var tempC: Double?
    /// Present weather groups ("-RA BR").
    public var wx: String?
    /// "Light rain", "Partly cloudy".
    public var condition: String
    /// "Partly cloudy with light winds."
    public var summary: String
    public var observedAt: Date
    public var metarRaw: String
    /// NOAA did not answer and this is an older read (at most an hour).
    public var stale: Bool

    public init(category: FlightCategory, ceilingFt: Int? = nil, visibilitySm: Double? = nil, windDirDeg: Int? = nil,
                windKt: Int? = nil, gustKt: Int? = nil, tempC: Double? = nil, wx: String? = nil, condition: String,
                summary: String, observedAt: Date, metarRaw: String = "", stale: Bool = false) {
        self.category = category; self.ceilingFt = ceilingFt; self.visibilitySm = visibilitySm
        self.windDirDeg = windDirDeg; self.windKt = windKt; self.gustKt = gustKt; self.tempC = tempC; self.wx = wx
        self.condition = condition; self.summary = summary; self.observedAt = observedAt; self.metarRaw = metarRaw
        self.stale = stale
    }

    /// What the weather does to the airport (the Rust core's reading of ceiling, visibility, wind and weather).
    public var impact: WeatherImpact {
        WeatherImpact.of(ceilingFt: ceilingFt, visibilitySm: visibilitySm, windKt: windKt, gustKt: gustKt, wx: wx ?? "")
    }
}

/// The free half of one airport: its weather and, at US airports, the FAA's live programs.
public struct AirportOverview: Sendable, Hashable, Identifiable {
    public var icao: String
    public var iata: String?
    /// Nil when the airport has no recent METAR.
    public var weather: AirportConditions?
    /// The FAA's programs, most serious first; nil outside the US (or when the FAA feed is down).
    public var programs: [AirportProgram]?

    public var id: String { icao }

    public init(icao: String, iata: String? = nil, weather: AirportConditions? = nil, programs: [AirportProgram]? = nil) {
        self.icao = icao; self.iata = iata; self.weather = weather; self.programs = programs
    }
}

/// On time, delayed 15 minutes or more and canceled for one direction: the list's three columns.
public struct AirportBrief: Codable, Sendable, Hashable {
    public var total: Int
    public var onTime: Int
    public var delayed: Int
    public var canceled: Int
    public var avgDelayMinutes: Int

    public init(total: Int, onTime: Int, delayed: Int, canceled: Int, avgDelayMinutes: Int) {
        self.total = total; self.onTime = onTime; self.delayed = delayed; self.canceled = canceled
        self.avgDelayMinutes = avgDelayMinutes
    }

    /// Whole percent of the flights counted; nil with none.
    public func percent(_ n: Int) -> Int? {
        total > 0 ? Int((Double(n) / Double(total) * 100).rounded()) : nil
    }

    public var onTimePercent: Int? { percent(onTime) }
    public var canceledPercent: Int? { percent(canceled) }
}

/// One hour of a delay trend. `estimated` when nothing in it has flown yet.
public struct AirportTrendHour: Codable, Sendable, Hashable, Identifiable {
    public var hour: Date
    public var avgDelayMinutes: Int
    public var flights: Int
    public var estimated: Bool

    public var id: Date { hour }

    public init(hour: Date, avgDelayMinutes: Int, flights: Int, estimated: Bool) {
        self.hour = hour; self.avgDelayMinutes = avgDelayMinutes; self.flights = flights; self.estimated = estimated
    }
}

/// One direction of the airport card's live numbers.
public struct AirportPerformance: Codable, Sendable, Hashable {
    public var total: Int
    public var onTime: Int
    public var delayed: Int
    public var canceled: Int
    public var avgDelayMinutes: Int
    public var trend: [AirportTrendHour]
    /// Most delayed and canceled flights by route and by airline, worst first.
    public var worstRoutes: [RouteDelay]
    public var worstAirlines: [AirlineDelay]

    public init(total: Int, onTime: Int, delayed: Int, canceled: Int, avgDelayMinutes: Int, trend: [AirportTrendHour],
                worstRoutes: [RouteDelay] = [], worstAirlines: [AirlineDelay] = []) {
        self.total = total; self.onTime = onTime; self.delayed = delayed; self.canceled = canceled
        self.avgDelayMinutes = avgDelayMinutes; self.trend = trend
        self.worstRoutes = worstRoutes; self.worstAirlines = worstAirlines
    }

    public var brief: AirportBrief {
        AirportBrief(total: total, onTime: onTime, delayed: delayed, canceled: canceled, avgDelayMinutes: avgDelayMinutes)
    }

    /// The same numbers in the board's shape, so the card's performance and daily sections can show them
    /// when the provider's summary is all there is (no hourly buckets: the trend chart reads `trend`).
    public var delayStats: DelayStats {
        let severity: Severity = canceled * 10 >= max(total, 1) ? .major
            : avgDelayMinutes >= AirportStatus.majorDelay ? .major
            : avgDelayMinutes >= AirportStatus.minorDelay ? .moderate : .normal
        return DelayStats(total: total, onTime: onTime, delayed15: delayed, canceled: canceled,
                          avgDelayMinutes: Double(avgDelayMinutes), perHour: [], worstRoutes: worstRoutes,
                          worstAirlines: worstAirlines, severity: severity)
    }
}

/// An airport's traffic over a period: what leaves it, who flies it, where to.
public struct AirportTraffic: Codable, Sendable, Hashable {
    public struct Airline: Codable, Sendable, Hashable {
        public var `operator`: String
        public var flights: Int
        public init(operator: String, flights: Int) { self.operator = `operator`; self.flights = flights }
    }

    public struct Route: Codable, Sendable, Hashable {
        public var icao: String
        public var flights: Int
        public init(icao: String, flights: Int) { self.icao = icao; self.flights = flights }
    }

    public var departures: Int
    public var airlines: Int
    public var airportsServed: Int
    public var countriesServed: Int
    public var busiestAirlines: [Airline]
    public var busiestRoutes: [Route]

    public init(departures: Int, airlines: Int, airportsServed: Int, countriesServed: Int,
                busiestAirlines: [Airline], busiestRoutes: [Route]) {
        self.departures = departures; self.airlines = airlines; self.airportsServed = airportsServed
        self.countriesServed = countriesServed; self.busiestAirlines = busiestAirlines; self.busiestRoutes = busiestRoutes
    }
}

/// The airport card's paid layer (`airport-stats`). `available` false: the backend has no board provider.
public struct AirportLiveStats: Codable, Sendable, Hashable {
    public var available: Bool
    public var icao: String
    public var fetchedAt: Date?
    public var stale: Bool
    public var departures: AirportPerformance?
    public var arrivals: AirportPerformance?
    public var today: AirportTraffic?
    /// Needs a schedules feed: nil until a provider adapter gives one.
    public var next7Days: AirportTraffic?

    public init(available: Bool, icao: String, fetchedAt: Date? = nil, stale: Bool = false,
                departures: AirportPerformance? = nil, arrivals: AirportPerformance? = nil,
                today: AirportTraffic? = nil, next7Days: AirportTraffic? = nil) {
        self.available = available; self.icao = icao; self.fetchedAt = fetchedAt; self.stale = stale
        self.departures = departures; self.arrivals = arrivals; self.today = today; self.next7Days = next7Days
    }

    /// What the card shows with no board provider.
    public static func needsPlan(_ icao: String) -> AirportLiveStats { AirportLiveStats(available: false, icao: icao) }

    private enum CodingKeys: String, CodingKey {
        case available, icao, fetchedAt, stale, departures, arrivals, today
        case next7Days = "next7Days"
    }
}

/// One airport's line in the Airports list (`airport-stats?airports=`).
public struct AirportLiveSummary: Codable, Sendable, Hashable, Identifiable {
    public var icao: String
    public var departures: AirportBrief?
    public var arrivals: AirportBrief?
    public var stale: Bool

    public var id: String { icao }

    public init(icao: String, departures: AirportBrief?, arrivals: AirportBrief?, stale: Bool = false) {
        self.icao = icao; self.departures = departures; self.arrivals = arrivals; self.stale = stale
    }
}

/// The list's paid layer: `available` false while the backend has no board provider.
public struct AirportLiveList: Sendable, Hashable {
    public var available: Bool
    public var airports: [AirportLiveSummary]

    public init(available: Bool, airports: [AirportLiveSummary]) {
        self.available = available; self.airports = airports
    }
}

/// Someone who keeps flying through an airport: the user or a friend who shares their Passport.
public struct RunwayRegular: Sendable, Hashable, Identifiable {
    public var userId: UUID
    public var isMe: Bool
    public var displayName: String?
    public var emoji: String?
    public var visits: Int
    /// The month of the latest visit (the server gives no finer date).
    public var lastVisit: Date?

    public var id: UUID { userId }

    public init(userId: UUID, isMe: Bool, displayName: String?, emoji: String?, visits: Int, lastVisit: Date?) {
        self.userId = userId; self.isMe = isMe; self.displayName = displayName; self.emoji = emoji
        self.visits = visits; self.lastVisit = lastVisit
    }

    /// "You" for the user, the friend's name otherwise.
    public var name: String {
        if isMe { return "You" }
        let n = displayName?.trimmingCharacters(in: .whitespaces) ?? ""
        return n.isEmpty ? "Friend" : n
    }
}

// MARK: - Status

/// How an airport is doing, for its dot on the globe and its section in the list.
public enum AirportStatusLevel: Int, Sendable, Hashable, Comparable, Codable {
    case normal, minor, major
    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

/// An airport's level and the line under its name ("Ground delay program, about 47 min").
public struct AirportStatus: Sendable, Hashable {
    public var level: AirportStatusLevel
    /// Nil on a normal day with nothing to say.
    public var line: String?

    public init(level: AirportStatusLevel, line: String?) { self.level = level; self.line = line }

    public static let normal = AirportStatus(level: .normal, line: nil)

    /// Average delay at which a direction is a minor issue, and a major one.
    public static let minorDelay = 15
    public static let majorDelay = 45
    /// On-time share under which a direction is a minor issue, and a major one.
    public static let minorOnTime = 75
    public static let majorOnTime = 50

    /// The worst of what is known: the FAA's programs, the weather, the notice and forecast reading, and the live numbers when a board
    /// provider gives them. With none of them the airport reads as normal: no data is not a problem.
    public static func of(_ overview: AirportOverview?, live: AirportLiveSummary? = nil,
                          assessment: AirportAssessment? = nil) -> AirportStatus {
        var found: [AirportStatus] = []
        for p in overview?.programs ?? [] { found.append(program(p)) }
        if let w = overview?.weather { found.append(weather(w)) }
        // What notices and the forecast add (and, outside the US, all there is): after the FAA and the weather
        // now, before the numbers.
        if let a = assessment, a.level > .normal, let line = a.summary { found.append(.init(level: a.level, line: line)) }
        for (b, word) in [(live?.departures, "Departures"), (live?.arrivals, "Arrivals")] {
            if let b { found.append(board(b, word)) }
        }
        // The first of the worst wins: programs before weather before numbers.
        guard let worst = found.map(\.level).max(), worst > .normal else { return .normal }
        return found.first { $0.level == worst } ?? .normal
    }

    static func program(_ p: AirportProgram) -> AirportStatus {
        let avg = p.averageMinutes.map { ", about \(Format.minutes($0))" } ?? ""
        switch p.kind {
        case .closure: return .init(level: .major, line: "Airport closed")
        case .groundStop: return .init(level: .major, line: "Ground stop")
        case .groundDelay:
            return .init(level: (p.averageMinutes ?? 0) >= 60 ? .major : .minor, line: "Ground delay program\(avg)")
        case .departureDelay:
            return .init(level: (p.averageMinutes ?? 0) >= majorDelay ? .major : .minor, line: "Departure delays\(avg)")
        case .arrivalDelay:
            return .init(level: (p.averageMinutes ?? 0) >= majorDelay ? .major : .minor, line: "Arrival delays\(avg)")
        case .deicing: return .init(level: .minor, line: "Deicing")
        }
    }

    static func weather(_ w: AirportConditions) -> AirportStatus {
        let impact = w.impact
        let level: AirportStatusLevel = switch impact.level {
        case .severe: .major
        case .moderate: .minor
        case .minor, .none: .normal
        }
        guard level > .normal else { return .normal }
        let hazard = impact.hazards.first?.label ?? w.condition.lowercased()
        return .init(level: level, line: "\(hazard.prefix(1).uppercased())\(hazard.dropFirst()) (\(w.category.rawValue))")
    }

    static func board(_ b: AirportBrief, _ word: String) -> AirportStatus {
        guard b.total >= 5, let onTime = b.onTimePercent else { return .normal }
        if b.avgDelayMinutes >= majorDelay || onTime < majorOnTime || (b.canceledPercent ?? 0) >= 10 {
            return .init(level: .major, line: "\(word) running \(Format.minutes(b.avgDelayMinutes)) late")
        }
        if b.avgDelayMinutes >= minorDelay || onTime < minorOnTime {
            return .init(level: .minor, line: "\(word) running \(Format.minutes(b.avgDelayMinutes)) late")
        }
        return .normal
    }
}
