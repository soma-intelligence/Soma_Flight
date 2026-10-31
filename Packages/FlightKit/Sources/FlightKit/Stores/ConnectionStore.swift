import Foundation
import Observation

/// The Connection Assistant behind one flight sheet: the followed flights this one connects with (pairing
/// and verdicts in `ConnectionPairing` and `ConnectionAssistant`), kept fresh from both flights' live
/// updates, and the other direct flights offered when the flight is canceled or a connection is at risk.
/// Every failure leaves its part empty: the cards are extras, never an error banner.
@MainActor @Observable
public final class ConnectionStore {
    /// The connections the flight is part of: the one it arrives into first, then the one it leaves for.
    public private(set) var connections: [Connection] = []
    /// The other flights for `request`, in its window, by departure.
    public private(set) var alternates: [AlternateFlight] = []
    /// What the "Other flights" card is for; nil hides it.
    public private(set) var request: AlternateRequest?
    /// True once the alternates for `request` answered (an empty list then says so).
    public private(set) var alternatesLoaded = false
    /// The alternate being looked up and followed.
    public private(set) var pending: AlternateFlight.ID?
    /// Why the last follow did not work; cleared by the next try.
    public private(set) var followError: APIError?

    private let id: Flight.ID
    private let flights: any FlightService
    private let airports: (any AirportService)?
    private let service: any AlternateFlightsService
    private let directory: @Sendable (String) -> Airport?
    private let rules: ConnectionRules
    /// Airports the directory did not have, read from `airports` by `run`, by ICAO and IATA code.
    private var fetched: [String: Airport] = [:]

    /// - Parameters:
    ///   - airports: reads an airport the bundled directory lacks (its country and time zone); nil reads none.
    ///   - service: the other direct flights (paid data); the default asks nothing and shows none.
    ///   - lookup: an airport by ICAO or IATA code from the bundled directory.
    public init(id: Flight.ID, flights: any FlightService, airports: (any AirportService)? = nil,
                alternates service: any AlternateFlightsService = UnavailableAlternateFlightsService(),
                lookup: @escaping @Sendable (String) -> Airport? = { _ in nil }, rules: ConnectionRules = .bundled) {
        self.id = id; self.flights = flights; self.airports = airports; self.service = service
        self.directory = lookup; self.rules = rules
    }

    /// An airport by ICAO or IATA code: the bundled directory, else one `run` read. The cards read local
    /// times through it too.
    func lookup(_ code: String) -> Airport? { directory(code) ?? fetched[code.uppercased()] }

    /// The verdict, steps and figures of a connection, with the airports' countries from `lookup`. An
    /// airport nobody knows counts as international, the longer connection.
    public func assessment(_ c: Connection) -> ConnectionAssessment {
        ConnectionAssistant.assess(c, country: { self.lookup($0)?.country }, rules: rules)
    }

    /// Finds the connections among the followed flights, reads the airports they need that the directory
    /// lacks, then follows both flights of each until the task is cancelled, so the verdict moves with every
    /// new estimate. A failed read shows no connection.
    /// - Parameter flight: the sheet's flight, whose own airports a canceled flight's other flights need.
    public func run(flight: Flight? = nil) async {
        guard let all = try? await flights.followed(), !Task.isCancelled else { return }
        connections = ConnectionPairing.connections(for: id, in: all)
        var codes = Set(connections.flatMap { [$0.arriving.originIcao, $0.airport, $0.departing.destinationIcao] })
        if let flight { codes.formUnion([flight.originIcao, flight.destinationIcao]) }
        await resolve(codes)
        let ids = Set(connections.flatMap { [$0.arriving.id, $0.departing.id] })
        guard !ids.isEmpty, !Task.isCancelled else { return }
        for await f in flights.updates(for: ids.sorted { $0.uuidString < $1.uuidString }) {
            apply(f)
        }
    }

    /// Reads the airports of `codes` the directory lacks, one call each; a failure leaves that one unknown.
    private func resolve(_ codes: Set<String>) async {
        guard let airports else { return }
        let missing = codes.filter { lookup($0) == nil }.sorted()
        guard !missing.isEmpty else { return }
        let found = await withTaskGroup(of: Airport?.self) { group in
            for code in missing { group.addTask { try? await airports.airport(code) } }
            var out: [Airport] = []
            for await a in group { if let a { out.append(a) } }
            return out
        }
        for a in found {
            fetched[a.id] = a
            if let iata = a.iata { fetched[iata] = a }
        }
    }

    /// A fresher copy of either flight (a live update, or the sheet's own reload).
    public func apply(_ f: Flight) {
        guard connections.contains(where: { $0.arriving.id == f.id || $0.departing.id == f.id }) else { return }
        connections = connections.map { $0.updated(with: f) }
    }

    /// What the "Other flights" card should show for `flight` at `now` (`AlternateRequest.make`).
    public func alternateRequest(for flight: Flight, now: Date) -> AlternateRequest? {
        AlternateRequest.make(flight: flight, connections: connections.map { ($0, assessment($0)) }, now: now,
                              timeZone: { self.lookup($0)?.timeZone ?? .gmt })
    }

    /// Asks for the flights of `request` (none for nil). A newer request wins over an older answer; a
    /// failure shows the card empty rather than an error.
    public func loadAlternates(_ request: AlternateRequest?) async {
        if request != self.request { alternatesLoaded = false; alternates = [] }
        self.request = request
        guard let request else { return }
        let found: [AlternateFlight]
        do {
            found = try await service.alternates(origin: request.origin, destination: request.destination,
                                                 after: request.after)
        } catch {
            found = []
        }
        guard self.request == request, !Task.isCancelled else { return }
        alternates = request.filter(found)
        alternatesLoaded = true
    }

    /// Looks the alternate up by flight number and follows it with alerts on. Returns the followed flight,
    /// nil with `followError` set when the lookup finds no matching flight or the follow is refused.
    public func follow(_ alt: AlternateFlight) async -> Flight? {
        guard pending == nil else { return nil }
        pending = alt.id
        followError = nil
        defer { pending = nil }
        do {
            let found = try await flights.lookup(.ident(alt.ident, date: alt.scheduledOut))
            guard let f = Self.match(alt, in: found) else {
                followError = .notFound
                return nil
            }
            try await flights.follow(f.id, notify: true)
            return f
        } catch {
            followError = error
            return nil
        }
    }

    public func clearFollowError() { followError = nil }

    /// The lookup's flight that is this alternate: same number, same origin, the departure nearest the
    /// scheduled one and no more than 3 hours from it.
    nonisolated static func match(_ alt: AlternateFlight, in found: [Flight]) -> Flight? {
        let ident = alt.ident.uppercased().replacingOccurrences(of: " ", with: "")
        return found
            .filter { $0.ident.uppercased().replacingOccurrences(of: " ", with: "") == ident }
            .filter { $0.originIata == alt.originIata || $0.originIcao == alt.originIata }
            .compactMap { f in f.scheduledOut.map { (f, abs($0.timeIntervalSince(alt.scheduledOut))) } }
            .filter { $0.1 <= 3 * 3600 }
            .min { $0.1 < $1.1 }?.0
    }
}
