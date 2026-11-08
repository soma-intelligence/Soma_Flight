import Foundation

/// The airline's customer service line and manage booking page, from
/// `Resources/Reference/airline_contacts.json`. Each entry was read on the airline's own website on the
/// date it carries (`checked`), from the page in `source`; an airline outside the file has no entry rather
/// than a guess.
public struct AirlineContact: Decodable, Sendable, Hashable {
    /// ICAO designator, "AFR".
    public var icao: String
    public var iata: String
    public var name: String
    /// E.164, "+33969393654"; nil when the airline publishes no number that can be written that way.
    public var phone: String?
    /// The country the line serves, ISO 3166-1 alpha-2.
    public var phoneCountry: String?
    /// The page to change or rebook a booking online.
    public var rebook: URL
    /// The airline page where the number (or the link) was read.
    public var source: URL
    /// "2026-11-08".
    public var checked: String

    /// `tel:` for the phone line.
    public var phoneURL: URL? { phone.flatMap { URL(string: "tel:\($0)") } }

    /// True for "+" then 8 to 15 digits, the first not 0 (ITU-T E.164).
    public static func isE164(_ s: String) -> Bool {
        guard s.first == "+" else { return false }
        let digits = s.dropFirst()
        return (8...15).contains(digits.count) && digits.allSatisfy { $0.isASCII && $0.isNumber } && digits.first != "0"
    }
}

public struct AirlineContacts: Decodable, Sendable {
    public var version: Int
    public var airlines: [AirlineContact]

    /// The entry for an airline, by ICAO or IATA code, any case.
    public func contact(_ code: String?) -> AirlineContact? {
        guard let code = code?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(), !code.isEmpty else { return nil }
        return airlines.first { $0.icao == code } ?? airlines.first { $0.iata == code }
    }

    public static func decode(_ data: Data) throws -> AirlineContacts {
        try JSONDecoder().decode(AirlineContacts.self, from: data)
    }

    /// The file in the app bundle. It ships with the app, so a failure is a build error.
    public static let bundled: AirlineContacts = {
        guard let url = Bundle.module.url(forResource: "airline_contacts", withExtension: "json", subdirectory: "Reference")
                ?? Bundle.module.url(forResource: "airline_contacts", withExtension: "json"),
              let data = try? Data(contentsOf: url) else {
            fatalError("Missing airline_contacts.json")
        }
        do { return try decode(data) } catch { fatalError("Bad airline_contacts.json: \(error)") }
    }()
}

/// When the flight sheet offers the cancellation kit: a canceled flight, or one still at the gate whose
/// departure has moved 3 hours or more.
public enum CancellationKit {
    public static let longDelay: TimeInterval = 3 * 3600

    public static func isShown(_ f: Flight) -> Bool {
        if f.status == .canceled { return true }
        guard f.actualOut == nil, [.scheduled, .unknown].contains(f.status),
              let delay = f.departureDelay else { return false }
        return delay >= .seconds(longDelay)
    }
}
