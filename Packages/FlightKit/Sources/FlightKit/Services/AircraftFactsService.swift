import Foundation
import Supabase

/// What is known about one airframe: when it was delivered and the name painted on it, if any.
/// Ages on the Passport come from `deliveredOn`; an airframe without one has no age.
public struct AircraftFact: Codable, Sendable, Hashable {
    public var registration: String
    /// Delivery day (UTC midnight); nil when unknown.
    public var deliveredOn: Date?
    public var name: String?

    public init(registration: String, deliveredOn: Date? = nil, name: String? = nil) {
        self.registration = registration; self.deliveredOn = deliveredOn; self.name = name
    }

    private enum CodingKeys: String, CodingKey { case registration, deliveredOn = "delivered_on", name }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        registration = try c.decode(String.self, forKey: .registration)
        deliveredOn = try c.decodeIfPresent(String.self, forKey: .deliveredOn).flatMap(Self.day)
        name = try c.decodeIfPresent(String.self, forKey: .name).flatMap { $0.isEmpty ? nil : $0 }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(registration, forKey: .registration)
        try c.encodeIfPresent(deliveredOn.map(Self.dayString), forKey: .deliveredOn)
        try c.encodeIfPresent(name, forKey: .name)
    }

    /// "2018-09-20" (a Postgres `date`) at UTC midnight.
    static func day(_ s: String) -> Date? {
        let parts = s.prefix(10).split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .gmt
        return cal.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    static func dayString(_ d: Date) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .gmt
        let c = cal.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}

/// Airframe facts for the registrations the user flew. Never throws: without facts the Passport
/// hides ages and keeps everything else.
public protocol AircraftFactsService: Sendable {
    func facts(_ registrations: [String]) async -> [AircraftFact]
}

/// Facts from the seed (Resources/Fakes/aircraft_facts.json), covering every registration of the fake
/// history, delivered between 1994 and 2026.
public struct FakeAircraftFactsService: AircraftFactsService {
    private let all: [String: AircraftFact]

    public init() {
        // A plain decoder: the seed has the table's own column names, which the keys spell out.
        guard let url = Bundle.module.url(forResource: "aircraft_facts", withExtension: "json", subdirectory: "Fakes")
                ?? Bundle.module.url(forResource: "aircraft_facts", withExtension: "json"),
              let list = try? JSONDecoder().decode([AircraftFact].self, from: Data(contentsOf: url)) else {
            fatalError("Missing or bad fake seed aircraft_facts.json")
        }
        all = Dictionary(list.map { ($0.registration.uppercased(), $0) }, uniquingKeysWith: { a, _ in a })
    }

    public func facts(_ registrations: [String]) async -> [AircraftFact] {
        Array(Set(registrations.map { $0.uppercased() })).sorted().compactMap { all[$0] }
    }
}

/// Facts from the `aircraft` table (filled by the service role, readable by any signed-in user). The
/// table is empty today, so live builds show no ages yet.
public final class SupabaseAircraftFactsService: AircraftFactsService {
    private let backend: SupabaseBackend

    public init(backend: SupabaseBackend) { self.backend = backend }

    public func facts(_ registrations: [String]) async -> [AircraftFact] {
        let regs = Array(Set(registrations.filter { !$0.isEmpty })).sorted()
        guard !regs.isEmpty else { return [] }
        do {
            let data = try await backend.rows {
                $0.from("aircraft").select("registration, delivered_on, name").in("registration", values: regs)
            }
            return try JSONDecoder().decode([AircraftFact].self, from: data)
        } catch {
            SupabaseBackend.log.error("aircraft facts: \(String(describing: error), privacy: .public)")
            return []
        }
    }
}
