import Foundation

/// A flight the user already knows: one they follow or one in their Passport. Search suggests these
/// as they type a flight number ("AF 8" offers AF 83, AF 84 and AF 85 from the history).
public struct KnownFlight: Sendable, Hashable {
    /// As stored: "AF84".
    public var ident: String
    /// ICAO codes.
    public var origin: String
    public var destination: String
    /// When it flew or flies; the newest of the same flight is kept.
    public var date: Date?
    public var followed: Bool

    public init(ident: String, origin: String, destination: String, date: Date?, followed: Bool) {
        self.ident = ident; self.origin = origin; self.destination = destination; self.date = date; self.followed = followed
    }

    public init(_ f: Flight) {
        self.init(ident: f.ident, origin: f.originIcao, destination: f.destinationIcao,
                  date: f.scheduledOut, followed: true)
    }

    public init(_ f: PastFlight) {
        self.init(ident: f.ident, origin: f.originIcao, destination: f.destinationIcao, date: f.date, followed: false)
    }

    /// The followed flights, then the Passport's.
    public static func list(followed: [Flight], past: [PastFlight]) -> [KnownFlight] {
        followed.map(KnownFlight.init) + past.filter { !$0.ident.isEmpty }.map(KnownFlight.init)
    }
}

/// One row the search field offers while the user types.
public enum SearchSuggestion: Sendable, Hashable, Identifiable {
    /// Look this flight number up; `known` is the followed or past flight it came from, nil for what
    /// the user typed.
    case flight(ident: String, known: KnownFlight?)
    /// Fills the airline's code, ready for the number.
    case airline(Airline)
    /// Fills the airport's code, ready for "Flights from" or a destination.
    case airport(Airport)
    /// Opens the airport's board.
    case board(Airport)
    /// The origin's departures to the destination today.
    case route(Airport, Airport)
    /// A past search, run again.
    case recent(String)

    public var id: String {
        switch self {
        case .flight(let ident, let k): "flight:\(ident):\(k.map { "\($0.origin)-\($0.destination)" } ?? "typed")"
        case .airline(let a): "airline:\(a.id)"
        case .airport(let a): "airport:\(a.id)"
        case .board(let a): "board:\(a.id)"
        case .route(let o, let d): "route:\(o.id)-\(d.id)"
        case .recent(let q): "recent:\(q)"
        }
    }

    /// What the field reads once this row is picked: an airline's or airport's code and a space (the
    /// keyboard stays up for the rest), a flight number, a route as two codes. nil for the board, which
    /// opens a screen instead.
    public var fill: String? {
        switch self {
        case .flight(let ident, _): ident
        case .airline(let a): "\(a.iata ?? a.id) "
        case .airport(let a): "\(a.iata ?? a.id) "
        case .board: nil
        case .route(let o, let d): "\(o.iata ?? o.id) \(d.iata ?? d.id)"
        case .recent(let q): q
        }
    }

    /// True when picking it runs a search (the field holds a whole query, not the start of one).
    public var searches: Bool {
        switch self {
        case .flight, .route, .recent: true
        case .airline, .airport, .board: false
        }
    }
}

/// The suggestions for one text, in groups like the reference's Add Flight list.
public struct SearchSuggestions: Sendable, Equatable {
    public enum Kind: String, Sendable, CaseIterable {
        case flights, airlines, airports, routes, recent

        public var title: String {
            switch self {
            case .flights: "Flights"
            case .airlines: "Airlines"
            case .airports: "Airports and cities"
            case .routes: "Routes"
            case .recent: "Recent searches"
            }
        }

        /// At most this many rows per group.
        var limit: Int {
            switch self {
            case .flights: 5
            case .airlines: 4
            case .airports: 6
            case .routes: 4
            case .recent: 3
            }
        }
    }

    public struct Group: Sendable, Equatable, Identifiable {
        public var kind: Kind
        public var items: [SearchSuggestion]
        public var id: Kind { kind }
    }

