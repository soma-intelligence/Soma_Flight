import Foundation

/// An airline or airport the Add Flight sheet offers before anything is typed, with how many of the
/// user's flights it counts.
public enum FrequentItem: Identifiable, Hashable, Sendable {
    case airline(Airline, count: Int)
    case airport(Airport, count: Int)

    public var id: String {
        switch self {
        case .airline(let a, _): "airline:\(a.id)"
        case .airport(let a, _): "airport:\(a.id)"
        }
    }
}

/// Picks the frequently used airlines and airports from the past and followed flights.
public enum FrequentlyUsed {
    /// How many of each kind the sheet shows.
    public static let limit = 2

    /// The top two airlines, then the top two airports, by number of flights (a flight counts once for
    /// each of its airports). A tie goes to the one flown most recently, then to the lower code (ICAO).
    /// Canceled flights did not fly and are left out; a followed flight already in the history (same
    /// number, leaving within a day of it) counts once. Airlines the reference list does not know and
    /// airports `lookup` does not find are skipped.
    public static func compute(past: [PastFlight], followed: [Flight], reference: ReferenceData,
                               lookup: (String) -> Airport?) -> [FrequentItem] {
        var airlines: [String: Tally<Airline>] = [:]
        var airports: [String: Tally<Airport>] = [:]

        func count(airline: Airline?, airportCodes: [String], at date: Date) {
            if let airline { airlines[airline.id, default: Tally(item: airline)].add(date) }
            var seen: Set<String> = []
            for code in airportCodes {
                guard let airport = lookup(code), seen.insert(airport.id).inserted else { continue }
                airports[airport.id, default: Tally(item: airport)].add(date)
            }
        }

        let flown = past.filter { $0.status != .canceled }
        for f in flown {
            let airline = f.airline.flatMap { reference.airline($0) } ?? reference.airline(ident: f.ident)
            count(airline: airline, airportCodes: [f.originIcao, f.destinationIcao], at: f.date)
        }
        for f in followed where f.status != .canceled {
            let date = f.scheduledOut ?? f.estimatedOut ?? f.actualOut ?? f.scheduledIn ?? f.estimatedIn
            let ident = f.ident.uppercased()
            if let date, flown.contains(where: { $0.ident.uppercased() == ident && abs($0.date.timeIntervalSince(date)) < 86_400 }) {
                continue
            }
            let airline = f.operator.flatMap { reference.airline($0) } ?? reference.airline(ident: f.ident)
            count(airline: airline, airportCodes: [f.originIcao, f.destinationIcao], at: date ?? .distantPast)
        }

        let topAirlines = top(airlines).map { FrequentItem.airline($0.item, count: $0.count) }
        let topAirports = top(airports).map { FrequentItem.airport($0.item, count: $0.count) }
        return topAirlines + topAirports
    }

    private static func top<T>(_ tallies: [String: Tally<T>]) -> [Tally<T>] {
        tallies.sorted { a, b in
            if a.value.count != b.value.count { return a.value.count > b.value.count }
            if a.value.latest != b.value.latest { return a.value.latest > b.value.latest }
            return a.key < b.key
        }
        .prefix(limit)
        .map(\.value)
    }

    private struct Tally<T> {
        var item: T
        var count = 0
        var latest = Date.distantPast

        mutating func add(_ date: Date) {
            count += 1
            latest = max(latest, date)
        }
    }
}
