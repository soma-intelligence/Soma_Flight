import Foundation
import Observation

@MainActor @Observable
public final class FlightDetailStore {
    public private(set) var flight: Flight?
    public private(set) var events: [FlightEvent] = []
    public private(set) var origin: Airport?
    /// The airport the flight actually ended at: the diversion target when diverted.
    public private(set) var destination: Airport?
    public private(set) var error: APIError?
    /// Alerts for this flight: true or false while the user follows it, nil when not followed or unknown.
    public private(set) var notify: Bool?
    /// A notify change is on its way to the server.
    public private(set) var isSavingNotify = false
    /// What the user noted on the flight (booking code, seat, notes); nil when not followed or unknown.
    public private(set) var details: FollowDetails?
    /// A details change is on its way to the server.
    public private(set) var isSavingDetails = false
    /// Why the last details change did not stick; cleared when the user tries again or opens an editor.
    public private(set) var detailsError: APIError?
    /// Why "Stop Tracking" did not work; the sheet shows it until dismissed.
    public private(set) var trackingError: APIError?
    /// True while the user follows the flight, as far as this screen knows.
    public var isFollowed: Bool { details != nil && !isArchived }
    /// A Passport flight: built from the history row, nothing to follow, refresh or edit here.
    public let isArchived: Bool

    // Good to Know and the history card (`loadExtras()`). Each one is nil until it loads and stays nil
    // when its call fails: a failure hides that row only, never an error banner.
    /// Departures at the origin.
    public private(set) var originStats: DelayStats?
    /// Arrivals at the destination.
    public private(set) var destinationStats: DelayStats?
    public private(set) var originWeather: Weather?
    public private(set) var destinationWeather: Weather?
    /// The user's past flights between the two airports, both ways; nil when none or not loaded.
    private(set) var routeHistory: RouteHistory?
    /// The flight's place among the traveller's flights on its tail ("your 3rd flight on F-GSQA"); nil when
    /// the tail is unknown or new to them (`TailVisits`). Filled by `loadExtras()` from the history.
    public private(set) var tailVisit: Int?
    /// How this flight number arrived lately (paid data; nil when insights are off or have none).
    public private(set) var forecast: ArrivalForecast?
    /// The aircraft's earlier flights, newest first (paid data; empty when insights are off or know none).
    public private(set) var inbound: [InboundLeg] = []
    /// The security wait at the origin (free data; nil outside the US, when the flight is not leaving
    /// within 12 hours, or on failure). The sheet shows it only inside `SecurityWaitFacts.window`.
    public private(set) var securityWait: SecurityWait?
    /// The gates the flight number used lately, for the gate prediction (free data; nil once the flight has
    /// a gate or has left, or on failure). See `FlightDetailStore+Prediction.swift`.
    public private(set) var gateHistory: GateHistory?
    /// The Connection Assistant (connections with other followed flights, other flights on the route);
    /// nil shows neither card. `AppEnvironment.makeFlightDetailStore` sets it for followed flights.
    public internal(set) var connections: ConnectionStore?
    /// FAA programs and NOTAMs at both airports (free data; parts stay nil outside the US, without the
    /// NOTAM key, once the flight landed, or on failure).
    public private(set) var advisories = FlightAdvisories()

    /// What the device kept for the flight before departure (`OfflineFlightPack`); nil when nothing was kept.
    public private(set) var offlinePack: OfflineFlightPack?

    /// The boarding pass kept on this device for the flight; nil when there is none (or a Passport flight).
    public private(set) var boardingPass: BoardingPass?
    /// True with the fakes: Add to Apple Wallet only pretends (see `AppEnvironment.simulatesWallet`).
    public let simulatesWallet: Bool

    /// What the server holds, to go back to when a save fails.
    private var confirmedDetails: FollowDetails?
    /// Bumped by every save; only the newest one may roll back or report an error.
    private var detailsGeneration = 0
    /// Saves run one after another, in the order the user made them.
    private var detailsChain: Task<Bool, Never>?

