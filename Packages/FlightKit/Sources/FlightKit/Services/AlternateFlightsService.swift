import CoreLocation
import Foundation

/// Direct flights on a route, for the "Other flights" card of a canceled flight or a connection at risk.
/// They come from AeroAPI's schedules, which cost money per call: live builds use
/// `SupabaseAlternateFlightsService` (edge function `alternate-flights`, cached 30 minutes and under the
/// backend's daily spend cap) when Info.plist turns the paid sections on (`INSIGHTS_ENABLED`), else
/// `UnavailableAlternateFlightsService` (no calls); screenshot runs (`-useFakes`) use
/// `FakeAlternateFlightsService`.
public protocol AlternateFlightsService: Sendable {
    /// Direct flights from `origin` to `destination` (ICAO) leaving from `after` on, for about 18 hours,
    /// by departure. Empty when the schedules list none.
    func alternates(origin: String, destination: String, after: Date) async throws(APIError) -> [AlternateFlight]
}

/// Live builds with the paid sections off: nothing, and no network call.
public struct UnavailableAlternateFlightsService: AlternateFlightsService {
    public init() {}
    public func alternates(origin: String, destination: String, after: Date) async throws(APIError) -> [AlternateFlight] {
        []
    }
}

/// Believable schedules for screenshot runs and tests: four flights spread over the hours after `after`,
/// airlines and minutes from an FNV-1a hash of the route, so a route always shows the same list. Each one is
/// also put in the fake flight service, so tapping it finds and follows it as a real lookup would.
public actor FakeAlternateFlightsService: AlternateFlightsService {
    public var nextError: APIError?
    private let flights: FakeFlightService?
    private let airports: [String: Airport]

    /// - Parameter flights: where the listed flights are registered for a later lookup; nil registers none.
    public init(flights: FakeFlightService? = nil) {
        self.flights = flights
        let list: [Airport] = FakeSeed.load("airports")
        var byCode: [String: Airport] = [:]
        for a in list {
            byCode[a.id] = a
            if let iata = a.iata { byCode[iata] = a }
        }
        airports = byCode
    }

    public func setNextError(_ error: APIError?) { nextError = error }

    static let carriers = ["UA", "AS", "DL", "AA", "B6", "AF"]

    /// The four flights for a route from `after`, as the fake answers them.
    static func schedule(origin: String, destination: String, after: Date, originAirport: Airport?,
                         destinationAirport: Airport?) -> [AlternateFlight] {
        var h = FakeInsightsService.fnv1a("\(origin)-\(destination)")
        func next(_ range: ClosedRange<Int>) -> Int {
            h = h &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return range.lowerBound + Int((h >> 33) % UInt64(range.count))
        }
        let blockMinutes: Int = {
            guard let o = originAirport, let d = destinationAirport else { return 120 }
            let km = distanceKm(CLLocationCoordinate2D(latitude: o.lat, longitude: o.lon),
                                CLLocationCoordinate2D(latitude: d.lat, longitude: d.lon))
            return max(45, Int(km / 800 * 60) + 30)
        }()
        let originCode = originAirport?.iata ?? origin
        let destinationCode = destinationAirport?.iata ?? destination
        // Departures on the next quarter hour after `after`, then every 1 to 3 hours.
        let quarter: TimeInterval = 15 * 60
        var out = Date(timeIntervalSince1970: (after.timeIntervalSince1970 / quarter).rounded(.up) * quarter)
            .addingTimeInterval(TimeInterval(next(2...5)) * quarter)
        var list: [AlternateFlight] = []
        for i in 0..<4 {
            let carrier = carriers[next(0...(carriers.count - 1))]
            let ident = "\(carrier)\(next(100...2999))"
            let late = i == 1 ? TimeInterval(next(2...4) * 10 * 60) : 0
            let arrive = out.addingTimeInterval(TimeInterval(blockMinutes * 60))
            list.append(AlternateFlight(
                id: "\(ident)-\(Int(out.timeIntervalSince1970))-fake", ident: ident,
                originIata: originCode, destinationIata: destinationCode, scheduledOut: out, scheduledIn: arrive,
                estimatedOut: late > 0 ? out.addingTimeInterval(late) : nil,
                estimatedIn: late > 0 ? arrive.addingTimeInterval(late) : nil,
                status: .scheduled, aircraftType: ["B738", "A320", "B39M", "A21N"][next(0...3)]))
            out = out.addingTimeInterval(TimeInterval(next(4...12)) * quarter)
        }
        return list
    }

    /// The flight a lookup of `alt` finds.
    static func flight(_ alt: AlternateFlight, origin: Airport?, destination: Airport?) -> Flight {
        let hash = FakeInsightsService.fnv1a(alt.id)
        let id = UUID(uuid: withUnsafeBytes(of: (hash, hash.byteSwapped)) { raw in
            var b = [UInt8](raw)
            b[6] = (b[6] & 0x0F) | 0x40
            b[8] = (b[8] & 0x3F) | 0x80
            return (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15])
        })
        return Flight(id: id, providerId: alt.id, ident: alt.ident,
                      originIcao: origin?.id ?? alt.originIata, originIata: alt.originIata,
                      destinationIcao: destination?.id ?? alt.destinationIata, destinationIata: alt.destinationIata,
                      scheduledOut: alt.scheduledOut, scheduledIn: alt.scheduledIn,
                      estimatedOut: alt.estimatedOut, estimatedIn: alt.estimatedIn,
                      aircraftType: alt.aircraftType, status: alt.status, updatedAt: alt.scheduledOut.addingTimeInterval(-3 * 3600))
    }

    public func alternates(origin: String, destination: String, after: Date) async throws(APIError) -> [AlternateFlight] {
        if let e = nextError { nextError = nil; throw e }
        let o = airports[origin.uppercased()], d = airports[destination.uppercased()]
        let list = Self.schedule(origin: origin, destination: destination, after: after, originAirport: o,
                                 destinationAirport: d)
        if let flights {
            for alt in list { await flights.push(Self.flight(alt, origin: o, destination: d)) }
        }
        return list
    }
}

