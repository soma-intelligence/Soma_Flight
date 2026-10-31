import Foundation

/// FAA advisories for an airport: the live programs (ground stops, ground delay programs, delays,
/// closures) and the decoded NOTAMs. Live builds use `SupabaseFAAService` (edge functions `faa-status`
/// and `faa-notams`, free sources); screenshot runs (`-useFakes`) use `FakeFAAService`.
public protocol FAAService: Sendable {
    /// The programs at `airport` (IATA or ICAO); nil outside the US, where the FAA has none to give.
    func programs(airport: String) async throws(APIError) -> AirportPrograms?
    /// The notices at `airport`; nil while the backend has no FAA NOTAM key (the app then hides them).
    func notams(airport: String) async throws(APIError) -> NotamReport?
}

/// Nothing anywhere, and no network call: the default for stores built without a service.
public struct UnavailableFAAService: FAAService {
    public init() {}
    public func programs(airport: String) async throws(APIError) -> AirportPrograms? { nil }
    public func notams(airport: String) async throws(APIError) -> NotamReport? { nil }
}

/// A believable bad afternoon for screenshot runs and tests, around the seeded flights: a ground delay
/// program at SFO (low clouds), departure delays building at AUS and a ground stop at EWR; NOTAMs at SFO
/// (two runway closures, an ILS glide slope out, a taxiway, construction, an unlit tower) and AUS. Any
/// other US airport is calm; outside the US there are no programs. Times follow the clock given.
public actor FakeFAAService: FAAService {
    public var nextError: APIError?
    private let airports: [Airport]
    private let clock: @Sendable () -> Date

    /// - Parameter now: the clock the answers are for; the real time when nil.
    public init(now: Date? = nil) {
        airports = FakeSeed.load("airports")
        clock = { now ?? .now }
    }

    public func setNextError(_ error: APIError?) { nextError = error }

    private func airport(_ code: String) throws(APIError) -> Airport {
        let c = code.uppercased()
        guard let a = airports.first(where: { $0.id == c || $0.iata == c }) else { throw .notFound }
        return a
    }

    /// The fake programs at `icao` for `now`.
    static func programs(_ icao: String, now: Date) -> [AirportProgram] {
        let h: (Double) -> Date = { now.addingTimeInterval($0 * 3600) }
        switch icao {
        case "KSFO":
            return [AirportProgram(airport: "SFO", kind: .groundDelay, reason: "low clouds",
                                   reasonRaw: "WEATHER / LOW CEILINGS", averageMinutes: 47,
                                   startsAt: h(-2), endsAt: h(6), updatedAt: h(-0.3),
                                   advisoryURL: URL(string: "https://www.fly.faa.gov/adv/adv_spt.jsp"))]
        case "KAUS":
            return [AirportProgram(airport: "AUS", kind: .departureDelay, reason: "heavy traffic",
                                   reasonRaw: "TM Initiatives:MIT:VOL", averageMinutes: 25, trend: .increasing,
                                   updatedAt: h(-0.2))]
        case "KEWR":
            return [AirportProgram(airport: "EWR", kind: .groundStop, reason: "thunderstorms",
                                   reasonRaw: "WEATHER / THUNDERSTORMS", extensionChance: .medium,
                                   startsAt: h(-0.5), endsAt: h(1), updatedAt: h(-0.4))]
        default:
            return []
        }
    }

    /// The fake notices at `icao` for `now`, ranked as the backend ranks them.
    static func notams(_ icao: String, now: Date) -> [Notam] {
        let h: (Double) -> Date = { now.addingTimeInterval($0 * 3600) }
        switch icao {
        case "KSFO":
            return [
                Notam(number: "10/101", kind: .runwayClosed, title: "Runway 10L/28R closed", relevance: 80,
                      raw: "!SFO 10/101 SFO RWY 10L/28R CLSD 2610310500-2610311300", startsAt: h(-3), endsAt: h(5)),
                Notam(number: "10/104", kind: .ilsOut, title: "ILS glide slope for runway 28L out of service",
                      detail: "Landings in low cloud or fog may be slower.", relevance: 60,
                      raw: "!SFO 10/104 SFO NAV ILS RWY 28L GP U/S 2610301600-2611011600",
                      startsAt: h(-16), endsAt: h(32)),
                Notam(number: "10/102", kind: .runwayClosed, title: "Runway 01R/19L closed in part", relevance: 50,
                      raw: "!SFO 10/102 SFO RWY 01R/19L CLSD EXC XNG 2610311400-2610312200",
                      startsAt: h(2), endsAt: h(10)),
                Notam(number: "10/103", kind: .taxiwayClosed, title: "Taxiway C closed in part",
                      detail: "Between A and B.", relevance: 25,
                      raw: "!SFO 10/103 SFO TWY C BTN TWY A AND TWY B CLSD 2610300800-2611152359EST",
                      startsAt: h(-24), endsAt: h(360), endsEstimated: true),
                Notam(number: "10/107", kind: .construction, title: "Construction on the apron", relevance: 20,
                      raw: "!SFO 10/107 SFO APRON TERMINAL 2 RAMP WIP 2610300600-2611302359",
                      startsAt: h(-26), endsAt: h(700)),
                Notam(number: "10/105", kind: .obstacleLight, title: "Unlit tower",
                      detail: "1.6 NM NW of the airport, 296 ft tall.", relevance: 5,
                      raw: "!SFO 10/105 SFO OBST TOWER LGT (ASR 1234567) 373712.00N1222248.00W (1.6NM NW SFO) 412FT (296FT AGL) U/S 2610290000-2611120000",
                      startsAt: h(-48), endsAt: h(300)),
            ]
        case "KAUS":
            return [Notam(number: "10/212", kind: .runwayClosed, title: "Runway 18L/36R closed", relevance: 80,
                          raw: "!AUS 10/212 AUS RWY 18L/36R CLSD 2610310400-2610311200", startsAt: h(-1), endsAt: h(3))]
        default:
            return []
        }
    }

    public func programs(airport: String) async throws(APIError) -> AirportPrograms? {
        if let e = nextError { nextError = nil; throw e }
        let a = try self.airport(airport)
        guard a.country == "US" else { return nil }
        let now = clock()
        return AirportPrograms(airportIcao: a.id, iata: a.iata, fetchedAt: now.addingTimeInterval(-90),
                               programs: Self.programs(a.id, now: now))
    }

    public func notams(airport: String) async throws(APIError) -> NotamReport? {
        if let e = nextError { nextError = nil; throw e }
        let a = try self.airport(airport)
        let now = clock()
        return NotamReport(airportIcao: a.id, iata: a.iata, fetchedAt: now.addingTimeInterval(-240),
                           notams: Self.notams(a.id, now: now))
    }
}
