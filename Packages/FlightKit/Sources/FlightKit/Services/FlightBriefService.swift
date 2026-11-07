import Foundation

/// The language-model texts of the flight sheet (door to door, why it is late) and the airport screen
/// (a summary). Each is written from facts the app sends and checked by the backend (`flight-brief`): it
/// may only use those facts and their numbers. Costs money per new text, so it ships off: live builds use
/// `SupabaseFlightBriefService` only when Info.plist turns it on (`LLM_ENABLED`, NO everywhere until the
/// owner approves the cost), else `UnavailableFlightBriefService` (no calls, sections hidden); screenshot
/// runs (`-useFakes`) use `FakeFlightBriefService`.
public protocol FlightBriefService: Sendable {
    /// False hides every brief section and makes no call.
    var isAvailable: Bool { get }
    /// The text for `facts`, nil when there is none to show. `subject` is the flight id (lower case UUID) for
    /// the flight kinds, the airport code for `airportSummary`.
    func brief(_ kind: BriefKind, subject: String, facts: [BriefFact]) async throws(APIError) -> FlightBrief?
}

/// Live builds with the feature off: nothing, and no network call.
public struct UnavailableFlightBriefService: FlightBriefService {
    public init() {}
    public var isAvailable: Bool { false }
    public func brief(_ kind: BriefKind, subject: String, facts: [BriefFact]) async throws(APIError) -> FlightBrief? { nil }
}

/// Deterministic sample texts for screenshot runs and tests: each is phrased from the facts it is given,
/// the way the backend's model may, and never says more than they do.
public actor FakeFlightBriefService: FlightBriefService {
    public var nextError: APIError?
    public private(set) var calls = 0
    private let now: Date

    public init(now: Date = .now) { self.now = now }

    public nonisolated var isAvailable: Bool { true }

    public func setNextError(_ error: APIError?) { nextError = error }

    public func brief(_ kind: BriefKind, subject: String, facts: [BriefFact]) async throws(APIError) -> FlightBrief? {
        calls += 1
        if let e = nextError { nextError = nil; throw e }
        let values = Dictionary(facts.map { ($0.id, $0.value) }, uniquingKeysWith: { a, _ in a })
        let text = Self.phrase(kind, values)
        guard !text.isEmpty else { return nil }
        return FlightBrief(kind: kind, text: text, factsUsed: facts.map(\.id).sorted(), generatedAt: now)
    }

    private static func string(_ v: [String: BriefValue], _ id: String) -> String? {
        if case .text(let s) = v[id] { return s }
        return nil
    }

    private static func int(_ v: [String: BriefValue], _ id: String) -> Int? {
        if case .int(let n) = v[id] { return n }
        return nil
    }

    static func phrase(_ kind: BriefKind, _ v: [String: BriefValue]) -> String {
        var s: [String] = []
        switch kind {
        case .doorToDoor:
            if let t = string(v, "leave_by_local") { s.append("Leave by \(t).") }
            if let m = int(v, "drive_minutes") { s.append("The drive is about \(m) minutes.") }
            if let m = int(v, "bag_drop_minutes") { s.append("Allow \(m) minutes for bag drop.") }
            if let m = int(v, "security_wait_minutes") { s.append("Security is about \(m) minutes.") }
            if let m = int(v, "walk_minutes") {
                s.append(string(v, "gate").map { "The walk to gate \($0) is about \(m) minutes." }
                    ?? "The walk to the gate is about \(m) minutes.")
            }
            if let t = string(v, "boarding_local") { s.append("Boarding starts at \(t).") }
        case .delayCause:
            if let m = int(v, "inbound_late_minutes") { s.append("The plane for this flight is arriving \(m) minutes late.") }
            if let c = string(v, "origin_weather_category") { s.append("Weather at the departure airport is \(c).") }
            if let c = string(v, "destination_weather_category") { s.append("Weather at the arrival airport is \(c).") }
            if let p = string(v, "origin_faa_program") { s.append("The FAA reports: \(p).") }
            if let p = string(v, "destination_faa_program") { s.append("The FAA reports: \(p).") }
            if let n = int(v, "gate_changes") { s.append("The gate changed \(n) times.") }
        case .airportSummary:
            if let c = string(v, "weather_category") { s.append("Conditions are \(c).") }
            if let m = int(v, "departures_delay_minutes") { s.append("Departures are about \(m) minutes late on average.") }
            if let m = int(v, "arrivals_delay_minutes") { s.append("Arrivals are about \(m) minutes late on average.") }
            if let p = string(v, "faa_program") { s.append("The FAA reports: \(p).") }
            if let m = int(v, "security_wait_minutes") { s.append("Security is about \(m) minutes.") }
        }
        return s.joined(separator: " ")
    }
}
