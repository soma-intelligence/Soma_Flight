import Foundation

/// The flight sheet's paid insights: the arrival forecast of a flight number and the flights the
/// aircraft flies before this one. Both come from AeroAPI, which costs money per call, so live builds use
/// `UnavailableInsightsService` (no calls, no sample data) until the owner approves the cost; screenshot
/// runs (`-useFakes`) use `FakeInsightsService`.
public protocol InsightsService: Sendable {
    /// nil when there is no forecast for the flight number.
    func arrivalForecast(ident: String) async throws(APIError) -> ArrivalForecast?
    /// The inbound legs, newest first; empty when unknown.
    func inbound(_ id: Flight.ID) async throws(APIError) -> [InboundLeg]
}

/// Live builds: nothing, and no network call.
public struct UnavailableInsightsService: InsightsService {
    public init() {}
    public func arrivalForecast(ident: String) async throws(APIError) -> ArrivalForecast? { nil }
    public func inbound(_ id: Flight.ID) async throws(APIError) -> [InboundLeg] { [] }
}

/// Deterministic sample insights for screenshot runs and tests: every figure comes from an FNV-1a hash
/// of the flight number, so a flight always shows the same forecast and chain.
public actor FakeInsightsService: InsightsService {
    public var nextError: APIError?
    private let flights: any FlightService

    /// - Parameter flights: where the inbound chain finds the flight it leads to.
    public init(flights: any FlightService) { self.flights = flights }

    public func setNextError(_ error: APIError?) { nextError = error }

    private func check() throws(APIError) {
        if let e = nextError { nextError = nil; throw e }
    }

    /// 64-bit FNV-1a over the UTF-8 bytes.
    static func fnv1a(_ text: String) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in text.utf8 { h = (h ^ UInt64(b)) &* 0x0000_0100_0000_01b3 }
        return h
    }

    /// The forecast for `ident`: 60 days, 20 to 40 flights observed, buckets from the hash.
    static func forecast(ident: String) -> ArrivalForecast {
        var h = fnv1a(ident.uppercased())
        func next(_ range: ClosedRange<Int>) -> Int {
            h = h &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return range.lowerBound + Int((h >> 33) % UInt64(range.count))
        }
        let observed = next(20...40)
        let weights: [ForecastBucket: Int] = [
            .early: next(15...35), .onTime: next(20...40), .late15: next(5...15), .late30: next(3...10),
            .late45: next(2...10), .canceled: next(0...3), .diverted: next(0...2),
        ]
        let percents = percentages(weights)
        let late = percents[.late15, default: 0] + percents[.late30, default: 0] + percents[.late45, default: 0]
        return ArrivalForecast(ident: ident, days: 60, observed: observed, latePercent: late,
                               averageLateMinutes: next(18...55), percents: percents)
    }

    /// Whole percents that add up to exactly 100 (largest remainder).
    static func percentages(_ weights: [ForecastBucket: Int]) -> [ForecastBucket: Int] {
        let total = weights.values.reduce(0, +)
        guard total > 0 else { return Dictionary(uniqueKeysWithValues: ForecastBucket.allCases.map { ($0, 0) }) }
        var out: [ForecastBucket: Int] = [:]
        var rest: [(ForecastBucket, Int)] = []
        for b in ForecastBucket.allCases {
            let w = weights[b, default: 0] * 100
            out[b] = w / total
            rest.append((b, w % total))
        }
        var missing = 100 - out.values.reduce(0, +)
        for (b, _) in rest.sorted(by: { $0.1 > $1.1 }) where missing > 0 {
            out[b, default: 0] += 1
            missing -= 1
        }
        return out
    }

    static let hubs = ["JFK", "ORD", "DEN", "LAX", "SEA", "BOS", "IAD", "MIA", "ATL", "LHR", "AMS", "FRA", "MAD", "NRT"]

    /// Two legs ending at the flight's origin, newest first, the aircraft turning 90 minutes before
    /// each departure.
    static func chain(for f: Flight) -> [InboundLeg] {
        let h = fnv1a(f.ident.uppercased())
        let origin = f.originIata ?? f.originIcao
        let pool = hubs.filter { $0 != origin && $0 != (f.destinationIata ?? f.destinationIcao) }
        let a = pool[Int(h % UInt64(pool.count))]
        let b = pool.filter { $0 != a }[Int((h >> 8) % UInt64(pool.count - 1))]
        guard let out = f.scheduledOut else { return [] }
        let firstIn = out.addingTimeInterval(-90 * 60)
        let firstOut = firstIn.addingTimeInterval(-Double(180 + Int((h >> 16) % 240)) * 60)
        let secondIn = firstOut.addingTimeInterval(-90 * 60)
        let secondOut = secondIn.addingTimeInterval(-Double(120 + Int((h >> 24) % 180)) * 60)
        let code = TravelFacts.airlineCode(ident: f.ident)
        return [
            InboundLeg(id: "\(f.id)-1", ident: "\(code)\(100 + Int((h >> 32) % 800))", originIata: a,
                       destinationIata: origin, scheduledOut: firstOut, scheduledIn: firstIn, status: .arrived,
                       delayMinutes: Int((h >> 40) % 35)),
            InboundLeg(id: "\(f.id)-2", ident: "\(code)\(100 + Int((h >> 44) % 800))", originIata: b,
                       destinationIata: a, scheduledOut: secondOut, scheduledIn: secondIn, status: .arrived,
                       delayMinutes: Int((h >> 52) % 20)),
        ]
    }

    public func arrivalForecast(ident: String) async throws(APIError) -> ArrivalForecast? {
        try check()
        return Self.forecast(ident: ident)
    }

    public func inbound(_ id: Flight.ID) async throws(APIError) -> [InboundLeg] {
        try check()
        let f = try await flights.flight(id)
        return Self.chain(for: f)
    }
}
