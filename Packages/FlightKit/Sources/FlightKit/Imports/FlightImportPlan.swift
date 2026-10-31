import Foundation
import FlightImportKit

/// A flight that has not left yet, to follow: now when it is within reach of a flight lookup (two days
/// ahead), else kept on this device and followed once it is (`FollowLaterQueue`).
public struct UpcomingFlight: Codable, Sendable, Hashable, Identifiable {
    /// The flight number as written ("AF84").
    public var ident: String
    /// The departure day, local at the origin.
    public var day: LocalDay
    /// The airports as ICAO codes when known, else as written; nil when the source did not say.
    public var origin: String?
    public var destination: String?
    /// The departure, when the source gave a time.
    public var departure: Date?
    /// What is noted on the flight once followed.
    public var details: FollowDetails

    public var id: String { "\(ident) \(day)" }

    public init(ident: String, day: LocalDay, origin: String? = nil, destination: String? = nil, departure: Date? = nil,
                details: FollowDetails = .empty) {
        self.ident = ident; self.day = day; self.origin = origin; self.destination = destination
        self.departure = departure; self.details = details
    }
}

/// One flight of an import and what adding it would do.
public struct ImportCandidate: Sendable, Hashable, Identifiable {
    public enum Action: Sendable, Hashable {
        /// Goes into the history.
        case addPast(PastFlight)
        /// Gets followed (or waits to be).
        case follow(UpcomingFlight)
        /// Already in the history, followed, waiting to be, or listed twice.
        case duplicate(String)
        /// Cannot be added; the text says why.
        case unusable(String)
    }

    public var id: Int
    /// Where it was found: "Row 12", an event's title, an email's subject.
    public var label: String
    public var source: ImportedFlight
    public var action: Action
    /// Values left out ("Seat “aisle” left out").
    public var warnings: [String]

    /// Ticked when the screen opens: what can be added.
    public var isActionable: Bool {
        switch action {
        case .addPast, .follow: true
        case .duplicate, .unusable: false
        }
    }
}

/// Turns what an import read into what it would do: a past flight for the history, a flight to follow,
/// or why not (a duplicate of the history, of a followed flight, of a waiting one, or of an earlier
/// row; a part missing). Pure: the history, the followed flights, the waiting ones, the airport and
/// airline lists and the clock go in.
public enum FlightImportPlan {
    public struct Context {
        public var existing: [PastFlight]
        public var followed: [Flight]
        public var waiting: [UpcomingFlight]
        public var airport: (String) -> Airport?
        public var reference: ReferenceData
        public var now: Date

        public init(existing: [PastFlight] = [], followed: [Flight] = [], waiting: [UpcomingFlight] = [],
                    airport: @escaping (String) -> Airport?, reference: ReferenceData = .bundled(), now: Date) {
            self.existing = existing; self.followed = followed; self.waiting = waiting; self.airport = airport
            self.reference = reference; self.now = now
        }
    }

    public static func plan(_ items: [(label: String, flight: ImportedFlight)], context c: Context,
                            makeID: () -> UUID = UUID.init) -> [ImportCandidate] {
        var seenTrips: [String: String] = [:]
        for f in c.existing { seenTrips[PastFlightRules.tripKey(f, airport: c.airport)] = "Already in your history" }
        var seenFollows: [String: String] = [:]
        for w in c.waiting { seenFollows[followKey(w.ident, w.day, reference: c.reference)] = "Already waiting to be followed" }
        for f in c.followed {
            guard let out = f.scheduledOut ?? f.estimatedOut else { continue }
            let zone = c.airport(f.originIcao)?.timeZone ?? .gmt
            seenFollows[followKey(f.ident, LocalDay(out, in: zone), reference: c.reference)] = "Already following"
        }

        var out: [ImportCandidate] = []
        for (index, item) in items.enumerated() {
            var candidate = ImportCandidate(id: index, label: item.label, source: item.flight, action: .unusable(""),
                                            warnings: [])
            let f = item.flight
            let departure = departureInstant(f, airport: c.airport)
            if departure > c.now {
                if f.canceled {
                    candidate.action = .unusable("Canceled")
                } else if let raw = f.ident, case let ident?? = PastFlightRules.ident(iataIdent(raw, reference: c.reference)) {
                    let key = followKey(ident, f.day, reference: c.reference)
                    if let why = seenFollows[key] {
                        candidate.action = .duplicate(why)
                    } else {
                        seenFollows[key] = "Listed twice"
                        candidate.action = .follow(upcoming(f, ident: ident, departure: departure, context: c,
                                                            warnings: &candidate.warnings))
                    }
                } else {
                    candidate.action = .unusable("No flight number to follow")
                }
            } else {
                switch past(f, departure: departure, context: c, id: makeID(), warnings: &candidate.warnings) {
                case .failure(let why):
                    candidate.action = .unusable(why.message)
                case .success(let flight):
                    let key = PastFlightRules.tripKey(flight, airport: c.airport)
                    if let why = seenTrips[key] {
                        candidate.action = .duplicate(why)
                    } else {
                        seenTrips[key] = "Listed twice"
                        candidate.action = .addPast(flight)
                    }
                }
            }
            out.append(candidate)
        }
        return out
    }

