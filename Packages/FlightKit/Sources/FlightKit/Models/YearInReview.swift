import Foundation
import FlightCore

/// One year of the history as the Year in Review cards tell it: how much was flown, how long in the air,
/// where to, the longest flight, the time lost to delays and the favourite route and aircraft. Pure: the
/// same flights, year and clock give the same review. The counts come from the Rust core
/// (`computePassport`, `computePassportDetail`) and the Delay Report, so they agree with the Passport.
/// Nothing here leaves the device: the cards are drawn on the phone and shared only when the traveller
/// shares them.
public struct YearInReview: Sendable, Equatable {
    /// The cards, in the order they are shown and shared.
    public enum Card: String, CaseIterable, Sendable, Identifiable {
        case flights, time, places, longest, delays, favorite
        public var id: String { rawValue }
    }

    /// The year's longest flight by distance.
    public struct Longest: Sendable, Equatable {
        public var ident: String
        public var originIcao: String
        public var destinationIcao: String
        public var distanceKm: Int
        /// Gate to gate, nil when the times are not known.
        public var minutes: Int?
    }

    /// The airline whose flights most often arrived on time or early (two flights at least, and two such
    /// airlines at least, else no pick).
    public struct Punctual: Sendable, Equatable {
        /// ICAO code as the store maps it, else the flight number's prefix.
        public var airline: String
        public var onTimePercent: Int
        public var flights: Int
    }

    public struct Route: Sendable, Equatable {
        public var originIcao: String
        public var destinationIcao: String
        public var flights: Int
    }

    public var year: Int
    /// True for the current year: its figures are "so far".
    public var isSoFar: Bool
    /// Flights counted (canceled ones are not).
    public var flights: Int
    public var longHaul: Int
    public var distanceKm: Int
    /// The distance over the Earth's circumference (the core's ratio).
    public var earthLaps: Double
    /// Time flown, gate to gate where known (the Passport's flight time).
    public var flightMinutes: Int
    /// Countries visited, ISO 3166-1 alpha-2, most flown first.
    public var countries: [String]
    /// Airports visited, ICAO, most visited first.
    public var airports: [String]
    public var longest: Longest?
    /// Minutes the late arrivals were late, summed (`DelayReport.lostMinutes`).
    public var delayLostMinutes: Int
    /// Completed flights whose arrival delay is known: what the delay card speaks for.
    public var timedFlights: Int
    public var punctual: Punctual?
    /// Every route of the year, most flown first (either way counts as its own route, as in the Passport).
    public var routes: [Route]
    /// The route flown most.
    public var topRoute: Route? { routes.first }
    /// The aircraft type flown most, ICAO designator, and on how many flights.
    public var topAircraft: (type: String, flights: Int)?

    public static func == (a: Self, b: Self) -> Bool {
        a.year == b.year && a.isSoFar == b.isSoFar && a.flights == b.flights && a.longHaul == b.longHaul
            && a.distanceKm == b.distanceKm && a.earthLaps == b.earthLaps && a.flightMinutes == b.flightMinutes
            && a.countries == b.countries && a.airports == b.airports && a.longest == b.longest
            && a.delayLostMinutes == b.delayLostMinutes && a.timedFlights == b.timedFlights
            && a.punctual == b.punctual && a.routes == b.routes
            && a.topAircraft?.type == b.topAircraft?.type && a.topAircraft?.flights == b.topAircraft?.flights
    }

    /// The cards that have something to say: the longest flight needs one flight with a distance, the
    /// delays card a flight with a known arrival, the favourite card a route flown twice or a known aircraft.
    public var cards: [Card] {
        Card.allCases.filter { card in
            switch card {
            case .flights, .time, .places: true
            case .longest: longest != nil
            case .delays: timedFlights > 0
            case .favorite: (topRoute?.flights ?? 0) >= 2 || topAircraft != nil
            }
        }
    }

    /// Years with at least one flight the review counts (canceled flights alone make no review), newest first.
    public static func years(_ flights: [PastFlight]) -> [Int] {
        Array(Set(flights.filter { $0.status != .canceled }.map(\.localYear))).sorted(by: >)
    }

    /// The review of `year`, nil when the year has no flight to count. `flights` are the history as the
    /// store maps it (`PassportStore.allFlights`: airlines as ICAO codes, countries filled in); a raw
    /// history works too, it is mapped again here.
    /// - Parameters:
    ///   - now: what "so far" is measured against, in `timeZone`.
    public static func make(_ flights: [PastFlight], year: Int, now: Date, timeZone: TimeZone = .current,
                            reference: ReferenceData = .bundled(),
                            airport: ((String) -> Airport?)? = nil) -> YearInReview? {
        let airport = airport ?? PassportStore.bundledAirports
        let mapped = PassportStore.mapped(flights, reference: reference, airport: airport)
        let inYear = mapped.filter { $0.localYear == year }
        guard inYear.contains(where: { $0.status != .canceled }) else { return nil }
        let core = inYear.map(\.coreFlight)
        let stats = PassportStats.compute(core: core, year: year)
        guard stats.flights > 0 else { return nil }
        let detail = FlightCore.computePassportDetail(flights: core, year: Int32(year),
                                                      countries: reference.countries.map(\.coreInfo))
        let delays = DelayReport.compute(inYear, year: year)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let longest = detail.longestByDistance.flatMap { r -> Longest? in
            guard r.distanceKm > 0 else { return nil }
            return Longest(ident: r.ident, originIcao: r.originIcao, destinationIcao: r.destinationIcao,
                           distanceKm: Int(r.distanceKm), minutes: r.blockMinutes.map(Int.init))
        }
        let routes = detail.routesByFlights.compactMap { t -> Route? in
            let parts = t.key.split(separator: "-").map(String.init)
            guard parts.count == 2 else { return nil }
            return Route(originIcao: parts[0], destinationIcao: parts[1], flights: Int(t.flights))
        }
        return YearInReview(
            year: year, isSoFar: calendar.component(.year, from: now) == year, flights: stats.flights,
            longHaul: stats.longHaul, distanceKm: stats.distanceKm, earthLaps: detail.earthRatio,
            flightMinutes: Int(detail.flightMinutes), countries: detail.countries.map(\.iso2),
            airports: detail.airports.map(\.icao), longest: longest,
            delayLostMinutes: delays.lostMinutes, timedFlights: delays.withTimes,
            punctual: punctual(delays), routes: routes,
            topAircraft: stats.mostFlownAircraft.map { (type: $0.type, flights: $0.count) })
    }

