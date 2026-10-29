import Foundation
import Observation
import FlightCore

@MainActor @Observable
public final class PassportStore {
    /// nil = all time. Changing it recomputes every figure.
    public var year: Int? {
        didSet { if year != oldValue { recompute() } }
    }
    public private(set) var error: APIError?
    public private(set) var isOffline = false
    /// Save time of the cached history while offline, nil when the data is live.
    public private(set) var lastUpdated: Date?
    /// True once a `load()` has finished, whatever its outcome (see `MyFlightsStore.hasLoaded`).
    public private(set) var hasLoaded = false
    /// When the history was last confirmed: now after a successful load, the cache's save time while offline.
    public internal(set) var fetchedAt: Date?

    /// The tab's totals for the chosen year (core `computePassport`).
    public private(set) var stats: PassportStats = .empty
    /// The full Passport figures for the chosen year (core `computePassportDetail`).
    public private(set) var detail: PassportDetail = .empty
    /// The aircraft figures for the chosen year (core `computeAircraftStats`).
    public private(set) var aircraft: AircraftStats = .empty
    /// Goes up every time the figures are recomputed; what a rendered copy (the share image) keys on.
    public private(set) var revision = 0

    private var all: [PastFlight] = [] {
        didSet { remap() }
    }
    /// `all` as the core reads it: airlines as ICAO codes, countries filled from the airports.
    private var mapped: [PastFlight] = []
    private var core: [FlightCore.PastFlight] = []
    private var facts: [AircraftFact] = []
    /// The registrations `facts` was asked for, so a reload with the same tails does not ask again.
    private var factsAskedFor: [String]?

    private let history: any HistoryService
    private let cache: (any PastFlightCache)?
    private let reference: ReferenceData
    private let factsService: (any AircraftFactsService)?
    private let airport: @Sendable (String) -> Airport?
    private let asOf: Date
    private let countries: [FlightCore.CountryInfo]
    private let types: [FlightCore.TypeInfo]

    /// - Parameters:
    ///   - reference: airlines (names mapped to ICAO), aircraft types and countries.
    ///   - facts: airframe delivery dates for ages; nil means none, and the ages hide.
    ///   - asOf: the day ages are counted to.
    ///   - airports: where a flight's country comes from when the flight does not carry it.
    public init(history: any HistoryService, cache: (any PastFlightCache)? = nil, reference: ReferenceData = .bundled(),
                facts: (any AircraftFactsService)? = nil, asOf: Date = Date.now,
                airports: (@Sendable (String) -> Airport?)? = nil) {
        self.history = history; self.cache = cache; self.reference = reference
        self.factsService = facts; self.asOf = asOf
        self.airport = airports ?? Self.bundledAirports
        countries = reference.countries.map(\.coreInfo)
        types = reference.types.map(\.coreTypeInfo)
    }

    /// The bundled airport directory, read once for every store that is not handed one.
    nonisolated static let bundledAirports: @Sendable (String) -> Airport? = AirportDirectory.bundled().lookup

    /// Flights as the core reads them: the airline as its ICAO code when the reference list knows the
    /// name or code (else as given), the countries from the airports when the flight does not carry them.
    nonisolated static func mapped(_ flights: [PastFlight], reference: ReferenceData,
                                   airport: (String) -> Airport?) -> [PastFlight] {
        flights.map { f in
            var m = f
            if let name = f.airline, let hit = reference.airline(name) { m.airline = hit.id }
            m.originCountry = f.originCountry ?? airport(f.originIcao)?.country
            m.destinationCountry = f.destinationCountry ?? airport(f.destinationIcao)?.country
            return m
        }
    }

    /// Flights in the selected year (by local departure date), newest first.
    public var flights: [PastFlight] {
        all.filter { year == nil || $0.localYear == year }.sorted { $0.date > $1.date }
    }
    /// Years with at least one flight, newest first.
    public var years: [Int] { Array(Set(all.map(\.localYear))).sorted(by: >) }

    /// The selected year's flights that left latest, most late first, ten at most (the delay page's list).
    public var mostDelayed: [PastFlight] { PassportPicks.mostDelayed(flights) }

    /// The most flown aircraft type of the year, from the reference list when it knows the designator.
    public var mostFlownType: AircraftType? { aircraft.mostFlown.flatMap { reference.type($0.icaoType) } }

    /// The airline that flew the most flown type most often for this user: whose livery the card shows.
    public var mostFlownAirline: Airline? {
        guard let type = aircraft.mostFlown?.icaoType else { return nil }
        let inYear = mapped.filter { year == nil || $0.localYear == year }
        return PassportPicks.topAirline(for: type, in: inYear).flatMap { reference.airline($0) }
    }

    public func load() async {
        if all.isEmpty, let cache {
            let cached = await cache.past()
            if all.isEmpty { all = cached }
        }
        do {
            all = try await history.pastFlights()
            error = nil; isOffline = false; lastUpdated = nil
            fetchedAt = Date.now; hasLoaded = true
            await cache?.save(past: all)
        } catch {
            self.error = error
            isOffline = error == .offline
            hasLoaded = true
            if isOffline, let cache { lastUpdated = await cache.pastSavedAt(); fetchedAt = lastUpdated }
        }
        await loadFacts()
    }

    // MARK: Figures

    private func loadFacts() async {
        guard let factsService else { return }
        let regs = Array(Set(all.compactMap(\.registration).filter { !$0.isEmpty })).sorted()
        guard regs != factsAskedFor else { return }
        factsAskedFor = regs
        let got: [AircraftFact]
        do {
            got = regs.isEmpty ? [] : try await factsService.facts(regs)
        } catch {
            // Asked again on the next load; the ages stay as they were meanwhile.
            if factsAskedFor == regs { factsAskedFor = nil }
            return
        }
        // A newer load may have asked for other tails meanwhile; its answer wins.
        guard factsAskedFor == regs else { return }
        facts = got
        recompute()
    }

    private func remap() {
        mapped = Self.mapped(all, reference: reference, airport: airport)
        core = mapped.map(\.coreFlight)
        recompute()
    }

    private func recompute() {
        let y = year.map(Int32.init)
        stats = PassportStats.compute(core: core, year: year)
        detail = FlightCore.computePassportDetail(flights: core, year: y, countries: countries)
        aircraft = FlightCore.computeAircraftStats(flights: core, year: y, types: types, facts: facts.map(\.coreFact),
                                                   asOf: Int64(asOf.timeIntervalSince1970))
        revision += 1
    }
}
