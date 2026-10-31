import Foundation

/// The security (TSA) wait at an airport, for the flight sheet's Good to Know row and the airport sheet's
/// Security section. Live builds use `SupabaseSecurityWaitService` (edge function `security-wait`, free:
/// no paid provider behind it); screenshot runs (`-useFakes`) use `FakeSecurityWaitService`.
public protocol SecurityWaitService: Sendable {
    /// The wait at `airport` (IATA or ICAO); nil where there is none to give (outside the US).
    func securityWait(airport: String) async throws(APIError) -> SecurityWait?
}

/// No wait anywhere, and no network call: the default for stores built without a service.
public struct UnavailableSecurityWaitService: SecurityWaitService {
    public init() {}
    public func securityWait(airport: String) async throws(APIError) -> SecurityWait? { nil }
}

/// Believable estimates for screenshot runs and tests. SFO, AUS and JFK get their real checkpoint names
/// with a busiest-hour wait each; any other US airport in the seed gets one "All checkpoints" row; the rest
/// none. The minutes follow the same typical US day as the backend's fallback (`security-wait/model.ts`)
/// at the airport's local hour, so a morning run shows the rush. Every answer is an estimate.
public actor FakeSecurityWaitService: SecurityWaitService {
    public var nextError: APIError?
    private let airports: [Airport]
    private let clock: @Sendable () -> Date

    /// - Parameter now: the clock the answers are for; the real time when nil.
    public init(now: Date? = nil) {
        airports = FakeSeed.load("airports")
        clock = { now ?? .now }
    }

    public func setNextError(_ error: APIError?) { nextError = error }

    /// One checkpoint: its id, name, terminal, PreCheck, and its standard wait at the busiest hour.
    struct Spec { var id, name: String; var terminal: String?; var precheck: Bool?; var peak: Int }

    static let checkpoints: [String: [Spec]] = [
        "KSFO": [
            Spec(id: "t1", name: "Harvey Milk Terminal 1", terminal: "1", precheck: true, peak: 30),
            Spec(id: "t2", name: "Terminal 2", terminal: "2", precheck: true, peak: 25),
            Spec(id: "t3-e", name: "Terminal 3 E", terminal: "3", precheck: false, peak: 20),
            Spec(id: "t3-f", name: "Terminal 3 F", terminal: "3", precheck: true, peak: 40),
            Spec(id: "intl-a", name: "International A", terminal: "International", precheck: true, peak: 35),
            Spec(id: "intl-g", name: "International G", terminal: "International", precheck: true, peak: 30),
        ],
        "KAUS": [
            Spec(id: "cp1", name: "Checkpoint 1", terminal: "Barbara Jordan", precheck: false, peak: 30),
            Spec(id: "cp2", name: "Checkpoint 2", terminal: "Barbara Jordan", precheck: true, peak: 40),
            Spec(id: "cp3", name: "Checkpoint 3", terminal: "Barbara Jordan", precheck: true, peak: 45),
        ],
        "KJFK": [
            Spec(id: "t1", name: "Terminal 1", terminal: "1", precheck: true, peak: 35),
            Spec(id: "t4", name: "Terminal 4", terminal: "4", precheck: true, peak: 45),
            Spec(id: "t5", name: "Terminal 5", terminal: "5", precheck: true, peak: 30),
            Spec(id: "t7", name: "Terminal 7", terminal: "7", precheck: true, peak: 25),
            Spec(id: "t8", name: "Terminal 8", terminal: "8", precheck: true, peak: 30),
        ],
    ]

    /// The typical US checkpoint by local hour (0 to 1) and weekday (Sunday first), as the backend's.
    static let hours: [Double] = [0.05, 0.03, 0.03, 0.08, 0.45, 0.9, 1.0, 0.85, 0.7, 0.6, 0.6, 0.62,
                                  0.65, 0.6, 0.62, 0.7, 0.72, 0.65, 0.55, 0.45, 0.35, 0.25, 0.15, 0.08]
    static let weekdays: [Double] = [1.0, 0.95, 0.8, 0.8, 0.95, 1.0, 0.8]

    /// How busy a checkpoint is at `date` on the airport's clock, 0 to 1.
    static func load(at date: Date, in tz: TimeZone) -> Double {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        let c = cal.dateComponents([.weekday, .hour], from: date)
        return hours[(c.hour ?? 12) % 24] * weekdays[((c.weekday ?? 1) - 1) % 7]
    }

    /// Minutes rounded to 5, never below 5, as the backend's estimates.
    static func rounded(_ m: Double) -> Int { max(5, Int((m / 5).rounded()) * 5) }

    /// The estimate at `airport` for `date`, or nil outside the US.
    static func wait(_ airport: Airport, at date: Date) -> SecurityWait? {
        guard airport.country == "US" else { return nil }
        let load = Self.load(at: date, in: airport.timeZone)
        let specs = checkpoints[airport.id]
            ?? [Spec(id: SecurityCheckpoint.allId, name: "All checkpoints", terminal: nil, precheck: nil, peak: 28)]
        let rows = specs.map { s in
            let standard = 4 + Double(s.peak - 4) * pow(load, 1.5)
            return SecurityCheckpoint(id: s.id, name: s.name, terminal: s.terminal, precheck: s.precheck,
                                      standardMinutes: rounded(standard),
                                      precheckMinutes: s.precheck == false ? nil : rounded(standard * 0.35))
        }
        let measured = checkpoints[airport.id] != nil
        return SecurityWait(airportIcao: airport.id, iata: airport.iata, isLive: false,
                            source: measured
                                ? .init(id: "estimate_tsa_throughput", name: "Estimate from TSA checkpoint traffic",
                                        url: URL(string: "https://www.tsa.gov/foia/readingroom"))
                                : .init(id: "estimate_typical_day", name: "Estimate from a typical day at US airports"),
                            fetchedAt: date, checkpoints: rows)
    }

    public func securityWait(airport: String) async throws(APIError) -> SecurityWait? {
        if let e = nextError { nextError = nil; throw e }
        let c = airport.uppercased()
        guard let a = airports.first(where: { $0.id == c || $0.iata == c }) else { throw .notFound }
        return Self.wait(a, at: clock())
    }
}