    public var groups: [Group]

    public static let empty = SearchSuggestions(groups: [])

    /// What the return key picks.
    public var top: SearchSuggestion? { groups.first?.items.first }
    public var all: [SearchSuggestion] { groups.flatMap(\.items) }
    public var count: Int { groups.reduce(0) { $0 + $1.items.count } }
    public var isEmpty: Bool { groups.isEmpty }

    public func items(_ kind: Kind) -> [SearchSuggestion] { groups.first { $0.kind == kind }?.items ?? [] }
}

/// Ranks what the field should offer for a text, on the device and without the network: flight numbers
/// (the one typed, then the user's followed and past flights), airlines (by code, name or callsign),
/// airports and cities (by code, city or name), routes ("CDG SFO", "Paris to San Francisco") and recent
/// searches. Names forgive accents ("Zurich" finds Zürich) and, from four letters, a typo or two.
///
/// Built once over the bundled lists (folding 4,000 names is the slow part); `suggest` is pure.
public struct SearchSuggester: Sendable {
    struct AirportEntry: Sendable {
        var airport: Airport
        var city: String
        var name: String
        var words: [String]
        var typo: TypoKeys
        /// Large airports first, those with no IATA code (strips and heliports) last.
        var boost: Int
        var size: AirportSize
    }

    /// What a typo is measured against, split once: each word for a one-word query, the whole names
    /// for a query of several words.
    struct TypoKeys: Sendable {
        var words: [[Unicode.Scalar]]
        var whole: [[Unicode.Scalar]]

        init(words: [String], whole: [String]) {
            self.words = words.map { Array($0.unicodeScalars) }
            self.whole = whole.filter { !$0.isEmpty }.map { Array($0.unicodeScalars) }
        }

        /// The fewest typos from `q` to the start of a key, within `limit`. Only keys that start with
        /// the query's first letter count: people rarely miss the first one, and it keeps this fast.
        func distance(_ q: [Unicode.Scalar], multiword: Bool, limit: Int) -> Int? {
            guard let first = q.first else { return nil }
            var best: Int?
            for key in multiword ? whole : words where key.first == first {
                if let d = SearchText.prefixDistance(q, key, limit: best.map { $0 - 1 } ?? limit) {
                    best = d
                    if d == 0 { break }
                }
            }
            return best
        }
    }

    struct AirlineEntry: Sendable {
        var airline: Airline
        var name: String
        var words: [String]
        var typo: TypoKeys
        var callsign: String
        /// The name without a generic tail: "delta" for Delta Air Lines; nil when there is none.
        var short: String?
    }

    private let airports: [AirportEntry]
    private let airlines: [AirlineEntry]
    private let airportByCode: [String: Airport]
    private let airlineByCode: [String: Airline]
    /// Indices into `airports` by folded city.
    private let airportsByCity: [String: [Int]]

    public init(airports: [Airport], airlines: [Airline], sizes: AirportSizes = .bundled) {
        self.airports = airports.map { a in
            let city = SearchText.fold(a.city), name = SearchText.fold(a.name)
            let size = sizes.size(a.id)
            let boost = (size == .large ? 60 : size == .medium ? 20 : 0) - (a.iata == nil ? 40 : 0)
            let words = Array(Set(SearchText.words(city).map(String.init) + SearchText.words(name).map(String.init)))
            return AirportEntry(airport: a, city: city, name: name, words: words,
                                typo: TypoKeys(words: words, whole: [city, name]), boost: boost, size: size)
        }
        self.airlines = airlines.map { a in
            let name = SearchText.fold(a.name)
            let words = SearchText.words(name).map(String.init)
            let tail = Self.airlineTails.first { name.hasSuffix($0) && name.count > $0.count }
            return AirlineEntry(airline: a, name: name, words: words, typo: TypoKeys(words: words, whole: [name]),
                                callsign: SearchText.fold(a.callsign ?? ""), short: tail.map { String(name.dropLast($0.count)) })
        }
        var byCity: [String: [Int]] = [:]
        for (i, e) in self.airports.enumerated() where !e.city.isEmpty { byCity[e.city, default: []].append(i) }
        airportsByCity = byCity
        var codes: [String: Airport] = [:]
        for a in airports { codes[a.id.uppercased()] = a }
        for a in airports { if let i = a.iata?.uppercased(), codes[i] == nil { codes[i] = a } }
        airportByCode = codes
        var lines: [String: Airline] = [:]
        for a in airlines { lines[a.id.uppercased()] = a }
        for a in airlines { if let i = a.iata?.uppercased(), lines[i] == nil { lines[i] = a } }
        airlineByCode = lines
    }

