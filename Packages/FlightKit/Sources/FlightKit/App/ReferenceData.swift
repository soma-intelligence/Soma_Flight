import Foundation
import SwiftUI

/// The airlines, aircraft types and countries the app ships with (Resources/Reference), looked up
/// synchronously by the screens. Built once per process by `bundled()`.
public struct ReferenceData: Sendable {
    public let airlines: [Airline]
    public let types: [AircraftType]
    public let countries: [Country]
    private let airlineByCode: [String: Airline]
    private let airlineByName: [String: Airline]
    private let typeByCode: [String: AircraftType]
    private let countryByCode: [String: Country]

    public init(airlines: [Airline], types: [AircraftType], countries: [Country]) {
        self.airlines = airlines; self.types = types; self.countries = countries
        var codes: [String: Airline] = [:]
        // A code shared by two airlines resolves to the first in file order; the tests assert the bundled
        // list has no such code. ICAO first so a code that is one airline's ICAO and another's IATA reads as the ICAO.
        for a in airlines { codes[a.id.uppercased()] = a }
        for a in airlines { if let i = a.iata?.uppercased(), codes[i] == nil { codes[i] = a } }
        airlineByCode = codes
        var names: [String: Airline] = [:]
        for a in airlines { names[Self.nameKey(a.name, trimmed: false)] = a }
        for a in airlines { let k = Self.nameKey(a.name, trimmed: true); if names[k] == nil { names[k] = a } }
        airlineByName = names
        typeByCode = Dictionary(types.map { ($0.id.uppercased(), $0) }, uniquingKeysWith: { a, _ in a })
        countryByCode = Dictionary(countries.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    private static let sharedBundled = ReferenceData.load()

    /// The bundled lists, decoded once.
    public static func bundled() -> ReferenceData { sharedBundled }

    private static func load() -> ReferenceData {
        ReferenceData(airlines: read("airlines"), types: read("aircraft_types"), countries: read("countries"))
    }

    private static func read<T: Decodable>(_ name: String) -> [T] {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Reference")
                ?? Bundle.module.url(forResource: name, withExtension: "json") else {
            fatalError("Missing reference list \(name).json")
        }
        do { return try JSONDecoder().decode([T].self, from: Data(contentsOf: url)) }
        catch { fatalError("Bad reference list \(name).json: \(error)") }
    }

    /// Lower case, accents folded; with `trimmed` the generic tail ("Airlines", "Airways", "Air Lines")
    /// goes, so "United" finds "United Airlines".
    private static func nameKey(_ name: String, trimmed: Bool) -> String {
        var s = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed else { return s }
        for tail in [" air lines", " airlines", " airways", " airline"] where s.hasSuffix(tail) {
            s.removeLast(tail.count)
            break
        }
        return s
    }

    /// An airline by ICAO code, IATA code or name ("UAL", "UA", "United"), any case.
    public func airline(_ code: String) -> Airline? {
        let t = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        return airlineByCode[t.uppercased()] ?? airlineByName[Self.nameKey(t, trimmed: false)]
            ?? airlineByName[Self.nameKey(t, trimmed: true)]
    }

    /// The airline of a flight number: "UA990" gives United.
    public func airline(ident: String) -> Airline? {
        airline(TravelFacts.airlineCode(ident: ident))
    }

    /// An aircraft type by ICAO designator, any case.
    public func type(_ icao: String) -> AircraftType? {
        typeByCode[icao.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()]
    }

    /// How an airline paints its aircraft: the hand-tuned seed entry when there is one, else derived from
    /// its brand colours, else `.plain` for an airline the list does not know. Takes ICAO, IATA or name.
    public func livery(_ icao: String) -> Livery {
        let key = icao.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if let seeded = LiverySeed.all[key] { return seeded }
        guard let airline = airline(icao) else { return .plain }
        return LiverySeed.all[airline.id.uppercased()] ?? .derived(from: airline)
    }

    /// A country by ISO 3166-1 alpha-2 code, any case.
    public func country(_ iso2: String) -> Country? {
        countryByCode[iso2.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()]
    }
}

private struct ReferenceKey: EnvironmentKey {
    static var defaultValue: ReferenceData { .bundled() }
}

public extension EnvironmentValues {
    var reference: ReferenceData {
        get { self[ReferenceKey.self] }
        set { self[ReferenceKey.self] = newValue }
    }
}
