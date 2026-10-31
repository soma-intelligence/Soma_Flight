import Foundation
import Testing
@testable import FlightKit

/// The search field's ranking over the bundled lists: flight numbers from the history, airlines by code,
/// name and callsign, airports and cities with accents folded and typos forgiven, routes, recent searches,
/// and the live query a pause may look up.
@Suite struct SearchSuggesterTests {
    static let suggester = SearchSuggester.bundled()
    static let date = Date(timeIntervalSince1970: 1_793_361_600)

    static let known: [KnownFlight] = [
        KnownFlight(ident: "AF84", origin: "LFPG", destination: "KSFO", date: date, followed: true),
        KnownFlight(ident: "AF83", origin: "KSFO", destination: "LFPG", date: date.addingTimeInterval(-86_400 * 30), followed: false),
        KnownFlight(ident: "AF85", origin: "LFPG", destination: "KSFO", date: date.addingTimeInterval(-86_400 * 60), followed: false),
        KnownFlight(ident: "AF83", origin: "KSFO", destination: "LFPG", date: date.addingTimeInterval(-86_400 * 90), followed: false),
        KnownFlight(ident: "UA990", origin: "KSFO", destination: "LFPG", date: date.addingTimeInterval(-86_400 * 10), followed: false),
        KnownFlight(ident: "BAW286", origin: "KSFO", destination: "EGLL", date: date.addingTimeInterval(-86_400 * 5), followed: false),
    ]

    static func suggest(_ text: String, recent: [String] = []) -> SearchSuggestions {
        suggester.suggest(text, known: known, recent: recent)
    }

    static func airportIDs(_ s: SearchSuggestions) -> [String] {
        s.items(.airports).compactMap { if case .airport(let a) = $0 { a.id } else { nil } }
    }

    static func airlineIDs(_ s: SearchSuggestions) -> [String] {
        s.items(.airlines).compactMap { if case .airline(let a) = $0 { a.id } else { nil } }
    }

    static func idents(_ s: SearchSuggestions) -> [String] {
        s.items(.flights).compactMap { if case .flight(let i, _) = $0 { i } else { nil } }
    }

    static func routes(_ s: SearchSuggestions) -> [String] {
        s.items(.routes).compactMap { if case .route(let o, let d) = $0 { "\(o.id)-\(d.id)" } else { nil } }
    }

    // MARK: Text

    @Test func foldsAccentsCaseAndPunctuation() {
        #expect(SearchText.fold("Zürich") == "zurich")
        #expect(SearchText.fold("  Chicago O'Hare ") == "chicago ohare")
        #expect(SearchText.fold("Charles-de-Gaulle") == "charles de gaulle")
        #expect(SearchText.fold("CANCÚN") == "cancun")
        #expect(SearchText.fold("--") == "")
        #expect(SearchText.ident("af 84") == "AF84")
        #expect(SearchText.ident("ua-1527") == "UA1527")
    }

    @Test(arguments: [
        ("zurih", "zurich", 1, 1), ("frnace", "france", 1, 1), ("france", "france", 1, 0), ("fran", "france", 1, 0),
        ("heathorw", "heathrow", 2, 1), ("lodnon", "london", 1, 1), ("xyz", "abc", 1, nil), ("parsi", "paris", 1, 1),
        ("abcdef", "abc", 1, nil), ("", "paris", 1, 0),
    ] as [(String, String, Int, Int?)])
    func prefixDistance(_ q: String, _ word: String, _ limit: Int, _ expected: Int?) {
        #expect(SearchText.prefixDistance(q, word, limit: limit) == expected)
    }

    @Test func typoAllowanceGrowsWithLength() {
        #expect(SearchText.allowedTypos(3) == 0)
        #expect(SearchText.allowedTypos(4) == 1)
        #expect(SearchText.allowedTypos(6) == 1)
        #expect(SearchText.allowedTypos(7) == 2)
    }

    // MARK: Flights

    @Test func aPartialNumberSuggestsTheHistory() {
        let s = Self.suggest("AF 8")
        #expect(s.groups.first?.kind == .flights)
        #expect(Set(Self.idents(s).prefix(3)) == ["AF83", "AF84", "AF85"])
        // The followed flight first; one row per flight and route (AF83 flew twice).
        #expect(Self.idents(s).first == "AF84")
        #expect(Self.idents(s).filter { $0 == "AF83" }.count == 1)
    }