    /// Over the bundled airports and airlines, built once per process.
    public static func bundled() -> SearchSuggester { shared }
    private static let shared = SearchSuggester(airports: AirportDirectory.bundled().all,
                                                airlines: ReferenceData.bundled().airlines)

    // MARK: Suggest

    /// A row with its score: higher ranks first, and a group ranks by its best row.
    struct Scored {
        var kind: SearchSuggestions.Kind
        var item: SearchSuggestion
        var score: Int
        /// Breaks ties: smaller first.
        var tie: String
    }

    /// The groups for `text`. Empty for blank text (the screen shows Frequently Used then).
    /// - Parameters:
    ///   - known: followed and past flights, for flight numbers and an airport's usual destinations.
    ///   - recent: past searches, newest first.
    public func suggest(_ text: String, known: [KnownFlight] = [], recent: [String] = []) -> SearchSuggestions {
        let q = SearchText.fold(text)
        guard !q.isEmpty else { return .empty }
        var rows: [Scored] = []
        rows += flights(text, known: known)
        let route = routeRows(text, known: known)
        rows += route
        // "CDG to ..." is about the route, not every airport named "to".
        if route.isEmpty {
            rows += airlineRows(q)
            rows += airportRows(q)
        }
        rows += recentRows(q, recent: recent)
        return Self.group(rows)
    }

    /// A query the screen may look up live, after a pause: a complete flight number, or a route whose
    /// two ends are certain (codes, or cities named in full). nil for anything else, which waits for
    /// the user to pick a row or press return.
    public func liveQuery(_ text: String, date: Date) -> FlightQuery? {
        switch FlightQuery.parse(text, date: date) {
        case .ident(let i, let d):
            return .ident(i, date: d)
        case .route(let o, let d, let day):
            guard let from = airportByCode[o], let to = airportByCode[d], from.id != to.id else { return nil }
            return .route(origin: from.id, destination: to.id, date: day)
        case .airport, nil:
            guard let (o, d) = certainRoute(text) else { return nil }
            return .route(origin: o.id, destination: d.id, date: date)
        }
    }

    // MARK: Flights

    private func flights(_ text: String, known: [KnownFlight]) -> [Scored] {
        let typed = SearchText.ident(text)
        guard typed.count >= 2, typed.first?.isLetter == true || typed.dropFirst().first?.isLetter == true else { return [] }
        let parsed: String? = if case .ident(let i, _) = FlightQuery.parse(text, date: .now) { i } else { nil }
        var rows: [Scored] = []
        var seen: Set<String> = []
        // The followed first, then the newest: the first of each ident and route stays.
        let ordered = known.sorted {
            ($0.followed ? 0 : 1, -($0.date?.timeIntervalSince1970 ?? 0)) < ($1.followed ? 0 : 1, -($1.date?.timeIntervalSince1970 ?? 0))
        }
        var exactKnown = false
        for k in ordered {
            let forms = identForms(k.ident)
            guard let form = forms.first(where: { $0.hasPrefix(typed) }) else { continue }
            let key = "\(SearchText.ident(k.ident))|\(k.origin)|\(k.destination)"
            guard seen.insert(key).inserted else { continue }
            let exact = form == typed
            exactKnown = exactKnown || exact
            // A number typed: its flights rank high. Only the airline's code: under the airline itself.
            let hasDigit = typed.contains(where: \.isNumber)
            let score = exact ? 1100 : hasDigit ? 950 : 600
            rows.append(Scored(kind: .flights, item: .flight(ident: SearchText.ident(k.ident), known: k),
                               score: score + (k.followed ? 5 : 0), tie: Self.identTie(k.ident)))
        }
        if let parsed, !exactKnown {
            // "AF 8" is more likely the start of a known AF 84 than a flight AF 8: the known come first.
            let score = rows.contains { $0.score >= 950 } ? 940 : 1100
            rows.append(Scored(kind: .flights, item: .flight(ident: parsed, known: nil), score: score, tie: ""))
        }
        return rows
    }

