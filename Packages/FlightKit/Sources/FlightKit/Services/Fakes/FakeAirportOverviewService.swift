import Foundation

/// A full, believable afternoon for screenshot runs and tests, so the Airports screens can be judged with
/// every section filled: weather for every airport (a few bad ones), the FAA programs of `FakeFAAService`
/// (ground delay at SFO, departure delays at AUS, a ground stop at EWR), on-time and delay numbers, a
/// 24 hour delay trend, the day's traffic and the next seven days, and Runway Regulars with the two fake
/// friends. The numbers are made up but stable: the same airport gives the same answer at the same clock.
///
/// `live: false` answers like a backend without a board provider (`-fakeNoProvider`): weather and FAA
/// programs stay, every paid number says it needs a data plan.
public actor FakeAirportOverviewService: AirportOverviewService {
    public var nextError: APIError?
    private let now: Date
    private let live: Bool
    private let faa: FakeFAAService
    private let lookup: @Sendable (String) -> Airport?
    /// The seed Passport, so "You" on the podium counts the same flights as "Your History Here".
    private let past: [PastFlight]

    public init(now: Date? = nil, live: Bool = true, directory: AirportDirectory = .bundled()) {
        self.now = now ?? .now
        self.live = live
        faa = FakeFAAService(now: now)
        lookup = directory.lookup
        past = FakeSeed.load("past_flights", as: [PastFlight].self)
    }

    public func setNextError(_ error: APIError?) { nextError = error }

    private func check() throws(APIError) {
        if let e = nextError { nextError = nil; throw e }
    }

    // MARK: Weather

    /// Airports whose weather is part of the story; the rest get fair weather from their code.
    private static let weatherStories: [String: (FlightCategory, Int?, Double, Int, Int?, String?, String)] = [
        // category, ceiling ft, visibility sm, wind kt, gust kt, wx, condition
        // SFO, AUS and CDG match the airport card's seed METARs (Resources/Fakes/weather.json).
        "KSFO": (.VFR, nil, 10, 14, nil, nil, "Partly cloudy"),
        "KEWR": (.IFR, 900, 2, 18, 32, "TSRA", "Thunderstorm with rain"),
        "KAUS": (.VFR, 25000, 10, 12, 22, nil, "Mostly cloudy"),
        "KORD": (.VFR, 4500, 10, 22, 36, nil, "Mostly cloudy"),
        "EGLL": (.MVFR, 1800, 5, 14, nil, "-RA BR", "Light rain and mist"),
        "LFPG": (.IFR, 600, 1.55, 6, nil, "-DZ BR", "Light drizzle and mist"),
        "KDEN": (.VFR, nil, 10, 12, nil, nil, "Clear skies"),
        "OMDB": (.VFR, nil, 6, 8, nil, "HZ", "Haze"),
        "ZBAA": (.LIFR, 300, 0.5, 4, nil, "FG", "Fog"),
    ]

    private static let fairSkies = ["Clear skies", "A few clouds", "Partly cloudy", "Clear skies", "Mostly cloudy"]

    static func seed(_ code: String) -> Int {
        code.unicodeScalars.reduce(7) { ($0 &* 31 &+ Int($1.value)) & 0x7FFF_FFFF }
    }

    private func conditions(_ icao: String) -> AirportConditions {
        let s = Self.seed(icao)
        let observed = now.addingTimeInterval(-Double(8 + s % 40) * 60)
        if let (cat, ceiling, vis, wind, gust, wx, condition) = Self.weatherStories[icao] {
            return AirportConditions(category: cat, ceilingFt: ceiling, visibilitySm: vis, windDirDeg: (s % 36) * 10,
                                     windKt: wind, gustKt: gust, tempC: Double(4 + s % 22), wx: wx,
                                     condition: condition, summary: Self.sentence(condition, wind, gust),
                                     observedAt: observed)
        }
        let condition = Self.fairSkies[s % Self.fairSkies.count]
        let wind = 3 + s % 14
        return AirportConditions(category: .VFR, ceilingFt: condition == "Mostly cloudy" ? 6000 : nil,
                                 visibilitySm: 10, windDirDeg: (s % 36) * 10, windKt: wind, tempC: Double(6 + s % 24),
                                 condition: condition, summary: Self.sentence(condition, wind, nil), observedAt: observed)
    }

    /// The same words `airport-weather` uses (`_shared/metar_words.ts`).
    static func sentence(_ condition: String, _ wind: Int, _ gust: Int?) -> String {
        let words: String
        if let gust, gust >= 25 { words = "gusty winds" }
        else if wind <= 3 { words = "calm winds" }
        else if wind <= 10 { words = "light winds" }
        else if wind <= 20 { words = "a steady breeze" }
        else { words = "strong winds" }
        return "\(condition) with \(words)."
    }

    public func overviews(_ codes: [String]) async throws(APIError) -> [AirportOverview] {
        try check()
        var out: [AirportOverview] = []
        for code in codes {
            guard let a = lookup(code), !out.contains(where: { $0.icao == a.id }) else { continue }
            let programs = (try? await faa.programs(airport: a.id))?.programs
            out.append(AirportOverview(icao: a.id, iata: a.iata, weather: conditions(a.id), programs: programs))
        }
        return out
    }

    // MARK: Live numbers

    /// How rough each story airport's afternoon is: on-time share and average delay of departures.
    private static let boardStories: [String: (onTime: Int, delay: Int, canceled: Int)] = [
        "KSFO": (64, 11, 2), "KEWR": (31, 74, 9), "KAUS": (61, 29, 1), "KORD": (68, 22, 1),
        "EGLL": (71, 17, 0), "LFPG": (64, 24, 1), "ZBAA": (38, 63, 6), "KATL": (86, 7, 0),
    ]

    private func brief(_ icao: String, arrivals: Bool) -> AirportBrief {
        let s = Self.seed(icao + (arrivals ? "A" : "D"))
        let total = 60 + s % 240
        let story = Self.boardStories[icao]
        var onTimePct = story?.onTime ?? (80 + s % 17)
        var delay = story?.delay ?? (2 + s % 11)
        if arrivals { onTimePct = min(98, onTimePct + 6); delay = max(0, delay - 5) }
        let canceled = total * (story?.canceled ?? 0) / 100
        let onTime = total * onTimePct / 100
        return AirportBrief(total: total, onTime: onTime, delayed: max(0, total - onTime - canceled), canceled: canceled,
                            avgDelayMinutes: delay)
    }

    public func liveSummaries(_ codes: [String]) async throws(APIError) -> AirportLiveList {
        try check()
        guard live else { return AirportLiveList(available: false, airports: []) }
        return AirportLiveList(available: true, airports: codes.compactMap(lookup).map {
            AirportLiveSummary(icao: $0.id, departures: brief($0.id, arrivals: false), arrivals: brief($0.id, arrivals: true))
        })
    }

    /// A day of delays: calm in the morning, building through the afternoon, estimates for the hours ahead.
    private func trend(_ icao: String, peak: Int, arrivals: Bool) -> [AirportTrendHour] {
        let hourStart = Date(timeIntervalSince1970: (now.timeIntervalSince1970 / 3600).rounded(.down) * 3600)
        let s = Self.seed(icao + (arrivals ? "a" : "d"))
        return (-10...5).map { offset in
            let hour = hourStart.addingTimeInterval(Double(offset) * 3600)
            // Rises towards now, eases off after; a little noise from the airport's code.
            let shape = offset <= 0 ? Double(10 + offset) / 10 : max(0.15, 1 - Double(offset) * 0.2)
            let noise = Double((s >> (offset + 10)) % 7) - 3
            let delay = max(0, Int((Double(peak) * shape * shape + noise).rounded()))
            return AirportTrendHour(hour: hour, avgDelayMinutes: delay, flights: 8 + (s >> (offset + 10)) % 18,
                                    estimated: offset > 0)
        }
    }

    private func traffic(_ icao: String, days: Int) -> AirportTraffic {
        let s = Self.seed(icao)
        // SFO matches the airport card's seed board (156 departures today).
        let perDay = icao == "KSFO" ? 156 : 240 + s % 420
        let carriers = Self.carriers(for: lookup(icao)?.country ?? "US")
        var left = perDay * days
        let airlines = carriers.enumerated().map { i, op in
            let n = i == carriers.count - 1 ? left / 3 : left * (i == 0 ? 38 : 22) / 100
            left -= n
            return AirportTraffic.Airline(operator: op, flights: n)
        }.sorted { $0.flights > $1.flights }
        let hubs = Self.routes(for: icao)
        let routes = hubs.enumerated().map { i, dest in
            AirportTraffic.Route(icao: dest, flights: (34 - i * 5 + s % 4) * days)
        }
        return AirportTraffic(departures: perDay * days, airlines: 18 + s % 40 + (days > 1 ? 4 : 0),
                              airportsServed: 60 + s % 90 + (days > 1 ? 9 : 0), countriesServed: 8 + s % 30,
                              busiestAirlines: airlines, busiestRoutes: routes)
    }

    /// Big local carriers by country, ICAO codes (no marks are drawn: the app shows monograms).
    static func carriers(for country: String) -> [String] {
        switch country {
        case "US": ["UAL", "DAL", "AAL", "SWA", "ASA"]
        case "GB": ["BAW", "EZY", "VIR", "DLH", "AFR"]
        case "FR": ["AFR", "EZY", "TVF", "KLM", "DLH"]
        case "JP": ["ANA", "JAL", "SKY", "APJ", "UAL"]
        case "CA": ["ACA", "WJA", "POE", "UAL", "DAL"]
        default: ["UAE", "DLH", "AFR", "BAW", "KLM"]
        }
    }

    static func routes(for icao: String) -> [String] {
        let pool = ["KLAX", "KJFK", "KORD", "KDEN", "KSEA", "EGLL", "LFPG", "KATL", "KBOS", "RJTT", "KDFW", "KLAS"]
        let s = seed(icao)
        return (0..<5).map { pool[(s + $0 * 5) % pool.count] }.reduce(into: [String]()) { list, c in
            if c != icao, !list.contains(c) { list.append(c) }
        }
    }

    public func liveStats(_ code: String) async throws(APIError) -> AirportLiveStats? {
        try check()
        guard let a = lookup(code) else { throw .notFound }
        guard live else { return .needsPlan(a.id) }
        let dep = brief(a.id, arrivals: false), arr = brief(a.id, arrivals: true)
        let routes = Self.routes(for: a.id), carriers = Self.carriers(for: a.country)
        func perf(_ b: AirportBrief, arrivals: Bool) -> AirportPerformance {
            // The delayed and canceled flights spread over the busiest routes and airlines, worst first.
            let worstRoutes = routes.enumerated().map { i, icao in
                RouteDelay(icao: icao, delayed: max(1, b.delayed * (5 - i) / 15), canceled: i == 1 ? b.canceled / 2 : 0)
            }
            let worstAirlines = carriers.prefix(4).enumerated().map { i, op in
                AirlineDelay(operator: op, delayed: max(1, b.delayed * (4 - i) / 10), canceled: i == 0 ? b.canceled / 2 : 0)
            }
            return AirportPerformance(total: b.total, onTime: b.onTime, delayed: b.delayed, canceled: b.canceled,
                                      avgDelayMinutes: b.avgDelayMinutes,
                                      trend: trend(a.id, peak: b.avgDelayMinutes + 12, arrivals: arrivals),
                                      worstRoutes: worstRoutes, worstAirlines: Array(worstAirlines))
        }
        return AirportLiveStats(available: true, icao: a.id, fetchedAt: now.addingTimeInterval(-90), stale: false,
                                departures: perf(dep, arrivals: false), arrivals: perf(arr, arrivals: true),
                                today: traffic(a.id, days: 1), next7Days: traffic(a.id, days: 7))
    }

    // MARK: Runway Regulars

    public func regulars(_ code: String) async throws(APIError) -> [RunwayRegular] {
        try check()
        guard let a = lookup(code) else { return [] }
        let s = Self.seed(a.id)
        let mine = past.filter { $0.status != .canceled && ($0.originIcao == a.id || $0.destinationIcao == a.id) }.count
        let month = { (months: Int) -> Date in
            Calendar(identifier: .gregorian).date(byAdding: .month, value: -months, to: self.now) ?? self.now
        }
        return [
            RunwayRegular(userId: FakeFriendsService.maya, isMe: false, displayName: "Maya", emoji: "🌿",
                          visits: 9 + s % 20, lastVisit: month(2)),
            RunwayRegular(userId: UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!, isMe: true,
                          displayName: "Quentin", emoji: "✈️", visits: max(1, mine), lastVisit: month(1)),
            RunwayRegular(userId: FakeFriendsService.theo, isMe: false, displayName: "Theo Martin", emoji: nil,
                          visits: 2 + s % 4, lastVisit: month(11)),
        ].sorted { $0.visits > $1.visits }
    }
}