    // MARK: Pieces

    /// When the flight leaves: the instant the source gave, else its day and time in the origin's zone
    /// (noon without a time; UTC for an airport the list does not know).
    static func departureInstant(_ f: ImportedFlight, airport: (String) -> Airport?) -> Date {
        if let d = f.departure { return d }
        let zone = f.origin.flatMap(airport)?.timeZone ?? .gmt
        if let t = f.departureTime, let d = PastFlightRules.at(year: f.day.year, month: f.day.month, day: f.day.day,
                                                               hour: t.hour, minute: t.minute, in: zone) {
            return d
        }
        return PastFlightRules.noon(year: f.day.year, month: f.day.month, day: f.day.day, in: zone)
            ?? Date(timeIntervalSince1970: 0)
    }

    /// The airline code a flight number starts with, as one key whether written IATA or ICAO ("AF84" and
    /// "AFR84" give the same), with the number's leading zeros dropped.
    static func followKey(_ ident: String, _ day: LocalDay, reference: ReferenceData) -> String {
        let code = TravelFacts.airlineCode(ident: ident)
        let airline = reference.airline(code)?.id ?? code
        let number = ident.dropFirst(code.count).drop { $0 == "0" }
        return "\(airline)\(number) \(day)"
    }

    static func upcoming(_ f: ImportedFlight, ident: String, departure: Date, context c: Context,
                         warnings: inout [String]) -> UpcomingFlight {
        var details = FollowDetails()
        details.seat = optional(f.seat, "Seat", FollowDetails.normalizedSeat, &warnings)
        details.bookingCode = optional(f.bookingReference, "Booking code", FollowDetails.normalizedBookingCode, &warnings)
        details.seatClass = f.cabin.flatMap(seatClass)
        details.seatPosition = f.seatPosition.flatMap { word($0, PastFlightImport.positionWords) }.flatMap(SeatPosition.init(rawValue:))
        details.reason = f.reason.flatMap { word($0, reasonWords) }.flatMap(TripReason.init(rawValue:))
        return UpcomingFlight(ident: ident, day: f.day, origin: f.origin.map { c.airport($0)?.id ?? $0 },
                              destination: f.destination.map { c.airport($0)?.id ?? $0 },
                              departure: f.departure ?? (f.departureTime != nil ? departure : nil), details: details)
    }

    enum PastProblem: Error {
        case noOrigin, noDestination, badOrigin(String), badDestination(String), sameAirports, badDate

        var message: String {
            switch self {
            case .noOrigin: "No departure airport"
            case .noDestination: "No arrival airport"
            case .badOrigin(let s): "Departure \u{201C}\(s)\u{201D} is not an airport code"
            case .badDestination(let s): "Arrival \u{201C}\(s)\u{201D} is not an airport code"
            case .sameAirports: "Departs and arrives at the same airport"
            case .badDate: "Date is before 1919"
            }
        }
    }