    /// A flight number in the forms it may be typed: as stored, and with the airline's other code
    /// ("AFR84" also reads "AF84").
    private func identForms(_ ident: String) -> [String] {
        let id = SearchText.ident(ident)
        let code = String(id.prefix { $0.isLetter })
        let number = id.dropFirst(code.count)
        var forms = [id]
        if let a = airlineByCode[code] {
            for c in [a.iata, a.id].compactMap({ $0 }) where c != code { forms.append(c + number) }
        }
        return forms
    }

    /// "AF83" before "AF84" before "AF840".
    private static func identTie(_ ident: String) -> String {
        let id = SearchText.ident(ident)
        let code = id.prefix { !$0.isNumber }
        let digits = id.dropFirst(code.count)
        return "\(code)\(String(repeating: "0", count: max(0, 5 - digits.count)))\(digits)"
    }

    // MARK: Airlines

    private func airlineRows(_ q: String) -> [Scored] {
        let code = q.uppercased().replacingOccurrences(of: " ", with: "")
        let qWords = SearchText.words(q)
        var rows: [Scored] = []
        var typoCandidates: [AirlineEntry] = []
        for e in airlines {
            let a = e.airline
            var score: Int?
            if a.iata?.uppercased() == code, !q.contains(" ") { score = 1000 }
            else if a.id.uppercased() == code, !q.contains(" ") { score = 980 }
            else if e.name == q { score = 900 }
            else if e.name.hasPrefix(q) { score = 850 }
            else if e.words.contains(where: { $0.hasPrefix(q) }) { score = 750 }
            else if !e.callsign.isEmpty, e.callsign.hasPrefix(q) { score = 700 }
            else if qWords.count > 1, qWords.allSatisfy({ w in e.words.contains { $0.hasPrefix(w) } }) { score = 650 }
            if let score {
                rows.append(Scored(kind: .airlines, item: .airline(a), score: score, tie: e.name))
            } else {
                typoCandidates.append(e)
            }
        }
        let limit = Self.typoLimit(q)
        if limit > 0, rows.count < SearchSuggestions.Kind.airlines.limit {
            let scalars = Array(q.unicodeScalars), multi = q.contains(" ")
            for e in typoCandidates {
                guard let d = e.typo.distance(scalars, multiword: multi, limit: limit) else { continue }
                rows.append(Scored(kind: .airlines, item: .airline(e.airline), score: 400 - 50 * d, tie: e.name))
            }
        }
        return rows
    }

    // MARK: Airports