    private let id: Flight.ID
    private let flights: any FlightService
    private let airports: any AirportService
    private let history: (any HistoryService)?
    private let insights: any InsightsService
    private let security: any SecurityWaitService
    private let gates: any GateHistoryService
    private let faa: any FAAService
    private let cache: (any FlightListCache)?
    private let passes: (any BoardingPassVault)?
    private let packs: (any OfflinePackCache)?
    private let lookup: @Sendable (String) -> Airport?

    /// - Parameters:
    ///   - history: the user's past flights, for the history card; nil shows none.
    ///   - insights: the arrival forecast and inbound chain; the default asks nothing and shows nothing.
    ///   - security: the security wait at the origin; the default asks nothing and shows nothing.
    ///   - gates: the flight number's recent gates, for the gate prediction; the default asks nothing.
    ///   - passes: the account's boarding passes on this device; nil offers none.
    ///   - packs: where the offline pack is kept from a day before departure; nil keeps none.
    ///   - lookup: an airport by code, to match a boarding pass's airports and day to the flight.
    public init(id: Flight.ID, flights: any FlightService, airports: any AirportService,
                history: (any HistoryService)? = nil, insights: any InsightsService = UnavailableInsightsService(),
                security: any SecurityWaitService = UnavailableSecurityWaitService(),
                gates: any GateHistoryService = UnavailableGateHistoryService(),
                faa: any FAAService = UnavailableFAAService(),
                cache: (any FlightListCache)? = nil, passes: (any BoardingPassVault)? = nil,
                packs: (any OfflinePackCache)? = nil,
                lookup: @escaping @Sendable (String) -> Airport? = { _ in nil }, simulatesWallet: Bool = false) {
        self.id = id; self.flights = flights; self.airports = airports; self.history = history
        self.insights = insights; self.security = security; self.gates = gates; self.faa = faa
        self.cache = cache; self.passes = passes; self.packs = packs; self.lookup = lookup
        self.simulatesWallet = simulatesWallet
        isArchived = false
    }

    /// A past flight from the history: the flight and the tiles come from the row, only the airports load.
    public init(past: PastFlight, flights: any FlightService, airports: any AirportService,
                history: (any HistoryService)? = nil) {
        id = past.id; self.flights = flights; self.airports = airports; self.history = history
        insights = UnavailableInsightsService(); security = UnavailableSecurityWaitService(); cache = nil
        gates = UnavailableGateHistoryService(); faa = UnavailableFAAService()
        passes = nil; packs = nil; lookup = { _ in nil }
        simulatesWallet = false
        isArchived = true
        flight = past.asFlight
        details = past.details
        confirmedDetails = details
    }

    /// A friend's flight (the Friends tab), read only like a Passport flight: the flight as the friend shared it,
    /// only the airports load, and nothing of the friend's own (seat, booking code, notes, pass) is there to show.
    /// The user's own history on the route is left out too: the sheet is about the friend's trip.
    public init(friend flight: Flight, flights: any FlightService, airports: any AirportService) {
        id = flight.id; self.flights = flights; self.airports = airports; history = nil
        insights = UnavailableInsightsService(); security = UnavailableSecurityWaitService(); cache = nil
        gates = UnavailableGateHistoryService(); faa = UnavailableFAAService()
        passes = nil; packs = nil; lookup = { _ in nil }
        simulatesWallet = false
        isArchived = true
        self.flight = flight
    }