    @Test func anExactKnownFlightIsTheTopRowOnce() {
        let s = Self.suggest("af84")
        guard case .flight(let ident, let known) = s.top else { Issue.record("no flight on top"); return }
        #expect(ident == "AF84")
        #expect(known?.followed == true)
        #expect(Self.idents(s).filter { $0 == "AF84" }.count == 1)
    }

    @Test func anUnknownNumberIsOfferedAsTyped() {
        let s = Self.suggest("UA 1527")
        #expect(s.top == .flight(ident: "UA1527", known: nil))
    }

    @Test func eitherAirlineCodeFindsAStoredNumber() {
        // Stored with British Airways' ICAO code, typed with its IATA code.
        #expect(Self.idents(Self.suggest("BA28")).contains("BAW286"))
        #expect(Self.idents(Self.suggest("BAW 2")).contains("BAW286"))
    }

    @Test func anAirlineCodeAloneRanksTheAirlineAboveItsFlights() {
        let s = Self.suggest("AF")
        #expect(s.top == .airline(ReferenceData.bundled().airline("AFR")!))
        #expect(Self.idents(s).contains("AF84"))
    }

    // MARK: Airlines

    @Test(arguments: [
        ("air fr", "AFR"), ("Air France", "AFR"), ("AF", "AFR"), ("AFR", "AFR"), ("ual", "UAL"), ("UA", "UAL"),
        ("united", "UAL"), ("speedbird", "BAW"), ("air frnace", "AFR"), ("lufthansa", "DLH"), ("lufthnasa", "DLH"),
        ("delta", "DAL"), ("klm", "KLM"),
    ])
    func airlinesByCodeNameAndCallsign(_ text: String, _ icao: String) {
        #expect(Self.airlineIDs(Self.suggest(text)).first == icao, "\(text)")
    }

    @Test func tappingAnAirlineFillsItsCodeAndASpace() {
        let s = Self.suggest("air fr")
        guard case .airline(let a) = s.top else { Issue.record("no airline on top"); return }
        #expect(a.id == "AFR")
        #expect(SearchSuggestion.airline(a).fill == "AF ")
        #expect(!SearchSuggestion.airline(a).searches)
    }

    // MARK: Airports

    @Test func aCityGivesItsAirportsBiggestFirst() {
        #expect(Self.airportIDs(Self.suggest("paris")).prefix(2) == ["LFPG", "LFPO"])
        #expect(Self.airportIDs(Self.suggest("Paris")).prefix(2) == ["LFPG", "LFPO"])
        let ny = Self.airportIDs(Self.suggest("new york"))
        #expect(ny.contains("KJFK") && ny.contains("KLGA"))
        // Heathrow and Gatwick are both large: either may lead, both come before the small fields.
        #expect(Set(Self.airportIDs(Self.suggest("london")).prefix(2)) == ["EGLL", "EGKK"])
    }

    @Test(arguments: [
        ("Zurich", "LSZH"), ("zürich", "LSZH"), ("zurih", "LSZH"), ("cancun", "MMUN"), ("CDG", "LFPG"),
        ("LFPG", "LFPG"), ("sfo", "KSFO"), ("heathrow", "EGLL"), ("heathorw", "EGLL"), ("charles de gaulle", "LFPG"),
        ("narita", "RJAA"), ("schiphol", "EHAM"), ("o'hare", "KORD"), ("ohare", "KORD"), ("sao paulo", "SBGR"),
        ("Dallas-Fort Worth", "KDFW"),
    ])
    func airportsByCodeCityAndName(_ text: String, _ icao: String) {
        #expect(Self.airportIDs(Self.suggest(text)).contains(icao), "\(text)")
    }

    @Test func anExactCodeOffersItsBoardRightUnder() {
        let s = Self.suggest("CDG")
        let cdg = AirportDirectory.bundled().airport("LFPG")!
        #expect(s.top == .airport(cdg))
        #expect(s.items(.airports).prefix(2) == [.airport(cdg), .board(cdg)])
        #expect(SearchSuggestion.airport(cdg).fill == "CDG ")
        #expect(SearchSuggestion.board(cdg).fill == nil)
    }

    @Test func aPickedAirportOffersItsBoardAndUsualRoutes() {
        let s = Self.suggest("SFO ")
        let sfo = AirportDirectory.bundled().airport("KSFO")!
        #expect(s.top == .board(sfo))
        #expect(Set(Self.routes(s)) == ["KSFO-LFPG", "KSFO-EGLL"])
        // Not every airport with "sfo" somewhere in it.
        #expect(Self.airportIDs(s).isEmpty)
    }