    /// The airline with the best share of flights on time or early, among those with two timed flights or
    /// more; ties go to the airline flown more, then by code. Nil unless two airlines qualify: with one,
    /// "most punctual" says nothing.
    static func punctual(_ report: DelayReport) -> Punctual? {
        let rows = report.airlines.filter { $0.share.of >= 2 }
        guard rows.count >= 2 else { return nil }
        let best = rows.min { a, b in
            let la = a.share.late * b.share.of, lb = b.share.late * a.share.of
            if la != lb { return la < lb }
            return a.share.of != b.share.of ? a.share.of > b.share.of : a.key < b.key
        }
        return best.map { Punctual(airline: $0.key, onTimePercent: 100 - $0.share.percent, flights: $0.share.of) }
    }
}

/// The cards' words, English source with French in Localizable.xcstrings.
enum YearInReviewFacts {
    /// "2026 so far" or "Your 2025": the kicker on every card.
    static func kicker(_ r: YearInReview) -> String {
        r.isSoFar ? String(localized: "\(String(r.year)) so far", bundle: .main)
            : String(localized: "Your \(String(r.year))", bundle: .main)
    }

    /// The Passport's entry row: "2026 So Far" for the current year, "2025 in Review" otherwise.
    static func entry(year: Int, soFar: Bool) -> String {
        soFar ? String(localized: "\(String(year)) So Far", bundle: .main)
            : String(localized: "\(String(year)) in Review", bundle: .main)
    }

    static func flights(_ n: Int) -> String {
        n == 1 ? String(localized: "flight", bundle: .main) : String(localized: "flights", bundle: .main)
    }

    /// "1.7 times around the Earth"; under a tenth, "a start on a lap of the Earth".
    static func laps(_ laps: Double) -> String {
        if laps < 0.1 { return String(localized: "A start on your first lap of the Earth", bundle: .main) }
        let value = PassportFacts.multiple(laps)
        return laps >= 0.95 && laps < 1.05 ? String(localized: "Once around the Earth", bundle: .main)
            : String(localized: "\(value) times around the Earth", bundle: .main)
    }

    /// "121" and "hours in the air"; under two hours, minutes.
    static func time(_ minutes: Int) -> (value: String, caption: String) {
        if minutes < 120 { return (PassportFacts.count(minutes), String(localized: "minutes in the air", bundle: .main)) }
        return (PassportFacts.count(minutes / 60), String(localized: "hours in the air", bundle: .main))
    }

    /// "That's 5.0 days" from a day up, nil below.
    static func days(_ minutes: Int) -> String? {
        guard minutes >= 1_440 else { return nil }
        return String(localized: "That's \(PassportFacts.multiple(Double(minutes) / 1_440)) days off the ground", bundle: .main)
    }

    static func longHauls(_ n: Int) -> String? {
        switch n {
        case 0: nil
        case 1: String(localized: "1 long haul", bundle: .main)
        default: String(localized: "\(n) long hauls", bundle: .main)
        }
    }

    static func countries(_ n: Int) -> String {
        n == 1 ? String(localized: "country", bundle: .main) : String(localized: "countries", bundle: .main)
    }

    static func airports(_ n: Int) -> String {
        n == 1 ? String(localized: "1 airport", bundle: .main) : String(localized: "\(n) airports", bundle: .main)
    }

    static var longestTitle: String { String(localized: "Longest flight", bundle: .main) }

    /// "16h 40m" gate to gate.
    static func duration(_ minutes: Int) -> String {
        TravelFacts.flightTime(.seconds(Int64(minutes) * 60))
    }

    /// "4h 12m" and "lost to delays"; nothing lost reads "No time lost to delays".
    static func lost(_ minutes: Int) -> (value: String, caption: String) {
        guard minutes > 0 else { return ("0", String(localized: "minutes lost to delays", bundle: .main)) }
        return (duration(minutes), String(localized: "lost to delays", bundle: .main))
    }

    static func timed(_ n: Int) -> String {
        n == 1 ? String(localized: "Over 1 flight with known arrival times", bundle: .main)
            : String(localized: "Over \(n) flights with known arrival times", bundle: .main)
    }

    static var punctualTitle: String { String(localized: "Most punctual airline", bundle: .main) }

    /// "92% on time or early, 12 flights".
    static func punctual(_ p: YearInReview.Punctual) -> String {
        String(localized: "\(p.onTimePercent)% on time or early over \(p.flights) flights", bundle: .main)
    }

    static var routeTitle: String { String(localized: "Most flown route", bundle: .main) }
    static var aircraftTitle: String { String(localized: "Most flown aircraft", bundle: .main) }

    static func times(_ n: Int) -> String {
        n == 1 ? String(localized: "1 flight", bundle: .main) : String(localized: "\(n) flights", bundle: .main)
    }

    static var footer: String { "SOMA FLIGHT" }

    static func fileName(_ card: YearInReview.Card, year: Int) -> String { "Soma Flight \(year) \(card.rawValue).png" }
}
