import Foundation
import Supabase
import Synchronization

/// Flights from the backend: `flight-lookup` and `airport-board` for search, `follow-flight` to follow,
/// the `flights`, `flight_events` and `user_flights` tables to read, Realtime on `flights` for updates.
///
/// Board rows and real flights carry different ids. A board row's `id` is a UUID v5 of its
/// `provider_id` (boards are not stored in `flights`), while `follow-flight` needs a `flights.id`. This
/// service is where the two meet: every board row it hands out is remembered, and `follow(_:notify:)`
/// on one of those ids first resolves the `flights` row with the same `provider_id` (the table, else a
/// `flight-lookup` of the row's ident and day) and follows that row. See `resolve(_:)`.
public final class SupabaseFlightService: FlightService {
    private let backend: SupabaseBackend
    private let airport: @Sendable (String) -> Airport?
    private let timeZone: @Sendable () -> TimeZone
    /// Board rows handed out by airport searches, by their v5 id.
    private let boardRows = Mutex<[UUID: Flight]>([:])
    /// Board row id to the `flights.id` it resolved to.
    private let resolved = Mutex<[UUID: UUID]>([:])

    /// - Parameters:
    ///   - airport: the bundled directory (ICAO or IATA), for an origin's time zone.
    ///   - timeZone: the calendar search days are picked in.
    public init(backend: SupabaseBackend, airport: @escaping @Sendable (String) -> Airport?,
                timeZone: @escaping @Sendable () -> TimeZone = { .current }) {
        self.backend = backend; self.airport = airport; self.timeZone = timeZone
    }

    private struct FlightsAnswer: Decodable { var flights: [Lossy<Flight>] }

    /// The flights of a `flight-lookup` answer. A row the app cannot read is logged and left out, so
    /// one bad row never fails the whole search.
    static func decodeLookup(_ data: Data) throws -> [Flight] {
        try FlightJSON.decoder.decode(FlightsAnswer.self, from: data).flights.compactMap(\.value)
    }

    // MARK: Search

    public func lookup(_ query: FlightQuery) async throws(APIError) -> [Flight] {
        if case .airport(let code) = query { return try await airportFlights(code) }
        guard let body = SupabaseBackend.lookupBody(for: query, timeZone: timeZone()) else { throw .notFound }
        let found = try await backend.call("flight-lookup", body: body, decode: Self.decodeLookup)
        guard !found.isEmpty else { throw .notFound }
        return found
    }

    /// An airport's flights today: its departures and arrivals boards, merged.
    private func airportFlights(_ code: String) async throws(APIError) -> [Flight] {
        let boards = SupabaseAirportService(backend: backend, airport: airport)
        async let dep = Self.capture { () async throws(APIError) in try await boards.board(code, .departures) }
        async let arr = Self.capture { () async throws(APIError) in try await boards.board(code, .arrivals) }
        let results = await [dep, arr]
        var rows: [UUID: Flight] = [:]
        var firstError: APIError?
        for r in results {
            switch r {
            case .success(let b): for f in b.flights { rows[f.id] = f }
            case .failure(let e): firstError = firstError ?? e
            }
        }
        if rows.isEmpty, let firstError { throw firstError }
        guard !rows.isEmpty else { throw .notFound }
        boardRows.withLock { $0.merge(rows) { $1 } }
        return rows.values.sorted { ($0.scheduledOut ?? .distantFuture, $0.id.uuidString) < ($1.scheduledOut ?? .distantFuture, $1.id.uuidString) }
    }

    private static func capture<T: Sendable>(_ body: @Sendable () async throws(APIError) -> T) async -> Result<T, APIError> {
        do { return .success(try await body()) } catch { return .failure(error) }
    }

    // MARK: Board row to flights row