    @Test func aDanglingToOffersTheBoard() {
        let s = Self.suggest("paris to")
        #expect(s.top == .board(AirportDirectory.bundled().airport("LFPG")!))
    }

    // MARK: Routes

    @Test(arguments: ["CDG SFO", "cdg sfo", "CDG to SFO", "CDG-SFO", "CDG \u{2192} SFO", "Paris to San Francisco",
                      "paris to san francisco", "LFPG KSFO"])
    func routesFromCodesOrCities(_ text: String) {
        let s = Self.suggest(text)
        #expect(s.groups.first?.kind == .routes, "\(text)")
        #expect(Self.routes(s).first == "LFPG-KSFO", "\(text)")
        #expect(s.top?.fill == "CDG SFO")
        #expect(s.top?.searches == true)
    }

    @Test func aPartialDestinationListsRoutesFromTheOrigin() {
        let r = Self.routes(Self.suggest("CDG san f"))
        #expect(r.first == "LFPG-KSFO")
        #expect(r.allSatisfy { $0.hasPrefix("LFPG-") })
        #expect(r.count <= SearchSuggestions.Kind.routes.limit)
    }

    @Test func aFlightNumberAfterAnAirportCodeIsNotARoute() {
        // DAL is Dallas Love Field and Delta's ICAO code.
        let s = Self.suggest("DAL 220")
        #expect(Self.routes(s).isEmpty)
        #expect(s.top == .flight(ident: "DAL220", known: nil))
    }

    @Test func namesWithDashesAreNotRoutes() {
        #expect(Self.routes(Self.suggest("Dallas-Fort Worth")).isEmpty)
        #expect(Self.airportIDs(Self.suggest("Dallas-Fort Worth")).first == "KDFW")
    }

    // MARK: Recent

    @Test func recentSearchesMatchingTheText() {
        let s = Self.suggest("aus", recent: ["AUS SFO", "AF84", "SFO"])
        #expect(s.items(.recent) == [.recent("AUS SFO")])
        #expect(Self.suggest("zzzzzz", recent: ["AUS SFO"]).items(.recent).isEmpty)
        #expect(Self.suggest("af 8", recent: ["AF84"]).items(.recent) == [.recent("AF84")])
    }

    // MARK: Shape

    @Test func blankTextSuggestsNothing() {
        #expect(Self.suggest("").isEmpty)
        #expect(Self.suggest("   ").isEmpty)
        #expect(Self.suggest("").top == nil)
    }

    @Test(arguments: ["a", "air", "san", "AF 8", "paris", "CDG s", "x", "new", "1"])
    func groupsAreCappedAndRowsUnique(_ text: String) {
        let s = Self.suggest(text, recent: ["AUS SFO", "AF84"])
        for g in s.groups { #expect(g.items.count <= g.kind.limit && !g.items.isEmpty) }
        #expect(Set(s.all.map(\.id)).count == s.count)
        #expect(Set(s.groups.map(\.kind)).count == s.groups.count)
    }

    @Test func nonsenseFindsNothing() {
        #expect(Self.suggest("qqqqqqqqqq").isEmpty)
    }

    @Test func suggestingIsFast() {
        let start = Date()
        for text in ["p", "pa", "par", "pari", "paris", "zurih", "air fr", "AF 8", "Paris to San F"] {
            _ = Self.suggest(text)
        }
        // Nine keystrokes over 3,975 airports, with typo passes; a debug build on a laptop.
        #expect(Date().timeIntervalSince(start) < 1.5)
    }

    // MARK: Live query

    @Test func liveQueriesAreWholeNumbersAndCertainRoutes() {
        let d = Self.date
        #expect(Self.suggester.liveQuery("AF84", date: d) == .ident("AF84", date: d))
        #expect(Self.suggester.liveQuery("af 84", date: d) == .ident("AF84", date: d))
        #expect(Self.suggester.liveQuery("CDG SFO", date: d) == .route(origin: "LFPG", destination: "KSFO", date: d))
        #expect(Self.suggester.liveQuery("Paris to San Francisco", date: d) == .route(origin: "LFPG", destination: "KSFO", date: d))
        #expect(Self.suggester.liveQuery("paris", date: d) == nil)
        #expect(Self.suggester.liveQuery("CDG", date: d) == nil)
        #expect(Self.suggester.liveQuery("Paris to San F", date: d) == nil)
        #expect(Self.suggester.liveQuery("ZZZ SFO", date: d) == nil)
        #expect(Self.suggester.liveQuery("CDG CDG", date: d) == nil)
        #expect(Self.suggester.liveQuery("air fr", date: d) == nil)
    }

    // MARK: Directory

    @Test func theBundledDirectoryIsTheWholeSeed() {
        let dir = AirportDirectory.bundled()
        #expect(dir.all.count == 3975)
        #expect(dir.airport("cdg")?.city == "Paris")
        #expect(dir.airport("LSZH")?.name == "Zürich Airport")
        #expect(dir.airport("ORY")?.timeZone.identifier == "Europe/Paris")
        // Every fake airport is in it, so screenshot runs find their cities.
        let fakes: [Airport] = FakeSeed.load("airports")
        #expect(fakes.allSatisfy { dir.airport($0.id) != nil })
    }

    @Test func directoryLinesParse() {
        let text = "LFPG\tCDG\tCharles de Gaulle International Airport\tParis\tFR\t49.009\t2.5541\tEurope/Paris\n"
            + "BGJH\t\tQaqortoq Heliport\t\tGL\t60.7157\t-46.0299\t\n"
            + "bad line\n"
        let a = AirportDirectory.parse(text)
        #expect(a.count == 2)
        #expect(a[0].iata == "CDG" && a[0].lat == 49.009)
        #expect(a[1].iata == nil && a[1].city == "Qaqortoq Heliport" && a[1].timeZone == .gmt)
    }
}

/// How often a pause in typing may cost a lookup.
@Suite struct LiveLookupGateTests {
    let t0 = Date(timeIntervalSince1970: 1_793_361_600)

