import Foundation
import Synchronization

// MARK: - Seed loading

/// Seeds live in the library bundle (Resources/Fakes) so `-useFakes` works at runtime.
/// Times are authored around `reference`; `shift` moves them so the seed's "now" is the real now.
enum FakeSeed {
    static let reference = Date(timeIntervalSince1970: 1_792_770_120) // 2026-10-23T15:42:00Z

    static func shift(now: Date = .now) -> TimeInterval {
        (now.timeIntervalSince(reference) / 60).rounded() * 60
    }

    static func load<T: Decodable>(_ name: String, as type: T.Type = T.self) -> T {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fakes")
                ?? Bundle.module.url(forResource: name, withExtension: "json") else {
            fatalError("Missing fake seed \(name).json")
        }
        do { return try FlightJSON.decoder.decode(T.self, from: Data(contentsOf: url)) }
        catch { fatalError("Bad fake seed \(name).json: \(error)") }
    }

    static func flights(_ name: String, shift s: TimeInterval) -> [Flight] {
        load(name, as: [Flight].self).map { $0.shifted(by: s) }
    }

    static func boards(shift s: TimeInterval) -> [AirportBoard] {
        load("boards", as: [AirportBoard].self).map {
            var b = $0
            b.fetchedAt = b.fetchedAt.addingTimeInterval(s)
            b.flights = b.flights.map { $0.shifted(by: s) }
            return b
        }
    }
}

private extension Flight {
    func shifted(by s: TimeInterval) -> Flight {
        var f = self
        func mv(_ d: Date?) -> Date? { d?.addingTimeInterval(s) }
        f.scheduledOut = mv(scheduledOut); f.scheduledIn = mv(scheduledIn)
        f.estimatedOut = mv(estimatedOut); f.estimatedIn = mv(estimatedIn)
        f.actualOut = mv(actualOut); f.actualOff = mv(actualOff)
        f.actualOn = mv(actualOn); f.actualIn = mv(actualIn)
        f.updatedAt = updatedAt.addingTimeInterval(s)
        if var p = position { p.at = p.at.addingTimeInterval(s); f.position = p }
        return f
    }
}

private extension DelayStats {
    func shifted(by s: TimeInterval) -> DelayStats {
        var d = self
        // Keep buckets aligned to whole hours.
        let whole = (s / 3600).rounded() * 3600
        d.perHour = perHour.map { var b = $0; b.hour = b.hour.addingTimeInterval(whole); return b }
        return d
    }
}

private extension Weather {
    func shifted(by s: TimeInterval) -> Weather {
        var w = self
        w.observedAt = observedAt.addingTimeInterval(s)
        w.forecast = forecast.map { var p = $0; p.from = p.from.addingTimeInterval(s); p.to = p.to.addingTimeInterval(s); return p }
        return w
    }
}

private struct StatsPair: Decodable { var departures: DelayStats; var arrivals: DelayStats }

// MARK: - Shared helpers

/// Fan-out of flight updates to live streams. Lock-protected so `updates(for:)` can stay synchronous.
private final class UpdateHub: Sendable {
    private struct Sub { var ids: Set<UUID>; var continuation: AsyncStream<Flight>.Continuation }
    private let subs = Mutex<[UUID: Sub]>([:])

    func stream(for ids: [UUID]) -> AsyncStream<Flight> {
        let key = UUID()
        let (stream, continuation) = AsyncStream<Flight>.makeStream()
        subs.withLock { $0[key] = Sub(ids: Set(ids), continuation: continuation) }
        continuation.onTermination = { [weak self] _ in self?.subs.withLock { _ = $0.removeValue(forKey: key) } }
        return stream
    }

    func emit(_ flight: Flight) {
        let targets = subs.withLock { $0.values.filter { $0.ids.contains(flight.id) }.map(\.continuation) }
        for c in targets { c.yield(flight) }
    }
}

private func normalized(_ code: String) -> String { code.trimmingCharacters(in: .whitespaces).uppercased() }

// MARK: - FlightService