    /// Every airport matching `q`, scored: the code, then the city, then the name, then typos.
    private func airportMatches(_ q: String) -> [(entry: AirportEntry, score: Int)] {
        let code = q.uppercased()
        let isCode = !q.contains(" ") && (3...4).contains(q.count) && q.allSatisfy(\.isLetter)
        let qWords = SearchText.words(q)
        var out: [(AirportEntry, Int)] = []
        var rest: [AirportEntry] = []
        for e in airports {
            let a = e.airport
            var score: Int?
            if isCode, a.iata == code { score = 1000 }
            else if isCode, a.id == code { score = 980 }
            else if e.city == q { score = 900 }
            else if e.city.hasPrefix(q) { score = 800 }
            else if e.name.hasPrefix(q) { score = 760 }
            else if e.words.contains(where: { $0.hasPrefix(q) }) { score = 700 }
            else if qWords.count > 1, qWords.allSatisfy({ w in e.words.contains { $0.hasPrefix(w) } }) { score = 650 }
            else if (2...3).contains(q.count), !q.contains(" "), a.iata?.hasPrefix(code) == true { score = 500 }
            if let score { out.append((e, score + e.boost)) } else { rest.append(e) }
        }
        let limit = Self.typoLimit(q)
        if limit > 0, out.count < SearchSuggestions.Kind.airports.limit {
            let scalars = Array(q.unicodeScalars), multi = q.contains(" ")
            for e in rest {
                guard let d = e.typo.distance(scalars, multiword: multi, limit: limit) else { continue }
                out.append((e, 400 - 50 * d + e.boost))
            }
        }
        return out.sorted { ($1.1, Self.airportTie($0.0.airport)) < ($0.1, Self.airportTie($1.0.airport)) }
    }

    private static func airportTie(_ a: Airport) -> String { a.id }

    /// Typos are for names: none for text with a digit (a flight number) or under four letters.
    private static func typoLimit(_ q: String) -> Int {
        q.contains(where: \.isNumber) ? 0 : SearchText.allowedTypos(q.count)
    }

    /// Airports for a picker (Add Past Flight's origin and destination), best first: the code, the
    /// city, the name, then typos, large airports before small ones.
    public func airports(matching text: String, limit: Int) -> [Airport] {
        let q = SearchText.fold(text)
        guard !q.isEmpty else { return [] }
        return airportMatches(q).prefix(limit).map(\.entry.airport)
    }

    private func airportRows(_ q: String) -> [Scored] {
        let matches = airportMatches(q)
        var rows = matches.map { Scored(kind: .airports, item: .airport($0.entry.airport), score: $0.score, tie: $0.entry.airport.id) }
        // An airport named by its exact code also offers its board, right under it.
        if let first = matches.first, first.score >= 980 {
            rows.append(Scored(kind: .airports, item: .board(first.entry.airport), score: first.score - 1, tie: first.entry.airport.id))
        }
        return rows
    }

    /// The best airport for one end of a route, if any text match finds one.
    private func bestAirport(_ part: String) -> (airport: Airport, score: Int)? {
        let q = SearchText.fold(part)
        guard !q.isEmpty else { return nil }
        return airportMatches(q).first.map { ($0.entry.airport, $0.score) }
    }

    // MARK: Routes

