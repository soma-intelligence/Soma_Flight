import Foundation

/// A flight's greenhouse gas emissions per passenger, in kg CO2e, by the method in docs/co2-method.md.
///
/// Source: UK Government GHG Conversion Factors for Company Reporting 2025 (DESNZ, published June 2025),
/// sheet "Business travel- air", factors per passenger.km **with RF** (radiative forcing: a 1.7 multiplier on
/// the CO2 part, for the non-CO2 effects of flying). The factors already carry DESNZ's 8% uplift on the great
/// circle distance for indirect routing, delays and circling (methodology paper 2025, paragraph 8.39), so the
/// distance they are multiplied by is the plain great circle distance between the two airports.
///
/// Haul: both airports in the United Kingdom is "Domestic"; otherwise under 3,700 km is short-haul and
/// 3,700 km or more long-haul (DESNZ's distance rule, methodology paragraph 8.9). The UK short- and long-haul
/// factors stand in for every flight in the world: DESNZ publishes no per-class haul split for other countries.
public enum FlightEmissions {
    public enum Haul: String, Sendable, Equatable { case domestic, shortHaul, longHaul }

    /// From this great circle distance a flight is long-haul.
    public static let longHaulFromKm = 3_700

    /// kg CO2e per passenger.km, with RF, DESNZ 2025 flat file IDs 21_316_3160 to 21_316_3176.
    enum Factor {
        /// Domestic, to/from UK, average passenger (no class split is published).
        static let domestic = 0.22928
        /// Short-haul, to/from UK.
        static let shortEconomy = 0.12576
        static let shortBusiness = 0.18863
        /// Long-haul, to/from UK.
        static let longEconomy = 0.11704
        static let longPremiumEconomy = 0.18726
        static let longBusiness = 0.33940
        static let longFirst = 0.46814
    }

    /// The haul for a flight of `km` between two countries (ISO 3166-1 alpha-2; nil when unknown).
    public static func haul(km: Int, origin: String? = nil, destination: String? = nil) -> Haul {
        if origin?.uppercased() == "GB", destination?.uppercased() == "GB" { return .domestic }
        return km >= longHaulFromKm ? .longHaul : .shortHaul
    }

    /// kg CO2e per passenger.km for the haul and seat class; nil for a private flight (no factor exists).
    /// Economy when the class is not known. On short-haul DESNZ gives economy and business only: premium
    /// economy counts as economy and first as business. Domestic has one factor for every class.
    public static func factor(_ haul: Haul, seatClass: SeatClass?) -> Double? {
        let seat = seatClass ?? .economy
        if seat == .private { return nil }
        switch haul {
        case .domestic: return Factor.domestic
        case .shortHaul:
            return seat == .business || seat == .first ? Factor.shortBusiness : Factor.shortEconomy
        case .longHaul:
            return switch seat {
            case .economy: Factor.longEconomy
            case .premiumEconomy: Factor.longPremiumEconomy
            case .business: Factor.longBusiness
            case .first: Factor.longFirst
            case .private: nil
            }
        }
    }

    /// kg CO2e for one passenger over `km` of great circle distance; 0 for no distance, nil for a private flight.
    public static func kilograms(km: Int, seatClass: SeatClass?, origin: String? = nil,
                                 destination: String? = nil) -> Double? {
        guard km > 0 else { return 0 }
        return factor(haul(km: km, origin: origin, destination: destination), seatClass: seatClass)
            .map { Double(km) * $0 }
    }

    /// kg CO2e for a past flight; nil for a canceled or private flight.
    public static func kilograms(_ f: PastFlight) -> Double? {
        guard f.status != .canceled else { return nil }
        return kilograms(km: f.distanceKm, seatClass: f.seatClass, origin: f.originCountry,
                         destination: f.destinationCountry)
    }

    /// The flights' kg CO2e added up (canceled and private flights add nothing), and how many counted.
    public static func total(_ flights: [PastFlight]) -> (kilograms: Double, flights: Int) {
        flights.reduce((0, 0)) { sum, f in
            guard let kg = kilograms(f) else { return sum }
            return (sum.0 + kg, sum.1 + 1)
        }
    }
}

/// What the screens say about emissions.
enum EmissionsFacts {
    static let title = "CO2 emissions"

    /// "640 kg" under a tonne (to the nearest 10 kg, "8 kg" under 10), "1.2 t" from a tonne, "12 t" from 10.
    static func amount(_ kg: Double) -> String {
        let en = Locale(identifier: "en_US")
        if kg < 10 { return "\(Int(kg.rounded())) kg" }
        if kg < 1_000 { return "\(Int((kg / 10).rounded()) * 10) kg" }
        let t = kg / 1_000
        if t < 10 { return "\(t.formatted(.number.precision(.fractionLength(1)).locale(en))) t" }
        return "\(Int(t.rounded()).formatted(.number.locale(en))) t"
    }

    /// The method in one line under a figure.
    static func basis(_ seatClass: SeatClass?) -> String {
        let seat = UIText.localized((seatClass ?? .economy).title)
        return String(localized: "One passenger in \(seat), non-CO2 effects included", bundle: .main)
    }

    static let source = "UK government factors (DESNZ 2025) on the great circle distance."
}