    /// The `flights.id` to use for `id`: itself unless it is a board row's v5 id, which resolves to the
    /// `flights` row with the same `provider_id`.
    func resolve(_ id: Flight.ID) async throws(APIError) -> Flight.ID {
        if let known = resolved.withLock({ $0[id] }) { return known }
        guard let row = boardRows.withLock({ $0[id] }) else { return id }
        let real = try await flightsRow(for: row)
        resolved.withLock { $0[id] = real.id }
        return real.id
    }

    /// The table first (someone may have looked it up already, free); else `flight-lookup` of the row's
    /// ident on its origin's local day, which stores it, keeping the result with the same `provider_id`.
    private func flightsRow(for row: Flight) async throws(APIError) -> Flight {
        let pid = row.providerId
        let data = try await backend.rows { $0.from("flights").select().eq("provider_id", value: pid).limit(1) }
        if let stored = try decodeFlights(data).first { return stored }
        guard let out = row.scheduledOut else { throw .notFound }
        let tz = airport(row.originIcao)?.timeZone ?? .gmt
        let body = SupabaseBackend.json(["ident": row.ident, "date": SupabaseBackend.day(out, in: tz)])
        let found = try await backend.call("flight-lookup", body: body, decode: Self.decodeLookup)
        guard let match = found.first(where: { $0.providerId == pid }) else { throw .notFound }
        return match
    }

    // MARK: Following

