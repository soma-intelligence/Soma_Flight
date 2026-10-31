import Foundation
import Observation
import FlightImportKit

/// Upcoming flights from an import that are too far ahead to look up yet (a lookup reaches two days
/// ahead): kept on this device, per account, and followed by `ImportFollower` once they come within
/// reach. Nothing is sent anywhere while they wait.
@MainActor @Observable
public final class FollowLaterQueue {
    public private(set) var items: [UpcomingFlight] = []
    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private var key: String

    static let keyPrefix = "imports.followLater"

    /// - Parameter defaults: where the list is kept; nil keeps it in memory (fakes, tests).
    public init(owner: UUID?, defaults: UserDefaults? = .standard) {
        self.defaults = defaults
        key = Self.key(owner)
        items = Self.read(defaults, key)
    }

    /// Switches to the list of the account signed in now.
    public func adopt(owner: UUID?) {
        let next = Self.key(owner)
        guard next != key else { return }
        key = next
        items = Self.read(defaults, key)
    }

    public func add(_ flights: [UpcomingFlight]) {
        for f in flights where !items.contains(where: { $0.id == f.id }) { items.append(f) }
        items.sort { $0.day < $1.day }
        save()
    }

    public func remove(_ id: UpcomingFlight.ID) {
        items.removeAll { $0.id == id }
        save()
    }

    private static func key(_ owner: UUID?) -> String {
        "\(keyPrefix).\(owner?.uuidString.lowercased() ?? "none")"
    }

    private static func read(_ defaults: UserDefaults?, _ key: String) -> [UpcomingFlight] {
        defaults?.data(forKey: key).flatMap { try? JSONDecoder().decode([UpcomingFlight].self, from: $0) } ?? []
    }

    private func save() {
        guard let defaults else { return }
        if items.isEmpty {
            defaults.removeObject(forKey: key)
        } else if let data = try? JSONEncoder().encode(items) {
            defaults.set(data, forKey: key)
        }
    }
}

/// Follows an imported upcoming flight: looks it up by number on its day, picks the one with its
/// airports and day, follows it and notes its seat and booking code. Too far ahead, it waits.
public enum ImportFollower {
    public enum Outcome: Sendable, Equatable {
        case followed(Flight)
        /// More than `reach` days ahead: kept to follow later.
        case later
        /// The lookup found no such flight.
        case notFound
        /// Its day has passed without it being followed.
        case gone
        /// The lookup or the follow failed (offline, a limit); worth another try.
        case failed(APIError)
    }

    /// How far ahead a lookup reaches (`flight-lookup`'s window).
    public static let reach = 2

    /// Days from today (the device's) to the flight's day.
    static func daysAhead(_ u: UpcomingFlight, now: Date, zone: TimeZone) -> Int {
        LocalDay(now, in: zone).days(to: u.day)
    }

    /// The flight `u` is among `found`: same airline (IATA or ICAO) and number, its day at the origin, and
    /// its airports when `u` names them.
    static func pick(_ u: UpcomingFlight, in found: [Flight], reference: ReferenceData,
                     airport: (String) -> Airport?) -> Flight? {
        let want = FlightImportPlan.followKey(u.ident, u.day, reference: reference)
        return found.first { f in
            guard let out = f.scheduledOut ?? f.estimatedOut ?? f.actualOut else { return false }
            let zone = airport(f.originIcao)?.timeZone ?? .gmt
            guard FlightImportPlan.followKey(f.ident, LocalDay(out, in: zone), reference: reference) == want else { return false }
            if let o = u.origin, !same(o, f.originIcao, f.originIata, airport) { return false }
            if let d = u.destination, !same(d, f.destinationIcao, f.destinationIata, airport) { return false }
            return true
        }
    }

    private static func same(_ code: String, _ icao: String, _ iata: String?, _ airport: (String) -> Airport?) -> Bool {
        let c = code.uppercased()
        return c == icao.uppercased() || c == iata?.uppercased() || airport(c)?.id == icao.uppercased()
    }

    /// Follows `u` when within reach, with alerts on, and fills its noted details.
    public static func follow(_ u: UpcomingFlight, flights: any FlightService, reference: ReferenceData,
                              airport: (String) -> Airport?, now: Date = .now, zone: TimeZone = .current) async -> Outcome {
        let ahead = daysAhead(u, now: now, zone: zone)
        if ahead > reach { return .later }
        if ahead < -1 { return .gone }
        let date = PastFlightRules.noon(year: u.day.year, month: u.day.month, day: u.day.day, in: zone) ?? now
        let found: [Flight]
        do {
            found = try await flights.lookup(.ident(u.ident, date: date))
        } catch {
            switch error {
            case .notFound: return .notFound
            // The window's edge falls on another day at the origin: try again tomorrow.
            case .outOfWindow: return .later
            default: return .failed(error)
            }
        }
        guard let flight = pick(u, in: found, reference: reference, airport: airport) else { return .notFound }
        do {
            try await flights.follow(flight.id, notify: true)
        } catch {
            return .failed(error)
        }
        if u.details != .empty, let normalized = u.details.normalized() {
            // A nicety: the follow stands if the details do not store.
            try? await flights.saveFollowDetails(flight.id, normalized)
        }
        return .followed(flight)
    }
}
