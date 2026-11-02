import Foundation
import FlightImportKit

/// What a free-text Add a flight search means, in any word order: "Paris New York 12 dec", "AF 84 demain",
/// "Air France CDG vendredi". Read in this order, each piece's words taken before the next: a time of
/// day, a flight number, a date, then airlines and places. Words nobody reads are kept, never blocking.
public struct SearchIntent: Sendable, Equatable {
    /// One piece the field shows as a chip.
    public enum Chip: Sendable, Hashable { case ident(String), airline(Airline), place([Airport]), day(LocalDay), time(Int) }

    /// "AF84".
    public var ident: String?
    public var airline: Airline?
    /// ICAO codes.
    public var origins: [String] = []
    public var destinations: [String] = []
    public var day: LocalDay?
    /// Minutes after midnight.
    public var timeOfDay: Int?
    /// In text order.
    public var chips: [Chip] = []
    /// Folded words nobody read, in text order.
    public var leftover: [String] = []
    /// For each chip, the indices of the folded words it read.
    private var chipWords: [[Int]] = []

    /// True when there is something to look up: a flight number, an airline or a place.
    public var isSearchable: Bool { ident != nil || airline != nil || !origins.isEmpty || !destinations.isEmpty }

    /// The text without the words `chip` read, other words as typed. The text unchanged when the chip is
    /// not one of these.
    public func removing(_ chip: Chip, from text: String) -> String {
        guard let k = chips.firstIndex(of: chip) else { return text }
        let read = Set(chipWords[k])
        let t = Self.tokenize(text)
        let kept = t.tokens.indices.filter { tok in
            let mine = t.owner.indices.filter { t.owner[$0] == tok }
            return mine.isEmpty || !mine.allSatisfy(read.contains)
        }
        return kept.map { String(t.tokens[$0]) }.joined(separator: " ")
    }

    // MARK: Parse

    /// Reads `text`. A bare day and month reads day first unless `monthFirst`.
    public static func parse(_ text: String, now: Date, tz: TimeZone, monthFirst: Bool, suggester: SearchSuggester) -> SearchIntent {
        let words = tokenize(text).words
        var intent = SearchIntent()
        // Indices of the words not read yet; each step sees them as one list.
        var free = Array(words.indices)
        var pieces: [(chip: Chip, at: [Int])] = []
        var unread: [Int] = []
        func view() -> [Substring] { free.map { words[$0] } }
        func take(_ r: Range<Int>) -> [Int] {
            let ids = Array(free[r])
            free.removeSubrange(r)
            return ids
        }

        if let t = DateWords.timeOfDay(view()) {
            intent.timeOfDay = t.minutes
            pieces.append((.time(t.minutes), take(t.used)))
        }

        if let (ident, used) = ident(view(), now: now, tz: tz, monthFirst: monthFirst, suggester: suggester) {
            intent.ident = ident
            pieces.append((.ident(ident), take(used)))
        }

        if let d = DateWords.day(view(), now: now, tz: tz, monthFirst: monthFirst) {
            intent.day = d.day
            pieces.append((.day(d.day), take(d.used)))
        }

        // Airlines and places, left to right, the longest phrase first.
        enum Role { case origin, destination }
        var places: [(airports: [Airport], at: [Int], role: Role?)] = []
        let v = view(), ids = free
        var i = 0
        var hint: Role?
        while i < v.count {
            let w = String(v[i])
            if toWords.contains(w) { hint = .destination; i += 1; continue }
            if fromWords.contains(w) { hint = .origin; i += 1; continue }
            if fillerWords.contains(w) { i += 1; continue }
            if DateWords.isCalendarWord(v[i]) { unread.append(ids[i]); i += 1; hint = nil; continue }
            guard let (name, n) = name(v, at: i, suggester: suggester) else {
                unread.append(ids[i]); i += 1; hint = nil; continue
            }
            let at = Array(ids[i..<(i + n)])
            switch name {
            case .airline(let a) where intent.airline == nil:
                intent.airline = a
                pieces.append((.airline(a), at))
            case .place(let p) where places.count < 2:
                places.append((p, at, hint))
            default:
                unread += at
            }
            i += n
            hint = nil
        }

        // A place after "to" is the destination, after "from" the origin; the rest fill in order.
        var origin = places.firstIndex { $0.role == .origin }
        var destination = places.firstIndex { $0.role == .destination }
        for k in places.indices where k != origin && k != destination {
            if origin == nil { origin = k } else if destination == nil { destination = k }
        }
        if let origin { intent.origins = places[origin].airports.map(\.id) }
        if let destination { intent.destinations = places[destination].airports.map(\.id) }
        for p in places { pieces.append((.place(p.airports), p.at)) }

        pieces.sort { ($0.at.min() ?? 0) < ($1.at.min() ?? 0) }
        intent.chips = pieces.map(\.chip)
        intent.chipWords = pieces.map(\.at)
        intent.leftover = unread.sorted().map { String(words[$0]) }
        return intent
    }

    /// The folded words of `text`, each with the index of the space-separated token it came from, so a
    /// chip's words map back to the text as typed.
    private static func tokenize(_ text: String) -> (tokens: [Substring], words: [Substring], owner: [Int]) {
        let tokens = text.split(whereSeparator: \.isWhitespace)
        var words: [Substring] = [], owner: [Int] = []
        for (k, t) in tokens.enumerated() {
            for w in SearchText.words(SearchText.fold(String(t))) {
                words.append(w)
                owner.append(k)
            }
        }
        return (tokens, words, owner)
    }

