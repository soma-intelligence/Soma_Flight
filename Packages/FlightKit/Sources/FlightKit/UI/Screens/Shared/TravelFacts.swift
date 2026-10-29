import Foundation
import SwiftUI

/// Pure helpers for the flight, search and Passport screens: names, totals wording, the past
/// flights list order. Kept out of the views so they can be unit tested.
enum TravelFacts {
    // MARK: Aircraft

    /// Marketing name for common ICAO type designators; the designator itself otherwise.
    static func aircraftName(_ type: String) -> String { aircraftNames[type] ?? type }

    private static let aircraftNames: [String: String] = [
        "A20N": "Airbus A320neo", "A21N": "Airbus A321neo", "A220": "Airbus A220", "BCS3": "Airbus A220-300",
        "A319": "Airbus A319", "A320": "Airbus A320", "A321": "Airbus A321", "A332": "Airbus A330-200",
        "A333": "Airbus A330-300", "A339": "Airbus A330-900", "A359": "Airbus A350-900", "A35K": "Airbus A350-1000",
        "A388": "Airbus A380", "B737": "Boeing 737-700", "B738": "Boeing 737-800", "B739": "Boeing 737-900",
        "B38M": "Boeing 737 MAX 8", "B39M": "Boeing 737 MAX 9", "B752": "Boeing 757-200", "B763": "Boeing 767-300",
        "B772": "Boeing 777-200", "B77W": "Boeing 777-300ER", "B788": "Boeing 787-8", "B789": "Boeing 787-9",
        "B78X": "Boeing 787-10", "E175": "Embraer 175", "E190": "Embraer 190", "CRJ9": "Bombardier CRJ900",
    ]

    // MARK: Airlines

    /// Airline designator from a flight number: "AF" from "AF84", "B6" from "B6417".
    static func airlineCode(ident: String) -> String {
        let chars = Array(ident)
        guard chars.count > 2 else { return ident }
        return String(chars[..<(chars[2].isLetter ? 3 : 2)])
    }

    /// A steady tint per airline for the round badge that stands in for a logo.
    static func airlineTint(_ key: String) -> Color {
        let palette: [Color] = [
            Color(light: 0x2F5BD3, dark: 0x3D6AE0), Color(light: 0xC23B3B, dark: 0xD14848),
            Color(light: 0x1E8A6E, dark: 0x29A383), Color(light: 0x7A4CC2, dark: 0x8C5CD6),
            Color(light: 0xC77A12, dark: 0xD98A1E), Color(light: 0x1F7FA8, dark: 0x2A93C0),
            Color(light: 0x8A6A3A, dark: 0x9C7B48), Color(light: 0x4A5568, dark: 0x5B6678),
        ]
        // FNV-1a, so short names with shared letters still spread over the palette.
        let hash = key.utf8.reduce(UInt32(2_166_136_261)) { ($0 ^ UInt32($1)) &* 16_777_619 }
        return palette[Int(hash % UInt32(palette.count))]
    }

    // MARK: Totals wording

    /// "14d 23h" from a day up, "18h 20m" below.
    static func flightTime(_ d: Duration) -> String {
        let m = Int(d.components.seconds / 60)
        let days = m / 1440, hours = (m % 1440) / 60, minutes = m % 60
        if days > 0 { return "\(days)d \(hours)h" }
        return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
    }

    static let earthKm = 40_075.0
    static let kmPerMile = 1.609_344

    /// "280,017 km" or "173,994 mi".
    static func distance(_ km: Int, _ unit: DistanceUnit) -> String {
        let value = unit == .km ? km : Int((Double(km) / kmPerMile).rounded())
        return "\(value.formatted(.number.grouping(.automatic).locale(Locale(identifier: "en_US")))) \(unit.rawValue)"
    }

    /// "7.0x around the world".
    static func aroundTheWorld(_ km: Int) -> String {
        String(format: "%.1fx around the world", Double(km) / earthKm)
    }

    /// Big number and its caption for the delays card: whole hours from one hour up, else minutes.
    static func delayLost(_ d: Duration) -> (value: String, caption: String) {
        let m = Int(d.components.seconds / 60)
        if m >= 60 {
            let h = m / 60
            return ("\(h)", h == 1 ? "hour lost to delays" : "hours lost to delays")
        }
        return ("\(m)", m == 1 ? "minute lost to delays" : "minutes lost to delays")
    }

    static func averageDelayLine(_ minutes: Int) -> String {
        minutes == 0 ? "Your flights left on time on average" : "Your flights left \(Format.minutes(minutes)) late on average"
    }

    // MARK: Past flights list

    enum Sort: String, CaseIterable, Hashable {
        case date, from, to, airline, aircraft

        var title: String {
            switch self {
            case .date: "Date"
            case .from: "From"
            case .to: "To"
            case .airline: "Airline"
            case .aircraft: "Aircraft"
            }
        }
    }

    struct Group: Identifiable {
        var id: String { title }
        var title: String
        var flights: [PastFlight]
    }

    /// Groups the list for the chosen sort: by local year (newest first) for date, else by
    /// origin city, destination city, airline or aircraft (largest group first, then by name).
    /// Inside a group flights stay newest first.
    static func groups(_ flights: [PastFlight], by sort: Sort, city: (String) -> String) -> [Group] {
        let newest = flights.sorted { $0.date > $1.date }
        func key(_ f: PastFlight) -> String {
            switch sort {
            case .date: String(f.localYear)
            case .from: city(f.originIcao)
            case .to: city(f.destinationIcao)
            // The code, so "UA" and "United" rows for one carrier land in one group.
            case .airline: airlineCode(ident: f.ident)
            case .aircraft: f.aircraftType.map(aircraftName) ?? "Unknown aircraft"
            }
        }
        var order: [String] = []
        var buckets: [String: [PastFlight]] = [:]
        for f in newest {
            let k = key(f)
            if buckets[k] == nil { order.append(k) }
            buckets[k, default: []].append(f)
        }
        var out: [Group] = order.compactMap { k in
            guard let list = buckets[k] else { return nil }
            // Airline groups show the carrier's name when any row carries it, else the code.
            let title = sort == .airline ? (list.lazy.compactMap(\.airline).first ?? k) : k
            return Group(title: title, flights: list)
        }
        if sort != .date {
            out.sort { ($0.flights.count, $1.title) > ($1.flights.count, $0.title) }
        }
        return out
    }
}