    /// `user_flights` rows with their flight (RLS keeps them to the signed-in user). A flight the app
    /// cannot read is logged and left out rather than failing the list.
    struct FollowRow: Decodable {
        var flights: Flight?
        private enum CodingKeys: String, CodingKey { case flights }
        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            flights = try c.decodeIfPresent(Lossy<Flight>.self, forKey: .flights)?.value
        }
    }

    static func decodeFollowed(_ data: Data) throws -> [Flight] {
        try FlightJSON.decoder.decode([FollowRow].self, from: data).compactMap(\.flights)
    }

    public func followed() async throws(APIError) -> [Flight] {
        let data = try await backend.rows { $0.from("user_flights").select("created_at, flights(*)").order("created_at") }
        do { return try Self.decodeFollowed(data) } catch { throw SupabaseBackend.map(error) }
    }

    public func follow(_ id: Flight.ID, notify: Bool) async throws(APIError) {
        let real = try await resolve(id)
        try await backend.call("follow-flight", body: SupabaseBackend.json(["flightId": real.uuidString.lowercased(), "notify": notify]))
    }

    public func unfollow(_ id: Flight.ID) async throws(APIError) {
        let real = try await resolve(id)
        try await backend.call("follow-flight", method: .delete, body: SupabaseBackend.json(["flightId": real.uuidString.lowercased()]))
    }

    private struct NotifyRow: Decodable { var notify: Bool }

    public func notifies(_ id: Flight.ID) async throws(APIError) -> Bool? {
        let real = try await resolve(id)
        let data = try await backend.rows {
            $0.from("user_flights").select("notify").eq("flight_id", value: real.uuidString.lowercased()).limit(1)
        }
        do { return try FlightJSON.decoder.decode([NotifyRow].self, from: data).first?.notify } catch { throw SupabaseBackend.map(error) }
    }

    // MARK: Follow details

    private struct DetailsRow: Decodable {
        var seatClass: SeatClass?
        var seat: String?
        var reason: TripReason?
        var bookingCode: String?
        var notes: String?
    }

    /// The five writable columns; every one is sent, null included, so a cleared field clears the column.
    private struct DetailsPatch: Encodable, Sendable {
        var details: FollowDetails
        private enum CodingKeys: String, CodingKey { case seatClass = "seat_class", seat, reason, bookingCode = "booking_code", notes }
        func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(details.seatClass, forKey: .seatClass)
            try c.encode(details.seat, forKey: .seat)
            try c.encode(details.reason, forKey: .reason)
            try c.encode(details.bookingCode, forKey: .bookingCode)
            try c.encode(details.notes, forKey: .notes)
        }
    }

    static func decodeDetails(_ data: Data) throws -> FollowDetails? {
        try FlightJSON.decoder.decode([DetailsRow].self, from: data).first.map {
            FollowDetails(seatClass: $0.seatClass, seat: $0.seat, reason: $0.reason, bookingCode: $0.bookingCode, notes: $0.notes)
        }
    }

    public func followDetails(_ id: Flight.ID) async throws(APIError) -> FollowDetails? {
        let real = try await resolve(id)
        let data = try await backend.rows {
            $0.from("user_flights").select("seat_class, seat, reason, booking_code, notes")
                .eq("flight_id", value: real.uuidString.lowercased()).limit(1)
        }
        do { return try Self.decodeDetails(data) } catch { throw SupabaseBackend.map(error) }
    }

    public func saveFollowDetails(_ id: Flight.ID, _ details: FollowDetails) async throws(APIError) {
        let real = try await resolve(id)
        let patch = DetailsPatch(details: details)
        try await backend.write {
            try $0.from("user_flights").update(patch).eq("flight_id", value: real.uuidString.lowercased())
        }
    }

    // MARK: One flight

    public func flight(_ id: Flight.ID) async throws(APIError) -> Flight {
        let real = try await resolve(id)
        let data = try await backend.rows { $0.from("flights").select().eq("id", value: real.uuidString.lowercased()).limit(1) }
        guard let f = try decodeFlights(data).first else { throw .notFound }
        return f
    }

    private struct PositionAnswer: Decodable { var flight: Flight }

    static func decodePosition(_ data: Data) throws -> Flight {
        try FlightJSON.decoder.decode(PositionAnswer.self, from: data).flight
    }

    public func refreshPosition(_ id: Flight.ID) async throws(APIError) -> Flight? {
        let real = try await resolve(id)
        return try await backend.call("flight-position",
                                      body: SupabaseBackend.json(["flightId": real.uuidString.lowercased()]),
                                      decode: Self.decodePosition)
    }

    public func events(_ id: Flight.ID) async throws(APIError) -> [FlightEvent] {
        let real = try await resolve(id)
        let data = try await backend.rows {
            $0.from("flight_events").select().eq("flight_id", value: real.uuidString.lowercased()).order("received_at")
        }
        do { return try FlightJSON.decoder.decode([FlightEvent].self, from: data) } catch { throw SupabaseBackend.map(error) }
    }

    private func decodeFlights(_ data: Data) throws(APIError) -> [Flight] {
        do { return try FlightJSON.decoder.decode([Flight].self, from: data) } catch { throw SupabaseBackend.map(error) }
    }

    func flights(_ ids: [Flight.ID]) async throws(APIError) -> [Flight] {
        let values = ids.map { $0.uuidString.lowercased() }
        let data = try await backend.rows { $0.from("flights").select().in("id", values: values) }
        return try decodeFlights(data)
    }

    // MARK: Live updates

    /// Waits before subscribing again after a channel closes or fails to join.
    static let resubscribeDelays: [Duration] = [.seconds(1), .seconds(2), .seconds(5), .seconds(15), .seconds(30)]

    /// Realtime accepts at most 100 values in an `in` filter (a longer one fails to join, forever).
    static let maxIdsPerChannel = 100

    /// The ids split into channel-sized groups, in order.
    static func channelGroups(_ ids: [Flight.ID], size: Int = maxIdsPerChannel) -> [[Flight.ID]] {
        stride(from: 0, to: ids.count, by: size).map { Array(ids[$0..<min($0 + size, ids.count)]) }
    }

    /// `postgres_changes` UPDATEs on `flights` filtered by `id=in.(...)`, one channel per 100 ids, all
    /// merged into one stream. Each time a channel joins (the first time, and again after a dropped
    /// connection) its flights are read once, so a change made while the socket was down is not lost. A
    /// channel that closes is replaced by a new one. Ending the stream (the consumer stops iterating)
    /// removes the channels.
    public func updates(for ids: [Flight.ID]) -> AsyncStream<Flight> {
        let groups = Self.channelGroups(Array(Set(ids)).sorted { $0.uuidString < $1.uuidString })
        let (stream, continuation) = AsyncStream<Flight>.makeStream(bufferingPolicy: .bufferingNewest(64))
        guard !groups.isEmpty else { continuation.finish(); return stream }
        let task = Task { [backend] in
            await withTaskGroup(of: Void.self) { tasks in
                for group in groups {
                    tasks.addTask {
                        await Self.run(ids: group, backend: backend,
                                       refetch: { () async throws(APIError) in try await self.flights(group) },
                                       yield: { continuation.yield($0) })
                    }
                }
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    /// Waits between tries of the read that follows a join.
    static let refetchDelays: [Duration] = [.seconds(2), .seconds(5), .seconds(15)]

    /// The read after a join, tried again a few times: it covers what changed while the channel was down.
    private static func refetchOnJoin(_ refetch: @Sendable () async throws(APIError) -> [Flight],
                                      yield: @Sendable (Flight) -> Void) async {
        for attempt in 0...refetchDelays.count {
            if Task.isCancelled { return }
            do {
                for f in try await refetch() { yield(f) }
                return
            } catch {
                SupabaseBackend.log.error("flights read after join failed (try \(attempt + 1)): \(String(describing: error), privacy: .public)")
                guard attempt < refetchDelays.count else { return }
                try? await Task.sleep(for: refetchDelays[attempt])
            }
        }
    }

    private static func run(ids: [Flight.ID], backend: SupabaseBackend,
                            refetch: @escaping @Sendable () async throws(APIError) -> [Flight],
                            yield: @escaping @Sendable (Flight) -> Void) async {
        let client = backend.client
        var failures = 0
        while !Task.isCancelled {
            let channel = client.channel("flights-\(UUID().uuidString.lowercased())")
            let changes = channel.postgresChange(UpdateAction.self, schema: "public", table: "flights",
                                                 filter: .in("id", values: ids.map { $0.uuidString.lowercased() }))
            do {
                try await channel.subscribeWithError()
                failures = 0
                await withTaskGroup(of: Void.self) { group in
                    group.addTask {
                        for await change in changes {
                            do { yield(try change.decodeRecord(as: Flight.self, decoder: FlightJSON.decoder)) } catch {
                                SupabaseBackend.log.error("flights change not decoded: \(String(describing: error), privacy: .public)")
                            }
                        }
                    }
                    group.addTask {
                        // Every join, the first and each rejoin after a reconnect, reads the flights once.
                        // The loop ends when the channel closes for good.
                        for await status in channel.statusChange {
                            switch status {
                            case .subscribed:
                                await refetchOnJoin(refetch, yield: yield)
                            case .unsubscribed:
                                return
                            case .subscribing, .unsubscribing:
                                break
                            }
                        }
                    }
                    await group.next()
                    group.cancelAll()
                }
            } catch {
                failures += 1
                SupabaseBackend.log.error("flights channel did not join: \(String(describing: error), privacy: .public)")
            }
            await client.removeChannel(channel)
            guard !Task.isCancelled else { return }
            let delay = resubscribeDelays[min(failures, resubscribeDelays.count - 1)]
            try? await Task.sleep(for: delay)
        }
    }
}

/// One element of a list, or nothing when it does not decode: the failure is logged and the list goes on.
struct Lossy<T: Decodable>: Decodable {
    let value: T?

    init(from decoder: any Decoder) throws {
        do {
            value = try T(from: decoder)
        } catch {
            SupabaseBackend.log.error("\(String(describing: T.self), privacy: .public) row left out, not decoded: \(String(describing: error), privacy: .public)")
            value = nil
        }
    }
}