    /// Failures set `error` (first one wins) and keep earlier data. A diverted flight whose events
    /// failed shows no destination rather than the planned one.
    public func load() async {
        var firstError: APIError?
        func note(_ e: APIError) { if firstError == nil { firstError = e } }
        if isArchived, var f = flight {
            do { origin = try await airports.airport(f.originIcao) } catch { note(error) }
            do { destination = try await airports.airport(f.destinationIcao) } catch { note(error) }
            // The history row keeps ICAO codes only; the airports give the IATA ones the screen shows.
            f.originIata = origin?.iata; f.destinationIata = destination?.iata
            flight = f
            error = firstError
            return
        }
        // The boarding pass is on the device: it shows at the gate even with no network.
        if boardingPass == nil, let passes { boardingPass = await passes.pass(for: id) }
        // Last known state first, so the screen is not blank while the network answers or when it is down.
        var cachedHere: Flight?
        if flight == nil, let cache {
            let cached = await cache.flights().first { $0.id == id }
            if flight == nil { flight = cached; cachedHere = cached }
        }
        // The pack kept before departure: the flight and both airports, for the estimate with no network.
        // Its flight wins over the list's copy when it was updated later; never over a live answer.
        if offlinePack == nil, let packs, let pack = await packs.pack(for: id) {
            offlinePack = pack
            if flight == nil {
                flight = pack.flight
            } else if let cachedHere, flight == cachedHere, pack.flight.updatedAt > cachedHere.updatedAt {
                flight = pack.flight
            }
            if origin == nil { origin = pack.origin }
            if destination == nil { destination = pack.destination }
        }
        let f: Flight
        do { f = try await flights.flight(id) } catch {
            self.error = error
            // Offline: the bundled airports still place the plane and name the time zones.
            if let cached = flight {
                if origin == nil { origin = lookup(cached.originIcao) }
                if destination == nil { destination = lookup(cached.destinationIcao) }
            }
            return
        }
        flight = f
        // The switch only: a failure hides it rather than covering the flight with an error.
        if !isSavingNotify, let n = try? await flights.notifies(id), !isSavingNotify { notify = n }
        // The tiles likewise: a failure keeps what they show.
        if !isSavingDetails, let d = try? await flights.followDetails(id), !isSavingDetails {
            details = d
            confirmedDetails = d
        }

        var eventsFailed = false
        do { events = try await flights.events(id) } catch { note(error); eventsFailed = true }

        var destCode: String? = f.destinationIcao
        if f.status == .diverted {
            if let d = events.last(where: { $0.kind == .diversion })?.payload["destination"], !d.isEmpty {
                destCode = d
            } else if eventsFailed {
                destCode = nil
            }
        }
        do { origin = try await airports.airport(f.originIcao) } catch { note(error) }
        if let destCode {
            do { destination = try await airports.airport(destCode) } catch { note(error); destination = nil }
        } else {
            destination = nil
        }
        error = firstError
        await keepOfflinePack(f, now: .now)
    }

    /// From a day before departure until the flight is over, keeps what the sheet needs to show the flight
    /// with no connection (`OfflineFlightPack`). Needs both airports.
    func keepOfflinePack(_ f: Flight, now: Date) async {
        guard let packs, OfflineFlightPack.isWorthSaving(f, now: now), let origin,
              let destination = destination ?? lookup(f.destinationIcao) else { return }
        let pack = OfflineFlightPack(flight: f, origin: origin, destination: destination,
                                     aircraft: f.aircraftType.flatMap { ReferenceData.bundled().type($0) }, savedAt: now)
        await packs.save(pack: pack)
        offlinePack = pack
    }

    /// False for a canceled or diverted flight: an arrival forecast and the inbound plane mean nothing for
    /// it, so the screen hides both sections and `loadExtras` makes no (paid) insights call.
    public nonisolated static func showsInsights(_ status: FlightStatus) -> Bool {
        status != .canceled && status != .diverted
    }

    /// Fills Good to Know (each airport's delays and weather), the history card and the paid insights,
    /// after `load()`, and the security wait at the origin for a flight leaving within 12 hours. The calls
    /// run at once; each failure leaves only its own value nil or empty. A cancelled load (the sheet closed
    /// or the flight changed) assigns nothing. A canceled or diverted flight skips the two insights calls
    /// (`showsInsights`).
    public func loadExtras(now: Date = .now) async {
        guard let f = flight else { return }
        let airports = airports, history = history, id = id
        let insights: (any InsightsService)? = Self.showsInsights(f.status) ? self.insights : nil
        let originCode = f.originIcao
        let destinationCode = destination?.id ?? f.destinationIcao
        async let oStats = try? airports.stats(originCode)
        async let dStats = try? airports.stats(destinationCode)
        async let oWeather = try? airports.weather(originCode)
        async let dWeather = try? airports.weather(destinationCode)
        async let past = Self.pastFlights(history)
        async let forecastValue = Self.forecast(insights, ident: f.ident)
        async let inboundValue = Self.inbound(insights, id: id)
        let security: (any SecurityWaitService)? = SecurityWaitFacts.worthLoading(f, now: now) ? self.security : nil
        async let securityValue = Self.securityWait(security, airport: originCode)
        async let gatesValue = Self.gateHistory(gates, flight: f, originTimeZone: origin?.timeZone)
        let faa: (any FAAService)? = FAAFacts.worthLoading(f.status) ? self.faa : nil
        async let faaValue = Self.advisories(faa, origin: originCode, destination: destinationCode)
        let results = await (oStats, dStats, oWeather, dWeather, past, forecastValue, inboundValue, securityValue, faaValue)
        let gateValue = await gatesValue
        guard !Task.isCancelled else { return }
        gateHistory = gateValue
        originStats = results.0?.departures
        destinationStats = results.1?.arrivals
        originWeather = results.2?.weather
        destinationWeather = results.3?.weather
        routeHistory = results.4.flatMap {
            RouteHistory.compute($0, origin: f.originIcao, destination: f.destinationIcao, excluding: f)
        }
        tailVisit = results.4.flatMap { TailVisits.ordinal(flight ?? f, past: $0) }
        forecast = results.5
        inbound = results.6 ?? []
        securityWait = results.7
        advisories = results.8 ?? FlightAdvisories()
    }