    /// The flight as a past flight for the history, the optional values that do not read left out with a
    /// warning each.
    static func past(_ f: ImportedFlight, departure: Date, context c: Context, id: UUID,
                     warnings: inout [String]) -> Result<PastFlight, PastProblem> {
        guard let fromText = f.origin else { return .failure(.noOrigin) }
        guard let toText = f.destination else { return .failure(.noDestination) }
        guard let from = PastFlightImport.airportCode(in: fromText, airport: c.airport) else { return .failure(.badOrigin(fromText)) }
        guard let to = PastFlightImport.airportCode(in: toText, airport: c.airport) else { return .failure(.badDestination(toText)) }
        if from == to { return .failure(.sameAirports) }
        guard PastFlightRules.allows(date: departure, now: c.now) else { return .failure(.badDate) }

        var p = PastFlight(id: id, date: departure, ident: "", originIcao: from, destinationIcao: to, distanceKm: 0, source: .import)
        if let raw = f.ident {
            p.ident = optional(iataIdent(raw, reference: c.reference), "Flight number", PastFlightRules.ident, &warnings) ?? ""
        }
        if let a = f.airline {
            p.airline = c.reference.airline(a)?.id ?? optional(a, "Airline", PastFlightRules.airline, &warnings)
        }
        if p.airline == nil, !p.ident.isEmpty { p.airline = c.reference.airline(ident: p.ident)?.id }
        if let t = f.aircraft {
            p.aircraftType = PastFlightImport.aircraftType(t, reference: c.reference)
                ?? optional(t, "Aircraft", PastFlightRules.aircraftType, &warnings)
        }
        p.registration = optional(f.registration, "Registration", PastFlightRules.registration, &warnings)
        p.seat = optional(f.seat, "Seat", FollowDetails.normalizedSeat, &warnings)
        p.bookingCode = optional(f.bookingReference, "Booking code", FollowDetails.normalizedBookingCode, &warnings)
        if let cabin = f.cabin {
            p.seatClass = seatClass(cabin)
            if p.seatClass == nil { warnings.append("Class \u{201C}\(cabin)\u{201D} left out") }
        }
        if let r = f.reason {
            p.reason = word(r, reasonWords).flatMap(TripReason.init(rawValue:))
            if p.reason == nil { warnings.append("Reason \u{201C}\(r)\u{201D} left out") }
        }
        if let s = f.seatPosition {
            p.seatPosition = word(s, PastFlightImport.positionWords).flatMap(SeatPosition.init(rawValue:))
            if p.seatPosition == nil { warnings.append("Seat position \u{201C}\(s)\u{201D} left out") }
        }
        if let notes = f.notes {
            p.notes = String(String.UnicodeScalarView(notes.unicodeScalars.prefix(FollowDetails.maxNotes)))
            if notes.unicodeScalars.count > FollowDetails.maxNotes { warnings.append("Notes cut to 2,000 characters") }
        }
        if let d = f.delayMinutes { p.delayMinutes = d }
        if f.canceled {
            p.status = .canceled
        } else if let diverted = f.divertedTo {
            p.status = .diverted
            warnings.append("Diverted to \(diverted)")
        }
        // Gate to gate, when both clocks are known: the arrival's zone is the destination's.
        if let arrivalDay = f.arrivalDay, let at = f.arrivalTime, let dz = c.airport(to)?.timeZone,
           f.departureTime != nil || f.departure != nil, c.airport(from) != nil || f.departure != nil,
           let arrival = PastFlightRules.at(year: arrivalDay.year, month: arrivalDay.month, day: arrivalDay.day,
                                            hour: at.hour, minute: at.minute, in: dz) {
            let minutes = Int(arrival.timeIntervalSince(departure) / 60)
            if (10...(24 * 60)).contains(minutes) { p.blockMinutes = minutes }
        }
        return .success(p)
    }

    /// A flight number led by an ICAO airline the list knows, with its IATA code instead ("CPA471" gives
    /// "CX471"), as the app writes flight numbers.
    static func iataIdent(_ raw: String, reference: ReferenceData) -> String {
        let code = TravelFacts.airlineCode(ident: raw)
        guard code.count == 3, let iata = reference.airline(code)?.iata, !iata.isEmpty else { return raw }
        return iata + raw.dropFirst(3)
    }

    /// The class a cabin name stands for: "ECONOMY", "PREMIUM_ECONOMY", "Business", "La Première".
    static func seatClass(_ cabin: String) -> SeatClass? {
        if let w = word(cabin, PastFlightImport.classWords) { return SeatClass(rawValue: w) }
        return BoardingPassMatch.seatClass(cabin: cabin)
    }

    /// What the export's and the confirmations' reasons mean: leisure is personal.
    static let reasonWords: [String: String] = PastFlightImport.reasonWords.merging(
        ["personalbusiness": "business", "other": "personal", "travel": "personal"]) { a, _ in a }

    private static func word(_ s: String, _ words: [String: String]) -> String? {
        words[PastFlightImport.normalized(s)]
    }

    /// The value `rule` makes of `text`; a value that does not read is left out with a warning.
    private static func optional(_ text: String?, _ label: String, _ rule: (String) -> String??,
                                 _ warnings: inout [String]) -> String? {
        guard let text else { return nil }
        guard let v = rule(text) else {
            warnings.append("\(label) \u{201C}\(text)\u{201D} left out")
            return nil
        }
        return v
    }
}
