import Foundation

/// Static facts about a country for the destination card, from `Resources/Reference/destinations.json`:
/// plug types, mains voltage, currency and the usual tipping custom. Countries whose values are not
/// certain are left out of the file, so the card simply does not show for them.
public struct DestinationFacts: Decodable, Sendable, Hashable, Identifiable {
    /// The usual tip in a restaurant, as a broad custom.
    public enum Tipping: String, Decodable, Sendable {
        case none
        case roundUp = "round_up"
        case included
        case ten
        case tenToFifteen = "ten_to_fifteen"
        case fifteenToTwenty = "fifteen_to_twenty"
    }

    /// ISO 3166-1 alpha-2.
    public var id: String
    /// IEC plug letters, "C", "E".
    public var plugs: [String]
    /// Mains voltage; two values where both are in use (Brazil: 127 and 220).
    public var volts: [Int]
    /// ISO 4217 code, "EUR".
    public var currency: String
    public var tipping: Tipping?

    private enum CodingKeys: String, CodingKey { case id = "iso2", plugs, volts, currency, tipping }
}

public struct DestinationTable: Decodable, Sendable {
    public var version: Int
    public var countries: [DestinationFacts]

    /// The facts for a country, any case; nil for a country the table leaves out.
    public func facts(_ iso2: String?) -> DestinationFacts? {
        guard let code = iso2?.trimmingCharacters(in: .whitespaces).uppercased(), !code.isEmpty else { return nil }
        return countries.first { $0.id == code }
    }

    /// The facts to show for a flight: only an international one (the destination's country differs from
    /// the origin's, both known) to a country in the table.
    public func card(origin: Airport?, destination: Airport?) -> DestinationFacts? {
        guard let o = origin?.country, let d = destination?.country, !o.isEmpty, !d.isEmpty,
              o.uppercased() != d.uppercased() else { return nil }
        return facts(d)
    }

    public static func decode(_ data: Data) throws -> DestinationTable {
        try JSONDecoder().decode(DestinationTable.self, from: data)
    }

    /// The file in the app bundle. It ships with the app, so a failure is a build error.
    public static let bundled: DestinationTable = {
        guard let url = Bundle.module.url(forResource: "destinations", withExtension: "json", subdirectory: "Reference")
                ?? Bundle.module.url(forResource: "destinations", withExtension: "json"),
              let data = try? Data(contentsOf: url) else {
            fatalError("Missing destinations.json")
        }
        do { return try decode(data) } catch { fatalError("Bad destinations.json: \(error)") }
    }()
}