    private nonisolated static func securityWait(_ service: (any SecurityWaitService)?, airport: String) async -> SecurityWait? {
        guard let service else { return nil }
        return try? await service.securityWait(airport: airport)
    }

    private nonisolated static func advisories(_ service: (any FAAService)?, origin: String,
                                               destination: String) async -> FlightAdvisories? {
        guard let service else { return nil }
        return await FlightAdvisories.load(service, origin: origin, destination: destination)
    }

    private nonisolated static func forecast(_ insights: (any InsightsService)?, ident: String) async -> ArrivalForecast? {
        guard let insights else { return nil }
        return try? await insights.arrivalForecast(ident: ident)
    }

    private nonisolated static func inbound(_ insights: (any InsightsService)?, id: Flight.ID) async -> [InboundLeg]? {
        guard let insights else { return nil }
        return try? await insights.inbound(id)
    }

    private nonisolated static func pastFlights(_ history: (any HistoryService)?) async -> [PastFlight]? {
        guard let history else { return nil }
        return try? await history.pastFlights()
    }

    /// How often an open detail asks for the live position while the flight is in the air: the
    /// backend's shared window, so asking more often never buys a fresher one.
    public static let positionInterval: Duration = .seconds(120)

    /// Keeps the live position fresh while the screen is open (run it in the screen's task, after
    /// `load()`): asks at once, then every `interval`, until the task is cancelled.
    public func followPosition(every interval: Duration = positionInterval) async {
        while !Task.isCancelled {
            await refreshPosition()
            do { try await Task.sleep(for: interval) } catch { return }
        }
    }

    /// One position refresh for a followed flight that is departed or en route; nothing for the rest.
    /// A failure keeps what is on screen: the position is a nicety, never an error banner.
    func refreshPosition() async {
        guard let f = flight, f.status == .departed || f.status == .enRoute, notify != nil else { return }
        guard let fresh = try? await flights.refreshPosition(id), fresh.id == flight?.id else { return }
        flight = fresh
    }

    /// Turns alerts for the followed flight on or off (`follow(_:notify:)`). The switch moves at once and
    /// goes back, with `error` set, when the server refuses.
    public func setNotify(_ on: Bool) async {
        guard let before = notify, before != on, !isSavingNotify else { return }
        notify = on
        isSavingNotify = true
        defer { isSavingNotify = false }
        do {
            try await flights.follow(id, notify: on)
        } catch {
            notify = before
            self.error = error
        }
    }

    /// Stores the booking code, seat and notes of the followed flight. Each field is normalised first
    /// (`FollowDetails.normalized()`); a value that does not normalise sends nothing and returns false.
    /// The tiles change at once. Saves are sent one after another and the latest wins: a save that a newer
    /// one replaced before it left is skipped, and only the newest one rolls the tiles back to what the
    /// server holds and sets `detailsError` when refused. Returns whether this edit is now stored (or
    /// superseded by a newer one).
    @discardableResult
    public func saveDetails(_ new: FollowDetails) async -> Bool {
        guard details != nil, let clean = new.normalized() else { return false }
        detailsError = nil
        guard clean != details || clean != confirmedDetails else { return true }
        detailsGeneration += 1
        let generation = detailsGeneration
        details = clean
        isSavingDetails = true
        let previous = detailsChain
        let work = Task { @MainActor [weak self] () -> Bool in
            _ = await previous?.value
            guard let self else { return false }
            return await self.send(clean, generation: generation)
        }
        detailsChain = work
        let stored = await work.value
        if generation == detailsGeneration { isSavingDetails = false }
        return stored
    }