    @Test func sendsUntilTheBudgetIsSpent() {
        var g = LiveLookupGate(budget: 3, window: 3600, reuse: 120, cooldown: 600)
        for i in 0..<3 {
            #expect(g.verdict(for: "k\(i)", now: t0) == .send)
            g.didSend(now: t0)
        }
        #expect(g.verdict(for: "k9", now: t0) == .wait)
        // An hour later the oldest have left the window.
        #expect(g.verdict(for: "k9", now: t0.addingTimeInterval(3601)) == .send)
    }

    @Test func theSameQueryIsReusedForAWhile() {
        var g = LiveLookupGate()
        g.didSend(now: t0)
        g.didAnswer("ident:AF84", now: t0)
        #expect(g.verdict(for: "ident:AF84", now: t0.addingTimeInterval(60)) == .reuse)
        #expect(g.verdict(for: "ident:AF84", now: t0.addingTimeInterval(121)) == .send)
    }

    @Test func aRateLimitPausesLiveLookups() {
        var g = LiveLookupGate()
        g.didHitLimit(now: t0)
        #expect(g.verdict(for: "a", now: t0.addingTimeInterval(599)) == .wait)
        #expect(g.verdict(for: "a", now: t0.addingTimeInterval(601)) == .send)
    }

    @Test func keysCarryKindCodesAndDay() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .gmt
        #expect(LiveLookupGate.key(.ident("AF84", date: t0), calendar: cal) == "ident:AF84:2026-10-30")
        #expect(LiveLookupGate.key(.route(origin: "LFPG", destination: "KSFO", date: t0), calendar: cal)
            == "route:LFPG-KSFO:2026-10-30")
        #expect(LiveLookupGate.key(.ident("AF84", date: t0), calendar: cal)
            != LiveLookupGate.key(.ident("AF84", date: t0.addingTimeInterval(86_400)), calendar: cal))
    }

    @Test func aRouteKeepsTheBoardRowsBoundForTheDestination() {
        let dir = AirportDirectory.bundled()
        func row(_ ident: String, to icao: String, iata: String?, at: TimeInterval) -> Flight {
            var f = PreviewData.followed[0]
            f.id = UUID(); f.ident = ident; f.destinationIcao = icao; f.destinationIata = iata
            f.scheduledOut = t0.addingTimeInterval(at)
            return f
        }
        let board = [row("AF84", to: "KSFO", iata: "SFO", at: 600), row("AF66", to: "KLAX", iata: "LAX", at: 0),
                     row("UA57", to: "KSFO", iata: nil, at: 0)]
        let picked = SupabaseFlightService.flights(in: board, to: "SFO", airport: dir.lookup)
        #expect(picked.map(\.ident) == ["UA57", "AF84"])
        #expect(SupabaseFlightService.flights(in: board, to: "KSFO", airport: dir.lookup).count == 2)
        #expect(SupabaseFlightService.flights(in: board, to: "JFK", airport: dir.lookup).isEmpty)
    }
}
