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
    /// The Delay Report for the chosen year (`DelayReport`, airlines as ICAO codes).
    public private(set) var delayReport: DelayReport = .empty
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
    /// Every flight of the history, whatever the year (airlines as the core reads them, ICAO when known).
    public var allFlights: [PastFlight] { mapped }
    /// Years with at least one flight, newest first.
    public var years: [Int] { Array(Set(all.map(\.localYear))).sorted(by: >) }

    /// The selected year's flights that arrived latest, most late first, ten at most (the delay page's list).
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

    // MARK: Writes

    /// Why the last add, edit, delete or import failed; nil once one succeeds. The sheets show it.
    public private(set) var writeError: APIError?

    public func clearWriteError() { writeError = nil }

    /// Stores a flight added by hand; true once the server has it (the list shows it straight away).
    public func add(_ flight: PastFlight) async -> Bool {
        do {
            let stored = try await history.add(flight)
            await applied { $0.append(stored) }
            return true
        } catch {
            writeError = error
            return false
        }
    }

    /// Replaces a manual or imported flight; true once stored.
    public func update(_ flight: PastFlight) async -> Bool {
        do {
            let stored = try await history.update(flight)
            await applied { all in all = all.map { $0.id == stored.id ? stored : $0 } }
            return true
        } catch {
            writeError = error
            return false
        }
    }

    /// Deletes a manual or imported flight; true once gone.
    public func delete(_ id: PastFlight.ID) async -> Bool {
        do {
            try await history.delete(id)
            await applied { all in all.removeAll { $0.id == id } }
            return true
        } catch {
            writeError = error
            return false
        }
    }

    /// What importing `data` would add, skip and leave out as duplicates of the history as loaded.
    public func importPreview(_ data: Data, now: Date = .now) throws(PastFlightImport.Failure) -> PastFlightImport.Preview {
        try PastFlightImport.preview(data, existing: all, airport: airport, reference: reference, now: now)
    }

    /// Stores the flights of an import; the number stored, nil when any flight was not (`writeError`
    /// says why; the ones stored stay).
    public func importFlights(_ flights: [PastFlight]) async -> Int? {
        guard !flights.isEmpty else { return 0 }
        let outcome = await importFlights(flights, batchSize: HistoryImport.batchSize)
        return outcome.failed.isEmpty && !outcome.canceled ? outcome.stored.count : nil
    }

    /// Stores the flights of an import a batch at a time (`HistoryImport`), reporting progress after each.
    /// What was stored joins the history at the end, in one change, so the Passport's figures are worked
    /// out once; after any failure the history is loaded again, so it shows exactly what the server has.
    public func importFlights(_ flights: [PastFlight], batchSize: Int,
                              progress: @MainActor (HistoryImport.Progress) -> Void = { _ in }) async -> HistoryImport.Outcome {
        let outcome = await HistoryImport.run(flights, into: history, batchSize: batchSize, progress: progress)
        if !outcome.stored.isEmpty { await applied { $0 += outcome.stored } }
        if let first = outcome.failed.first {
            writeError = first.error
            await load()
        }
        return outcome
    }

    /// After a write the server accepted: applies its change to the loaded history (the figures follow)
    /// and saves the copy on the device.
    private func applied(_ change: (inout [PastFlight]) -> Void) async {
        writeError = nil
        change(&all)
        await cache?.save(past: all)
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

    /// The lead tail's age in whole months (`aircraft.tails.first`), nil without its delivery date. The core
    /// gives no age per tail, so it runs on that tail's flights alone and its `newest` is the age. Asked for
    /// by the Aircraft Stats page only, and run off the main actor.
    public func leadTailAge() async -> UInt32? {
        guard let reg = aircraft.tails.first?.registration, !facts.isEmpty else { return nil }
        return await Self.age(of: reg, flights: core, facts: facts.map(\.coreFact), year: year.map(Int32.init),
                              asOf: Int64(asOf.timeIntervalSince1970))
    }

    @concurrent nonisolated private static func age(of reg: String, flights: [FlightCore.PastFlight],
                                                    facts: [FlightCore.AircraftFact], year: Int32?,
                                                    asOf: Int64) async -> UInt32? {
        let own = flights.filter { registrationKey($0.registration) == reg }
        let known = facts.filter { registrationKey($0.registration) == reg }
        guard !own.isEmpty, !known.isEmpty else { return nil }
        return FlightCore.computeAircraftStats(flights: own, year: year, types: [], facts: known, asOf: asOf).newest?.ageMonths
    }

    /// A registration as the core keys its tails (aircraft.rs `code`): trimmed, upper case, nil when empty.
    nonisolated static func registrationKey(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t.uppercased()
    }

    private func recompute() {
        let y = year.map(Int32.init)
        stats = PassportStats.compute(core: core, year: year)
        delayReport = DelayReport.compute(mapped, year: year)
        detail = FlightCore.computePassportDetail(flights: core, year: y, countries: countries)
        aircraft = FlightCore.computeAircraftStats(flights: core, year: y, types: types, facts: facts.map(\.coreFact),
                                                   asOf: Int64(asOf.timeIntervalSince1970))
        revision += 1
    }
}