    // MARK: Flight numbers

    /// The first flight number in `w` ("af 84", "af84", "u2 1234"), by the rule of `FlightQuery.parse`,
    /// when its code is an airline's. A three-letter code that is also an airport's, and a code that is
    /// also a small word ("de", "la"), yield to a date that reads its number ("cdg 12 dec" is CDG on
    /// 12 December, "vol de 12 dec" the 12th; "dal 220" is Delta 220, "la 800" LATAM 800).
    private static func ident(_ w: [Substring], now: Date, tz: TimeZone, monthFirst: Bool,
                              suggester: SearchSuggester) -> (String, Range<Int>)? {
        func airlineCode(_ c: Substring) -> Bool {
            let s = String(c)
            if suggester.airline(code: s) != nil { return true }
            return s.count == 2 && !toWords.contains(s) && !fromWords.contains(s) && !fillerWords.contains(s)
        }
        func yieldsToDate(_ code: Substring, number: Int) -> Bool {
            let s = String(code)
            let word = toWords.contains(s) || fromWords.contains(s) || fillerWords.contains(s)
            let airport = code.count == 3 && code.allSatisfy(\.isLetter) && suggester.airport(code: s) != nil
            guard word || airport,
                  let d = DateWords.day(w, now: now, tz: tz, monthFirst: monthFirst) else { return false }
            return d.used.contains(number)
        }
        for i in w.indices {
            if let m = w[i].wholeMatch(of: /([a-z]{2,3}|[a-z][0-9]|[0-9][a-z])([0-9]{1,4})/), airlineCode(m.1) {
                return ((m.1 + m.2).uppercased(), i..<(i + 1))
            }
            if i + 1 < w.count, w[i].wholeMatch(of: /[a-z]{2,3}|[a-z][0-9]|[0-9][a-z]/) != nil,
               w[i + 1].wholeMatch(of: /[0-9]{1,4}/) != nil, airlineCode(w[i]), !yieldsToDate(w[i], number: i + 1) {
                return ((w[i] + w[i + 1]).uppercased(), i..<(i + 2))
            }
        }
        return nil
    }

    // MARK: Names

    private enum Name { case airline(Airline), place([Airport]) }

    /// What the phrase starting at `i` names, and how many words it takes (at most four, the longest
    /// first). Whole names first, an airline's before a city's ("Delta Atlanta"), then short names (a
    /// large airport's before an airline's),
    /// then a lone code (two letters an airline, three or four an airport), then typos.
    private static func name(_ w: [Substring], at i: Int, suggester: SearchSuggester) -> (Name, Int)? {
        let longest = min(4, w.count - i)
        func phrase(_ n: Int) -> String {
            let p = w[i..<(i + n)].joined(separator: " ")
            return cityNames[p] ?? p
        }
        for n in stride(from: longest, through: 1, by: -1) {
            let p = phrase(n)
            let line = suggester.airline(named: p), place = suggester.airports(named: p)
            if let line, line.match == .exact { return (.airline(line.airline), n) }
            if let place, place.match == .exact { return (.place(place.airports), n) }
            // A large airport named by the phrase beats an airline's short name: "brussels" and
            // "kuwait" are the places, "delta" (Delta County Airport is medium) the airline.
            if let line, line.match == .short {
                if let place, place.match == .short, place.airports.allSatisfy({ AirportSizes.bundled.size($0.id) == .large }) {
                    return (.place(place.airports), n)
                }
                return (.airline(line.airline), n)
            }
            if let place, place.match == .short { return (.place(place.airports), n) }
        }
        let word = w[i]
        if word.allSatisfy({ $0.isASCII && $0.isLetter }) {
            if word.count == 2, let a = suggester.airline(code: String(word)) { return (.airline(a), 1) }
            if (3...4).contains(word.count), let a = suggester.airport(code: String(word)) { return (.place([a]), 1) }
        }
        for n in stride(from: longest, through: 1, by: -1) {
            let p = phrase(n)
            if let place = suggester.airports(named: p) { return (.place(place.airports), n) }
            if let line = suggester.airline(named: p) { return (.airline(line.airline), n) }
        }
        return nil
    }

    /// Words before a destination.
    private static let toWords: Set<String> = ["to", "vers", "a", "pour", "for", "towards"]
    /// Words before an origin.
    private static let fromWords: Set<String> = ["from", "de", "depuis", "du"]
    /// Words that carry nothing: read silently, never left over.
    private static let fillerWords: Set<String> = [
        "flight", "flights", "vol", "vols", "the", "le", "la", "les", "on", "at", "in", "et", "and", "en",
        "au", "aux", "des", "un", "une",
    ]

    /// French names of cities the bundled list writes in English.
    private static let cityNames: [String: String] = [
        "londres": "london", "geneve": "geneva", "bruxelles": "brussels", "vienne": "vienna", "moscou": "moscow",
        "lisbonne": "lisbon", "varsovie": "warsaw", "copenhague": "copenhagen", "pekin": "beijing",
        "athenes": "athens", "venise": "venice", "munchen": "munich", "barcelone": "barcelona",
        "edimbourg": "edinburgh", "singapour": "singapore",
    ]
}