public actor FakeFlightService: FlightService {
    public var nextError: APIError?
    private var pool: [Flight.ID: Flight] = [:]
    private var followedIDs: [Flight.ID] = []
    private var notify: [Flight.ID: Bool] = [:]
    private let airports: [Airport]
    private let hub = UpdateHub()

    /// - Parameter now: the clock the seed is shifted to. `FakeSeed.reference` keeps the seed's own times
    ///   (previews and snapshots).
    public init(now: Date = .now) {
        let s = FakeSeed.shift(now: now)
        let followed = FakeSeed.flights("followed", shift: s)
        for f in followed { pool[f.id] = f }
        followedIDs = followed.map(\.id)
        for b in FakeSeed.boards(shift: s) { for f in b.flights where pool[f.id] == nil { pool[f.id] = f } }
        airports = FakeSeed.load("airports")
    }

    public func setNextError(_ error: APIError?) { nextError = error }

    private func check() throws(APIError) {
        if let e = nextError { nextError = nil; throw e }
    }

    private func matches(_ code: String, icao: String, iata: String?) -> Bool {
        let c = normalized(code)
        return c == icao || c == iata
    }

    public func lookup(_ query: FlightQuery) async throws(APIError) -> [Flight] {
        try check()
        let all = pool.values.sorted { ($0.scheduledOut ?? .distantFuture) < ($1.scheduledOut ?? .distantFuture) }
        let hits: [Flight]
        switch query {
        case .ident(let ident, _):
            hits = all.filter { normalized($0.ident) == normalized(ident) }
        case .route(let o, let d, _):
            hits = all.filter {
                matches(o, icao: $0.originIcao, iata: $0.originIata) && matches(d, icao: $0.destinationIcao, iata: $0.destinationIata)
            }
        case .airport(let code):
            hits = all.filter {
                matches(code, icao: $0.originIcao, iata: $0.originIata) || matches(code, icao: $0.destinationIcao, iata: $0.destinationIata)
            }
        }
        guard !hits.isEmpty else { throw .notFound }
        return hits
    }

    public func followed() async throws(APIError) -> [Flight] {
        try check()
        return followedIDs.compactMap { pool[$0] }
    }

    public func follow(_ id: Flight.ID, notify: Bool) async throws(APIError) {
        try check()
        guard pool[id] != nil else { throw .notFound }
        if !followedIDs.contains(id) { followedIDs.append(id) }
        self.notify[id] = notify
    }

    public func notifies(_ id: Flight.ID) async throws(APIError) -> Bool? {
        try check()
        return followedIDs.contains(id) ? notify[id] ?? true : nil
    }

    public func unfollow(_ id: Flight.ID) async throws(APIError) {
        try check()
        followedIDs.removeAll { $0 == id }
        notify[id] = nil
    }

    /// Ids `refreshPosition` was asked for, in order.
    public private(set) var positionRequests: [Flight.ID] = []

    /// The stored flight: the seed already carries positions for flights in the air.
    public func refreshPosition(_ id: Flight.ID) async throws(APIError) -> Flight? {
        try check()
        positionRequests.append(id)
        return pool[id]
    }

    public func flight(_ id: Flight.ID) async throws(APIError) -> Flight {
        try check()
        guard let f = pool[id] else { throw .notFound }
        return f
    }

    public func events(_ id: Flight.ID) async throws(APIError) -> [FlightEvent] {
        try check()
        guard let f = pool[id] else { throw .notFound }
        var out: [FlightEvent] = []
        func add(_ kind: FlightEventKind, _ at: Date?, _ payload: [String: String] = [:]) {
            if let at { out.append(FlightEvent(flightId: id, kind: kind, payload: payload, receivedAt: at)) }
        }
        if let d = f.departureDelay, d >= .seconds(15 * 60), let at = f.estimatedOut ?? f.actualOut {
            add(.delay, at.addingTimeInterval(-3600), ["minutes": String(Int(d.components.seconds / 60))])
        }
        if let g = f.gateOrigin { add(.gateChange, (f.scheduledOut ?? f.updatedAt).addingTimeInterval(-5400), ["gate": g]) }
        add(.departure, f.actualOut)
        add(.arrival, f.actualIn)
        if f.status == .canceled { add(.cancel, f.updatedAt) }
        if f.status == .diverted { add(.diversion, f.actualOn ?? f.updatedAt, ["destination": f.destinationIcao]) }
        return out.sorted { $0.receivedAt < $1.receivedAt }
    }

    /// Emits `flight` to `updates` subscribers and stores it as the latest version.
    public func push(_ flight: Flight) {
        pool[flight.id] = flight
        hub.emit(flight)
    }

    public nonisolated func updates(for ids: [Flight.ID]) -> AsyncStream<Flight> {
        hub.stream(for: ids)
    }
}

// MARK: - AirportService