    private func send(_ value: FollowDetails, generation: Int) async -> Bool {
        // A newer edit is queued behind this one: only the newest goes to the server.
        guard generation == detailsGeneration else { return true }
        do {
            try await flights.saveFollowDetails(id, value)
            confirmedDetails = value
            return true
        } catch {
            if generation == detailsGeneration {
                details = confirmedDetails
                detailsError = error
            }
            return false
        }
    }

    /// Forgets the last details error (the user opened an editor or dismissed it).
    public func clearDetailsError() { detailsError = nil }

    /// Unfollows the flight. `unfollow` does the work when the screen sits in a shell that keeps its own
    /// list (it returns the error, nil on success); else the service is asked directly. On failure the
    /// sheet stays and `trackingError` says why.
    @discardableResult
    public func stopTracking(via unfollow: ((Flight.ID) async -> APIError?)? = nil) async -> Bool {
        guard isFollowed else { return false }
        trackingError = nil
        let failure: APIError?
        if let unfollow {
            failure = await unfollow(id)
        } else {
            do { try await flights.unfollow(id); failure = nil } catch { failure = error }
        }
        if let failure {
            trackingError = failure
            return false
        }
        details = nil
        confirmedDetails = nil
        notify = nil
        return true
    }

    public func clearTrackingError() { trackingError = nil }
}

extension FollowDetails {
    /// The details as stored: seat and booking code trimmed and upper-cased, notes trimmed, empty text
    /// cleared. nil when any field is not valid (a seat like "ZZ", a 3-letter code, notes over 2000).
    public func normalized() -> FollowDetails? {
        var out = self
        if let s = seat {
            guard let v = Self.normalizedSeat(s) else { return nil }
            out.seat = v
        }
        if let b = bookingCode {
            guard let v = Self.normalizedBookingCode(b) else { return nil }
            out.bookingCode = v
        }
        if let n = notes {
            guard let v = Self.normalizedNotes(n) else { return nil }
            out.notes = v
        }
        return out
    }
}

// MARK: - Boarding pass

extension FlightDetailStore {
    /// What became of a boarding pass offered to this flight.
    public enum PassResult: Equatable, Sendable {
        case attached
        /// The pass is for another flight; the text names it ("AF 83 · SFO to CDG · 25 Oct").
        case otherFlight(String)
        /// The pass could not be stored on the device.
        case failed
    }

    /// True when the sheet offers to add a boarding pass: a followed flight, with a place to keep one.
    public var takesBoardingPass: Bool { passes != nil && isFollowed }

    /// Keeps `pass` (and the Wallet file it came from) on this device for the flight, after checking it is
    /// for this flight, then fills the booking code, seat and class where the user has not set them.
    public func attach(_ pass: BoardingPass, walletFile: Data?) async -> PassResult {
        guard let passes, let f = flight else { return .failed }
        guard BoardingPassMatch.matches(pass, f, lookup: lookup) else {
            return .otherFlight(BoardingPassMatch.summary(pass))
        }
        var kept = pass
        kept.flightId = id
        do { try await passes.save(kept, walletFile: walletFile) } catch { return .failed }
        boardingPass = kept
        if let d = details, !isArchived, let next = BoardingPassMatch.filled(d, from: kept) {
            await saveDetails(next)
        }
        return .attached
    }

    /// The Wallet pass file the boarding pass came from; nil for a scanned one.
    public func walletFile() async -> Data? {
        await passes?.walletFile(for: id)
    }

    /// Forgets the boarding pass on this device (a copy added to Wallet stays in Wallet).
    public func removeBoardingPass() async {
        await passes?.remove(for: id)
        boardingPass = nil
    }
}
