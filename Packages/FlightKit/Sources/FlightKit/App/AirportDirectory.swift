import Foundation

/// Every airport the app knows, by ICAO and by IATA, for the synchronous lookups the screens need
/// (far-end city names, local times, globe pins, search suggestions). Built once from the bundled reference list.
public struct AirportDirectory: Sendable {
    public let all: [Airport]
    private let byCode: [String: Airport]

    public init(_ airports: [Airport]) {
        all = airports.sorted { $0.id < $1.id }
        var map: [String: Airport] = [:]
        for a in all {
            map[a.id.uppercased()] = a
            if let iata = a.iata, map[iata.uppercased()] == nil { map[iata.uppercased()] = a }
        }
        byCode = map
    }

    /// The bundled list: every airport the backend seeds (Resources/Reference/airports.tsv, 3,975 of them,
    /// built by `Scripts/build_airport_directory.py` from the seed migration). Read once per process.
    public static func bundled() -> AirportDirectory { shared }

    private static let shared = AirportDirectory(readBundled())

    /// One line per airport, tab separated: ICAO, IATA, name, city, country, lat, lon, time zone. An
    /// empty field is a missing value; a line the app cannot read is left out.
    static func parse(_ text: String) -> [Airport] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 8, f[0].count == 4, let lat = Double(f[5]), let lon = Double(f[6]) else { return nil }
            return Airport(id: f[0], iata: f[1].isEmpty ? nil : f[1], name: f[2], city: f[3].isEmpty ? f[2] : f[3],
                           country: f[4], lat: lat, lon: lon, tz: f[7])
        }
    }

    private static func readBundled() -> [Airport] {
        guard let url = Bundle.module.url(forResource: "airports", withExtension: "tsv", subdirectory: "Reference")
                ?? Bundle.module.url(forResource: "airports", withExtension: "tsv"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            fatalError("Missing reference list airports.tsv")
        }
        return parse(text)
    }

    /// Airport by ICAO or IATA code, any case.
    public func airport(_ code: String) -> Airport? {
        byCode[code.trimmingCharacters(in: .whitespaces).uppercased()]
    }

    /// The lookup closure the screens take.
    public var lookup: @Sendable (String) -> Airport? {
        let me = self
        return { me.airport($0) }
    }
}