public actor FakeAirportService: AirportService {
    public var nextError: APIError?
    private let airports: [Airport]
    private let boards: [AirportBoard]
    private let stats: [String: StatsPair]
    private let weathers: [String: Weather]
    private let fetchedAt: Date

    /// - Parameter now: the clock the seed is shifted to. `FakeSeed.reference` keeps the seed's own times
    ///   (previews and snapshots).
    public init(now: Date = .now) {
        let s = FakeSeed.shift(now: now)
        airports = FakeSeed.load("airports")
        boards = FakeSeed.boards(shift: s)
        stats = FakeSeed.load("stats", as: [String: StatsPair].self).mapValues {
            StatsPair(departures: $0.departures.shifted(by: s), arrivals: $0.arrivals.shifted(by: s))
        }
        weathers = FakeSeed.load("weather", as: [String: Weather].self).mapValues { $0.shifted(by: s) }
        fetchedAt = FakeSeed.reference.addingTimeInterval(s - 120)
    }

    public func setNextError(_ error: APIError?) { nextError = error }

    private func check() throws(APIError) {
        if let e = nextError { nextError = nil; throw e }
    }

    private func resolve(_ code: String) throws(APIError) -> Airport {
        let c = normalized(code)
        guard let a = airports.first(where: { $0.id == c || $0.iata == c }) else { throw .notFound }
        return a
    }

    public func airport(_ code: String) async throws(APIError) -> Airport {
        try check()
        return try resolve(code)
    }

    public func board(_ code: String, _ kind: BoardKind) async throws(APIError) -> AirportBoard {
        try check()
        let a = try resolve(code)
        guard kind == .departures || kind == .arrivals else { throw .decoding("no board of kind \(kind.rawValue)") }
        guard let b = boards.first(where: { $0.icao == a.id && $0.kind == kind }) else { throw .notFound }
        return b
    }

    public func stats(_ code: String) async throws(APIError) -> (fetchedAt: Date, stale: Bool, departures: DelayStats, arrivals: DelayStats) {
        try check()
        let a = try resolve(code)
        guard let s = stats[a.id] else { throw .notFound }
        return (fetchedAt, false, s.departures, s.arrivals)
    }

    public func weather(_ code: String) async throws(APIError) -> (fetchedAt: Date, stale: Bool, weather: Weather) {
        try check()
        let a = try resolve(code)
        guard let w = weathers[a.id] else { throw .notFound }
        return (fetchedAt, false, w)
    }
}

// MARK: - AuthService

public actor FakeAuthService: AuthService {
    public var nextError: APIError?
    private var plan: Plan
    private let state = SessionState()

    private final class SessionState: Sendable {
        private struct Inner { var current: UserSession?; var subs: [UUID: AsyncStream<UserSession?>.Continuation] = [:] }
        private let inner = Mutex(Inner())

        func stream() -> AsyncStream<UserSession?> {
            let key = UUID()
            let (stream, c) = AsyncStream<UserSession?>.makeStream()
            inner.withLock { $0.subs[key] = c; c.yield($0.current) }
            c.onTermination = { [weak self] _ in self?.inner.withLock { _ = $0.subs.removeValue(forKey: key) } }
            return stream
        }

        func set(_ s: UserSession?) {
            inner.withLock { i in
                i.current = s
                for c in i.subs.values { c.yield(s) }
            }
        }
    }

    public init(plan: Plan = .free) { self.plan = plan }

    public func setNextError(_ error: APIError?) { nextError = error }
    public func setPlan(_ plan: Plan) { self.plan = plan }

    private func check() throws(APIError) {
        if let e = nextError { nextError = nil; throw e }
    }

    public nonisolated var session: AsyncStream<UserSession?> { state.stream() }

    public func signInWithApple(idToken: String, nonce: String) async throws(APIError) {
        try check()
        state.set(UserSession(userId: UUID(uuidString: "5a1e0000-0000-4000-8000-000000000001")!, email: nil, plan: plan))
    }

    public func signInWithEmail(_ email: String) async throws(APIError) {
        try check()
        state.set(UserSession(userId: UUID(uuidString: "5a1e0000-0000-4000-8000-000000000002")!, email: email, plan: plan))
    }

    public func signOut() async { state.set(nil) }

    public func deleteAccount() async throws(APIError) {
        try check()
        state.set(nil)
    }
}

// MARK: - HistoryService

public actor FakeHistoryService: HistoryService {
    public var nextError: APIError?
    private let past: [PastFlight]

    public init() {
        past = FakeSeed.load("past_flights", as: [PastFlight].self).sorted { $0.date > $1.date }
    }

    public func setNextError(_ error: APIError?) { nextError = error }

    private func check() throws(APIError) {
        if let e = nextError { nextError = nil; throw e }
    }

    public func pastFlights() async throws(APIError) -> [PastFlight] {
        try check()
        return past
    }

    public func export(_ format: ExportFormat) async throws(APIError) -> Data {
        try check()
        return try PastFlightExport.data(past, format: format)
    }
}

// MARK: - PushService

public actor FakePushService: PushService {
    public struct Registration: Sendable, Equatable {
        public var deviceToken: Data
        public var kind: PushTokenKind
        public var flightId: Flight.ID?
    }

    public var nextError: APIError?
    public private(set) var registrations: [Registration] = []

    public init() {}

    public func setNextError(_ error: APIError?) { nextError = error }

    public func register(deviceToken: Data, kind: PushTokenKind, flightId: Flight.ID?) async throws(APIError) {
        if let e = nextError { nextError = nil; throw e }
        registrations.append(Registration(deviceToken: deviceToken, kind: kind, flightId: flightId))
    }
}