    /// The text split around " to ", a dash or an arrow, or two bare codes ("CDG SFO"). The second part
    /// may be empty ("CDG to", "CDG " once an airport was picked).
    private func routeParts(_ text: String) -> (String, String)? {
        let lower = text.lowercased()
        for sep in [" to ", "\u{2192}", ">", "-"] {
            if let r = lower.range(of: sep) {
                let a = String(lower[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
                let b = String(lower[r.upperBound...]).trimmingCharacters(in: .whitespaces)
                // A dash splits only after a code ("CDG-SFO"): names carry dashes ("Dallas-Fort Worth").
                if sep == "-", !isAirportCode(a) { continue }
                if !a.isEmpty { return (a, b) }
            }
        }
        if lower.hasSuffix(" to") {
            return (String(lower.dropLast(3)).trimmingCharacters(in: .whitespaces), "")
        }
        let words = lower.split(separator: " ")
        // "CDG " (an airport just picked) or "CDG san f" (its destination being typed).
        if let first = words.first, isAirportCode(String(first)) {
            if words.count == 1, lower.hasSuffix(" ") { return (String(first), "") }
            // "DAL 220" is a flight number (Delta's ICAO code), not Dallas Love Field to somewhere.
            let rest = words.dropFirst().joined(separator: " ")
            if words.count >= 2, !rest.contains(where: \.isNumber) { return (String(first), rest) }
        }
        return nil
    }

    private func isAirportCode(_ s: String) -> Bool {
        (3...4).contains(s.count) && s.allSatisfy(\.isLetter) && airportByCode[s.uppercased()] != nil
    }

    private func routeRows(_ text: String, known: [KnownFlight]) -> [Scored] {
        guard let (from, to) = routeParts(text), let origin = bestAirport(from), origin.score >= 650 else { return [] }
        let o = origin.airport
        guard !to.isEmpty else {
            // An origin alone: its board, then where the user has flown from it.
            var rows = [Scored(kind: .airports, item: .board(o), score: 1100, tie: "")]
            var seen: Set<String> = [o.id]
            for k in known where k.origin == o.id && seen.insert(k.destination).inserted {
                guard let d = airportByCode[k.destination] else { continue }
                rows.append(Scored(kind: .routes, item: .route(o, d), score: 700, tie: d.id))
            }
            return rows
        }
        let q = SearchText.fold(to)
        guard !q.isEmpty else { return [] }
        let certainOrigin = origin.score >= 900
        return airportMatches(q).prefix(SearchSuggestions.Kind.routes.limit).compactMap { m in
            guard m.entry.airport.id != o.id else { return nil }
            let certain = certainOrigin && m.score >= 900
            return Scored(kind: .routes, item: .route(o, m.entry.airport), score: (certain ? 1050 : 850) + m.score / 100,
                          tie: m.entry.airport.id)
        }
    }

    /// Both ends of a route typed in full (a code, or a city's whole name): safe to look up live.
    private func certainRoute(_ text: String) -> (Airport, Airport)? {
        guard let (from, to) = routeParts(text), !to.isEmpty,
              let o = bestAirport(from), o.score >= 900, let d = bestAirport(to), d.score >= 900,
              o.airport.id != d.airport.id else { return nil }
        return (o.airport, d.airport)
    }

    // MARK: Lookups

    /// How a lookup read a name: through a typo, by a short form, or whole.
    enum NameMatch: Int, Comparable, Sendable {
        case typo, short, exact
        static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
    }

    /// Generic tails an airline is often named without.
    private static let airlineTails = [" air lines", " airlines", " airline", " airways"]

    /// The airline with this code (IATA or ICAO).
    func airline(code: String) -> Airline? { airlineByCode[code.uppercased()] }

    /// The airport with this code (IATA or ICAO).
    func airport(code: String) -> Airport? { airportByCode[code.uppercased()] }

    /// The airline named `phrase` in full ("air france"), by its name without a generic tail ("delta"),
    /// or within the typos `SearchText.allowedTypos` allows.
    func airline(named phrase: String) -> (airline: Airline, match: NameMatch)? {
        let q = SearchText.fold(phrase)
        guard !q.isEmpty else { return nil }
        if let e = airlines.first(where: { $0.name == q }) { return (e.airline, .exact) }
        if let e = airlines.first(where: { $0.short == q }) { return (e.airline, .short) }
        let limit = Self.typoLimit(q)
        guard limit > 0 else { return nil }
        let scalars = Array(q.unicodeScalars)
        var best: (Airline, Int)?
        for e in airlines {
            for key in [e.name, e.short].compactMap({ $0 }) {
                guard let d = Self.wholeDistance(scalars, key, limit: limit), d < (best?.1 ?? .max) else { continue }
                best = (e.airline, d)
            }
        }
        return best.map { ($0.0, .typo) }
    }

    /// The airports `phrase` names: a city's ("paris" gives CDG and Orly, see `cityAirports`), one
    /// airport by the words of its name ("heathrow"), or a city within the typos allowed ("zurih").
    func airports(named phrase: String) -> (airports: [Airport], match: NameMatch)? {
        let q = SearchText.fold(phrase)
        guard !q.isEmpty else { return nil }
        if let ids = airportsByCity[q] { return (cityAirports(ids), .exact) }
        let qWords = SearchText.words(q).map(String.init)
        if q.count >= 4, qWords.contains(where: { !Self.genericAirportWords.contains($0) }),
           let e = airports.filter({ e in qWords.allSatisfy { e.words.contains($0) } }).max(by: { $0.boost < $1.boost }) {
            return ([e.airport], .short)
        }
        let limit = Self.typoLimit(q)
        guard limit > 0 else { return nil }
        let scalars = Array(q.unicodeScalars)
        var best: (city: String, d: Int, boost: Int)?
        for e in airports where !e.city.isEmpty {
            guard let d = Self.wholeDistance(scalars, e.city, limit: limit) else { continue }
            if let b = best, (d, -e.boost) >= (b.d, -b.boost) { continue }
            best = (e.city, d, e.boost)
        }
        guard let best, let ids = airportsByCity[best.city] else { return nil }
        return (cityAirports(ids), .typo)
    }

    /// Words that name no airport on their own.
    private static let genericAirportWords: Set<String> = [
        "airport", "international", "intl", "regional", "municipal", "airfield", "field", "aeroport", "aeropuerto",
        "air", "base", "heliport", "county", "city", "san", "saint", "new", "the", "de", "la",
    ]

    /// A city's airports: those that are not small, in the country of its largest (London is not also
    /// London, Ontario), large first; the largest alone when every one is small.
    private func cityAirports(_ ids: [Int]) -> [Airport] {
        let entries = ids.map { airports[$0] }
        guard let top = entries.max(by: { ($0.boost, $1.airport.id) < ($1.boost, $0.airport.id) }) else { return [] }
        let rank: (AirportSize) -> Int = { $0 == .large ? 0 : $0 == .medium ? 1 : 2 }
        let kept = entries.filter { $0.size != .small && $0.airport.country == top.airport.country }
        guard !kept.isEmpty else { return [top.airport] }
        return kept.sorted { (rank($0.size), $0.airport.id) < (rank($1.size), $1.airport.id) }.map(\.airport)
    }

    /// The typos from `q` to the whole of `key`, within `limit`; the first letters must agree.
    private static func wholeDistance(_ q: [Unicode.Scalar], _ key: String, limit: Int) -> Int? {
        let k = Array(key.unicodeScalars)
        guard k.first == q.first, abs(k.count - q.count) <= limit else { return nil }
        return SearchText.prefixDistance(q, k, limit: limit)
    }

    // MARK: Recent

    private func recentRows(_ q: String, recent: [String]) -> [Scored] {
        let ident = SearchText.ident(q)
        return recent.enumerated().compactMap { i, r in
            let f = SearchText.fold(r)
            guard f.hasPrefix(q) || (!ident.isEmpty && SearchText.ident(r).hasPrefix(ident)) else { return nil }
            return Scored(kind: .recent, item: .recent(r), score: 720 - i, tie: "")
        }
    }

    // MARK: Grouping

    /// Rows ranked within their group, capped, the same row once (its best score), groups by their best row.
    static func group(_ rows: [Scored]) -> SearchSuggestions {
        var best: [String: Scored] = [:]
        for r in rows {
            if let old = best[r.item.id], old.score >= r.score { continue }
            best[r.item.id] = r
        }
        var groups: [(kind: SearchSuggestions.Kind, rows: [Scored])] = []
        for kind in SearchSuggestions.Kind.allCases {
            let mine = best.values.filter { $0.kind == kind }
                .sorted { ($1.score, $0.tie, $0.item.id) < ($0.score, $1.tie, $1.item.id) }
            if !mine.isEmpty { groups.append((kind, Array(mine.prefix(kind.limit)))) }
        }
        let order = SearchSuggestions.Kind.allCases
        groups.sort {
            let a = $0.rows[0].score, b = $1.rows[0].score
            return a != b ? a > b : order.firstIndex(of: $0.kind)! < order.firstIndex(of: $1.kind)!
        }
        return SearchSuggestions(groups: groups.map { .init(kind: $0.kind, items: $0.rows.map(\.item)) })
    }
}