extension AppEnvironment {
    /// The same environment with `service` for the Connection Assistant's other flights.
    func withAlternates(_ service: any AlternateFlightsService) -> AppEnvironment {
        var env = self
        env.alternates = service
        return env
    }

    #if DEBUG
    /// Screenshot runs (`-fakeConnection`): follows a made-up UA 1958 from SFO two hours after AF 84 is due
    /// there, so AF 84 and UA 1958 show a (tight) Connection card. Off by default: the seed's list stays as
    /// the other screenshots and tests know it.
    func addFakeConnection() async {
        guard let fake = flights as? FakeFlightService,
              let af84 = try? await fake.followed().first(where: { $0.ident == "AF84" }),
              let landing = af84.scheduledIn else { return }
        let out = landing.addingTimeInterval(2 * 3600)
        let onward = Flight(id: UUID(uuidString: "6f1c7d7e-0000-4000-8000-000000001958")!,
                            providerId: "UAL1958-fake-connection", ident: "UA1958", operator: "UAL",
                            originIcao: "KSFO", originIata: "SFO", destinationIcao: "KORD", destinationIata: "ORD",
                            scheduledOut: out, scheduledIn: out.addingTimeInterval(4 * 3600 + 15 * 60),
                            estimatedOut: out, estimatedIn: out.addingTimeInterval(4 * 3600 + 15 * 60),
                            gateOrigin: "F3", terminalOrigin: "3", aircraftType: "B39M",
                            status: .scheduled, updatedAt: af84.updatedAt)
        await fake.push(onward)
        try? await fake.follow(onward.id, notify: true)
    }
    #endif
}
