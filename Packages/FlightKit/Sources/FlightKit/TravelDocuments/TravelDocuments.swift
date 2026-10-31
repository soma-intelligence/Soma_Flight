import Foundation

/// One airline loyalty number the traveller keeps in the app, for the airline that runs the programme.
public struct LoyaltyNumber: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    /// ICAO designator of the airline whose programme this is, "UAL".
    public var airline: String
    /// Normalised: upper case, no spaces or dashes (`TravelDocumentRules.normalise`).
    public var number: String
    /// What the traveller calls the programme, as they typed it; nil shows the airline's name.
    public var programme: String?

    public init(id: UUID = UUID(), airline: String, number: String, programme: String? = nil) {
        self.id = id; self.airline = airline.uppercased(); self.number = number; self.programme = programme
    }
}

/// What the flight sheet may read without Face ID: loyalty numbers (printed on every boarding pass anyway)
/// and the passport's country and expiry date, never its number. One Keychain item.
public struct TravelProfile: Codable, Sendable, Equatable {
    public var loyalty: [LoyaltyNumber]
    /// ISO 3166-1 alpha-2 of the country that issued the passport.
    public var passportCountry: String?
    /// The passport's expiry day, as "yyyy-MM-dd" (a calendar day, no time zone).
    public var passportExpires: String?

    public init(loyalty: [LoyaltyNumber] = [], passportCountry: String? = nil, passportExpires: String? = nil) {
        self.loyalty = loyalty; self.passportCountry = passportCountry; self.passportExpires = passportExpires
    }

    public var isEmpty: Bool { loyalty.isEmpty && passportCountry == nil && passportExpires == nil }
}

/// The numbers that identify the traveller, shown only after Face ID (or the passcode). One Keychain item.
public struct TravelIdentity: Codable, Sendable, Equatable {
    public var passportNumber: String?
    /// TSA PreCheck or Global Entry Known Traveler Number.
    public var knownTraveler: String?
    /// DHS TRIP Redress Number.
    public var redress: String?

    public init(passportNumber: String? = nil, knownTraveler: String? = nil, redress: String? = nil) {
        self.passportNumber = passportNumber; self.knownTraveler = knownTraveler; self.redress = redress
    }

    public var isEmpty: Bool { passportNumber == nil && knownTraveler == nil && redress == nil }
}

/// The kinds of number the vault holds, for validation, masking and copy.
public enum TravelDocumentKind: String, Sendable, CaseIterable {
    case loyalty, passport, knownTraveler, redress

    public var title: String {
        switch self {
        case .loyalty: "Loyalty Number"
        case .passport: "Passport Number"
        case .knownTraveler: "Known Traveler Number"
        case .redress: "Redress Number"
        }
    }

    /// Whether the number hides until Face ID and leaves the clipboard on its own.
    public var isSensitive: Bool { self != .loyalty }
}

/// The vault's rules, pure: what a valid number looks like, how a hidden one shows, which loyalty number
/// fits a flight and when the passport needs a word before an international flight.
public enum TravelDocumentRules {
    /// "ab 123-456" is "AB123456".
    public static func normalise(_ raw: String) -> String {
        raw.uppercased().filter { !$0.isWhitespace && $0 != "-" }
    }

    /// The normalised number when it is valid for `kind`, else nil.
    ///
    /// Loyalty numbers: 4 to 20 letters and digits. Passport numbers: 5 to 12 (ICAO 9303 allows up to 9 in
    /// the machine-readable line, some countries print more). Known Traveler Numbers: 8 to 10 (TSA's 9
    /// character KTN, CBP's 9 digit PASSID, older 8 and 10 character forms). Redress Numbers: 6 to 13 digits
    /// (DHS TRIP issues 7 today).
    public static func validated(_ raw: String, as kind: TravelDocumentKind) -> String? {
        let s = normalise(raw)
        let alnum = s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
        switch kind {
        case .loyalty: return alnum && (4...20).contains(s.count) ? s : nil
        case .passport: return alnum && (5...12).contains(s.count) ? s : nil
        case .knownTraveler: return alnum && (8...10).contains(s.count) ? s : nil
        case .redress: return s.allSatisfy { $0.isASCII && $0.isNumber } && (6...13).contains(s.count) ? s : nil
        }
    }

    /// A hidden number shows its last four characters, "•••• 4821"; one of five characters or fewer shows none.
    public static func masked(_ number: String) -> String {
        number.count <= 5 ? "••••••" : "•••• \(number.suffix(4))"
    }

    /// The loyalty numbers that fit a flight on `airline`: the airline's own programme first, then the
    /// programmes of airlines in its alliance (a partner flight can usually earn on them).
    public static func loyalty(for airline: Airline?, in numbers: [LoyaltyNumber],
                               lookup: (String) -> Airline?) -> (own: LoyaltyNumber?, partners: [LoyaltyNumber]) {
        guard let airline else { return (nil, []) }
        let own = numbers.first { $0.airline == airline.id.uppercased() }
        guard let alliance = airline.alliance else { return (own, []) }
        let partners = numbers.filter { $0.id != own?.id && $0.airline != airline.id.uppercased()
            && lookup($0.airline)?.alliance == alliance }
        return (own, partners)
    }

    /// Countries commonly ask for a passport valid six months past arrival.
    public static let passportMonths = 6

    /// What to say about the passport before an international flight, nil when nothing: expired by the
    /// day of departure, or expiring within six months of it. Domestic flights, flights without a known
    /// departure and a passport without an expiry say nothing.
    public static func passportNotice(expires: String?, departure: Date?, international: Bool,
                                      calendar: Calendar = gregorianUTC) -> PassportNotice? {
        guard international, let departure, let expiry = day(expires, calendar: calendar) else { return nil }
        let departureDay = calendar.startOfDay(for: departure)
        if expiry < departureDay { return .expired(expiry) }
        guard let limit = calendar.date(byAdding: .month, value: passportMonths, to: departureDay) else { return nil }
        return expiry < limit ? .expiresSoon(expiry) : nil
    }

    public enum PassportNotice: Sendable, Equatable {
        case expired(Date)
        case expiresSoon(Date)
    }

    /// "Your passport expires on 12 Mar 2027, within six months of this flight. Many countries ask for six
    /// months left, so check your destination's rule."
    public static func passportText(_ notice: PassportNotice) -> (title: String, text: String) {
        switch notice {
        case .expired(let d):
            ("Passport expired", "Your passport expired on \(dayText(d)), before this flight. Renew it before you travel.")
        case .expiresSoon(let d):
            ("Passport expires soon", "Your passport expires on \(dayText(d)), within six months of this flight. Many countries ask for six months left, so check your destination's rule.")
        }
    }

    // MARK: Days

    public static let gregorianUTC: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = .gmt
        return c
    }()

    /// "2027-03-12" as midnight UTC that day.
    public static func day(_ s: String?, calendar: Calendar = gregorianUTC) -> Date? {
        guard let s else { return nil }
        let parts = s.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    /// Midnight UTC on `date`'s day in `calendar`, as "yyyy-MM-dd".
    public static func dayString(_ date: Date, calendar: Calendar = gregorianUTC) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// "12 Mar 2027".
    public static func dayText(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.timeZone = .gmt
        f.dateFormat = "d MMM yyyy"
        return f.string(from: d)
    }
}
