import FlightImportKit
import Foundation
import Observation

/// What picking a suggestion (or pressing return) asks of the screen.
public enum SearchPick: Equatable, Sendable {
    /// The field now holds the start of a query (an airline's or airport's code); keep the keyboard up.
    case filled
    /// The field holds a whole query and its search is running.
    case searching
    /// Open this airport's board (ICAO).
    case openAirport(String)
}

/// One row a search found: a tracked flight from today's lookups, or a flight on an airline's schedule
/// days or weeks ahead.
public enum SearchResult: Sendable, Hashable, Identifiable {
    case live(Flight), planned(ScheduledFlight)

    public var id: String {
        switch self {
        case .live(let f): "live \(f.id)"
        case .planned(let p): "planned \(p.id)"
        }
    }
    public var ident: String {
        switch self {
        case .live(let f): f.ident
        case .planned(let p): p.ident
        }
    }
    /// ICAO.
    public var origin: String {
        switch self {
        case .live(let f): f.originIcao
        case .planned(let p): p.origin
        }
    }
    /// ICAO.
    public var destination: String {
        switch self {
        case .live(let f): f.destinationIcao
        case .planned(let p): p.destination
        }
    }
    public var scheduledOut: Date? {
        switch self {
        case .live(let f): f.scheduledOut ?? f.estimatedOut
        case .planned(let p): p.scheduledOut
        }
    }

    /// True when `airline` flies it, by its ICAO or IATA code, as operator or flight number prefix.
    func isFlown(by airline: Airline) -> Bool {
        let codes = Set([airline.id, airline.iata].compactMap { $0?.uppercased() })
        let carrier: String? = switch self {
        case .live(let f): f.operator
        case .planned(let p): p.airline
        }
        if let carrier, codes.contains(carrier.uppercased()) { return true }
        return codes.contains(SearchStore.airlinePrefix(ident.uppercased()))
    }
}

/// The lookups one intent costs, and how their rows are kept and ordered.
struct SearchRoute: Sendable {
    enum Grouping: Sendable { case byDestination, byOrigin }

    /// Same key, same lookups: the answer cache and the gate go by it. The time of day and the grouping
    /// only order rows, so they are not part of it.
    var key: String
    var live: [FlightQuery] = []
    var planned: [ScheduleQuery] = []
    /// Rows must leave from one of these (ICAO); empty keeps any.
    var origins: Set<String> = []
    var destinations: Set<String> = []
    var airline: Airline?
    /// For rows that carry neighbouring days (boards, route lookups, a flight number's schedules either
    /// side of midnight): the origin-local day asked for. Rows leaving on another day are dropped.
    var rowDay: LocalDay?
    var timeOfDay: Int?
    var grouping: Grouping?
}

@MainActor @Observable
public final class SearchStore {
    public var text = ""
    public var date = Date.now
    /// What the search found, in the order the screen lists it.
    public private(set) var items: [SearchResult] = []
    /// The live rows of `items`.
    public var results: [Flight] { items.compactMap { if case .live(let f) = $0 { f } else { nil } } }
    /// What `text` reads as, updated on each change.
    public private(set) var intent = SearchIntent()
    /// A short line under the field when the search cannot look where the text asks.
    public private(set) var note: String?
    public private(set) var error: APIError?
    public private(set) var isSearching = false
    /// Queries that found something, newest first, at most `recentLimit`.
    public private(set) var recent: [String] = []
    /// What the field offers for `text`, refreshed shortly after each change (`textChanged()`).
    public private(set) var suggestions: SearchSuggestions = .empty
    /// The followed and past flights flight numbers are suggested from; the screen sets them.
    public var known: [KnownFlight] = []

    public static let recentLimit = 6
    /// Schedules this build has no service for.
    public static let unavailableNote = "Future dates need the live service"
    /// The schedules service refused (its spend cap, an outage).
    public static let schedulesDownNote = "Schedules are unavailable right now"
    /// The backend stopped at its page limit: a busy airport's day holds more.
    public static let truncatedNote = "Showing the first flights. Add a destination for more."
    public static let beyondReachNote = "Airline schedules only go \(DateWords.maxDaysAhead) days ahead"
    nonisolated static let recentKey = "recentSearches"

    private let flights: any FlightService
    private let schedules: any ScheduleService
    /// The device calendar dates are typed in.
    @ObservationIgnored var timeZone: TimeZone = .current
    /// A bare "3 4" reads month first (the US way).
    @ObservationIgnored var monthFirst = Locale.current.region == .unitedStates
    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private let suggester: SearchSuggester
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var searchGeneration = 0
    @ObservationIgnored private(set) var gate = LiveLookupGate()
    /// The most calls one search fans out to over a city's airports.
    nonisolated static let maxCalls = 4
    /// What a route's lookups answered: rows before filters and order, the error when none answered.
    struct Answer: Sendable {
        var rows: [SearchResult] = []
        var error: APIError?
        var note: String?
    }
    /// The answers the gate still counts as fresh, by route key.
    @ObservationIgnored private var answers: [String: Answer] = [:]
    @ObservationIgnored private var suggestTask: Task<Void, Never>?
    @ObservationIgnored private var liveTask: Task<Void, Never>?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    /// The route `items` answer, so a change of text drops rows that no longer fit it.
    @ObservationIgnored private var resultsKey: String?
    /// The text `textChanged()` last handled.
    @ObservationIgnored private var handledText: String?

    /// Wait before suggesting; zero suggests on every keystroke (worked out off the main thread, the
    /// answer dropped when the text has moved on).
    @ObservationIgnored var suggestDelay: Duration = .zero
    /// The pause in typing before a complete flight number or route is looked up.
    @ObservationIgnored var liveDelay: Duration = .milliseconds(250)

    /// - Parameters:
    ///   - defaults: where recent searches persist; nil keeps them in memory only.
    ///   - suggester: the airports and airlines suggestions come from (the bundled lists).
    ///   - schedules: airline schedules, for days past the reach of today's lookups.
    public init(flights: any FlightService, schedules: any ScheduleService = UnavailableScheduleService(),
                defaults: UserDefaults? = nil, suggester: SearchSuggester = .bundled(),
                now: @escaping @Sendable () -> Date = { .now }) {
        self.flights = flights
        self.schedules = schedules
        self.defaults = defaults
        self.suggester = suggester
        self.now = now
        recent = defaults?.stringArray(forKey: Self.recentKey) ?? []
    }

    // MARK: Typing

    /// The screen calls this on every change of `text`: suggestions follow after `suggestDelay`, and a
    /// complete flight number or route is looked up after `liveDelay` without a further change.
    public func textChanged() {
        // The field's change handler repeats a change `pick` already made: nothing new to do.
        guard text != handledText else { return }
        handledText = text
        suggestTask?.cancel()
        liveTask?.cancel()
        let typed = text
        intent = readIntent()
        let route = currentRoute()
        if route?.key != resultsKey {
            items = []; resultsKey = nil; error = nil; note = nil
        } else if let route {
            items = ordered(items, route)
        }
        if intent.isBeyondReach { note = Self.beyondReachNote } else if note == Self.beyondReachNote { note = nil }
        if typed.trimmingCharacters(in: .whitespaces).isEmpty {
            suggestions = .empty
            isSearching = false
            return
        }
        let suggestDelay = suggestDelay, liveDelay = liveDelay
        suggestTask = Task { [weak self] in
            if suggestDelay > .zero { try? await Task.sleep(for: suggestDelay) }
            guard !Task.isCancelled, let self, self.text == typed else { return }
            let suggester = self.suggester, known = self.known, recent = self.recent
            let found = await Task.detached(priority: .userInitiated) {
                suggester.suggest(typed, known: known, recent: recent)
            }.value
            guard !Task.isCancelled, self.text == typed else { return }
            self.suggestions = found
        }
        liveTask = Task { [weak self] in
            try? await Task.sleep(for: liveDelay)
            guard !Task.isCancelled, let self, self.text == typed else { return }
            await self.lookUpLive()
        }
    }

    /// Recomputes `suggestions` at once (return, tests).
    public func suggestNow() {
        suggestTask?.cancel()
        suggestions = suggester.suggest(text, known: known, recent: recent)
    }

    /// The query a pause may look up now, if any.
    func liveQuery() -> FlightQuery? { suggester.liveQuery(text, date: date) }

    /// The query return searches: the text as parsed, else a route named by cities.
    func currentQuery() -> FlightQuery? { FlightQuery.parse(text, date: date) ?? liveQuery() }

    /// What `text` reads as now.
    func readIntent() -> SearchIntent {
        SearchIntent.parse(text, now: now(), tz: timeZone, monthFirst: monthFirst, suggester: suggester)
    }

    /// The lookups for `intent`, else for the text as `currentQuery` reads it; nil when there is nothing
    /// to look up or the date is past the schedules' reach.
    func currentRoute() -> SearchRoute? {
        guard !intent.isBeyondReach else { return nil }
        if let r = route(for: intent) { return r }
        guard !intent.isSearchable, let q = currentQuery() else { return nil }
        return SearchRoute(key: LiveLookupGate.key(q), live: [q])
    }

    /// Today's live paths when the origin-local day is today, tomorrow or the day after (the reach of
    /// `flight-lookup`), airline schedules further ahead. An airline alone has no lookup.
    func route(for i: SearchIntent) -> SearchRoute? {
        guard i.isSearchable else { return nil }
        let today = LocalDay(now(), in: i.origins.first.map(zone) ?? timeZone)
        let day = i.day ?? today
        let near = today.days(to: day) <= 2
        // The origin-local day on every path, typed or not: the board shortcut, the lookup's date and
        // `rowDay` must agree (a phone in Los Angeles at 16:00 is already tomorrow in Paris).
        let when = noon(day)
        var r = SearchRoute(key: "", origins: Set(i.origins), destinations: Set(i.destinations),
                            airline: i.airline, timeOfDay: i.timeOfDay)
        if let ident = i.ident {
            r.airline = nil
            if near {
                r.live = [.ident(ident, date: when)]
            } else {
                r.planned = [ScheduleQuery(ident: designator(ident, i.airline), day: day)]
                r.rowDay = day
            }
        } else if !i.origins.isEmpty, !i.destinations.isEmpty {
            let pairs = Self.pairs(i.origins, i.destinations)
            // A route lists the day closest to the time first, so it asks the whole day.
            if near {
                r.live = pairs.map { .route(origin: $0.0, destination: $0.1, date: when) }
            } else {
                r.planned = pairs.map { ScheduleQuery(origin: $0.0, destination: $0.1, airline: i.airline?.id, day: day) }
            }
            r.rowDay = day
        } else if !i.origins.isEmpty || !i.destinations.isEmpty {
            let fromOrigin = !i.origins.isEmpty
            let places = Array(Self.largestFirst(fromOrigin ? i.origins : i.destinations).prefix(Self.maxCalls))
            r.grouping = fromOrigin ? .byDestination : .byOrigin
            if near {
                r.live = places.map { .airport($0) }
                r.rowDay = i.day
            } else {
                // A whole day at a hub can pass the backend's page limit: the hours around the time asked.
                r.planned = places.map {
                    fromOrigin ? ScheduleQuery(origin: $0, airline: i.airline?.id, day: day, time: i.timeOfDay)
                               : ScheduleQuery(destination: $0, airline: i.airline?.id, day: day, time: i.timeOfDay)
                }
                // The backend reads a destination-only query on the destination's day: holding its rows
                // to their origin's day would drop most of them.
                if fromOrigin { r.rowDay = day }
            }
        } else {
            return nil
        }
        let calls = r.live.map { LiveLookupGate.key($0, calendar: calendar) }
            + r.planned.map {
                "plan:\($0.origin ?? "")-\($0.destination ?? "")-\($0.airline ?? "")-\($0.ident ?? "")-\($0.day)-\($0.time.map(String.init) ?? "")"
            }
        r.key = (calls + [r.origins.sorted().joined(separator: ","), r.destinations.sorted().joined(separator: ","),
                          r.airline?.id ?? "", r.rowDay?.description ?? ""]).joined(separator: "|")
        return r
    }

    nonisolated private static func sizeRank(_ icao: String) -> Int {
        switch AirportSizes.bundled.size(icao) { case .large: 0; case .medium: 1; case .small: 2 }
    }

    /// Airports by size, large first, in their own order within a size.
    nonisolated static func largestFirst(_ codes: [String]) -> [String] {
        codes.enumerated().sorted { (sizeRank($0.element), $0.offset) < (sizeRank($1.element), $1.offset) }.map(\.element)
    }

    /// The origin to destination pairs a two-place search asks, at most `maxCalls`: the largest
    /// airports first, spread over both ends (the first two of each before a third of either), an
    /// origin's turn before a destination's.
    nonisolated static func pairs(_ origins: [String], _ destinations: [String]) -> [(String, String)] {
        let from = largestFirst(origins), to = largestFirst(destinations)
        var all: [(key: (Int, Int, Int, Int), pair: (String, String))] = []
        for (i, o) in from.enumerated() {
            for (j, d) in to.enumerated() where d != o {
                all.append(((sizeRank(o) + sizeRank(d), max(i, j), i, j), (o, d)))
            }
        }
        return all.sorted { $0.key < $1.key }.prefix(maxCalls).map(\.pair)
    }

    /// The calls `r` costs against the gate; schedules this build cannot reach throw before any network.
    func cost(_ r: SearchRoute) -> Int {
        r.live.count + (schedules is UnavailableScheduleService ? 0 : r.planned.count)
    }

    /// The airport's time zone, else the device's.
    private func zone(_ icao: String) -> TimeZone {
        suggester.airport(code: icao).flatMap { TimeZone(identifier: $0.tz) } ?? timeZone
    }

    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        return cal
    }

    /// Noon of `day` on the device calendar: the date a lookup reads that day from.
    private func noon(_ day: LocalDay) -> Date {
        calendar.date(from: DateComponents(year: day.year, month: day.month, day: day.day, hour: 12)) ?? date
    }

    /// The airline code a flight number starts with: three letters when its third character is a
    /// letter ("AFR84"), else two ("AF84", "U21234").
    nonisolated static func airlinePrefix(_ ident: String) -> String {
        let chars = Array(ident)
        guard chars.count > 2 else { return ident }
        return String(chars[..<(chars[2].isLetter ? 3 : 2)])
    }

    /// The IATA designator schedules want ("AF84" for "AFR84"); the ident as typed when no IATA code is known.
    func designator(_ ident: String, _ airline: Airline?) -> String {
        let code = Self.airlinePrefix(ident)
        guard code.count == 3, let iata = (suggester.airline(code: code) ?? airline)?.iata else { return ident }
        return iata + ident.dropFirst(3)
    }

    /// Every lookup of `r` at once. Not found counts as no rows; the first other error stands only when no
    /// lookup answered. Schedules the build cannot reach, or that refuse, give a note instead, and so does
    /// an answer cut at the backend's page limit.
    func fetch(_ r: SearchRoute) async -> Answer {
        let flights = self.flights, schedules = self.schedules
        let live = await withTaskGroup(of: (Int, Result<[Flight], APIError>).self) { g in
            for (k, q) in r.live.enumerated() {
                g.addTask {
                    do throws(APIError) { return (k, .success(try await flights.lookup(q))) } catch { return (k, .failure(error)) }
                }
            }
            var out: [(Int, Result<[Flight], APIError>)] = []
            for await x in g { out.append(x) }
            return out.sorted { $0.0 < $1.0 }.map { $0.1.map { $0.map(SearchResult.live) } }
        }
        let planned = await withTaskGroup(of: (Int, Result<ScheduleDay, APIError>).self) { g in
            for (k, q) in r.planned.enumerated() {
                g.addTask {
                    do throws(APIError) { return (k, .success(try await schedules.scheduleDay(q))) } catch { return (k, .failure(error)) }
                }
            }
            var out: [(Int, Result<ScheduleDay, APIError>)] = []
            for await x in g { out.append(x) }
            return out.sorted { $0.0 < $1.0 }.map(\.1)
        }
        let builtIn = !(schedules is UnavailableScheduleService)
        var answer = Answer()
        var answered = false, firstError: APIError?
        let truncated = planned.contains { (try? $0.get())?.truncated == true }
        for result in live + planned.map({ $0.map { $0.flights.map(SearchResult.planned) } }) {
            switch result {
            case .success(let rows): answered = true; answer.rows += rows
            case .failure(.notFound): answered = true
            case .failure(.providerUnavailable) where !r.planned.isEmpty:
                answer.note = builtIn ? Self.schedulesDownNote : Self.unavailableNote
            case .failure(let e): firstError = firstError ?? e
            }
        }
        if truncated, answer.note == nil { answer.note = Self.truncatedNote }
        if !answered, answer.note == nil { answer.error = firstError ?? .notFound }
        return answer
    }

    /// The rows of `answer` that fit `r`, once each, in the order the screen lists them.
    func rows(_ answer: Answer, _ r: SearchRoute) -> [SearchResult] {
        var seen: Set<String> = []
        let kept = answer.rows.filter { row in
            guard seen.insert(row.id).inserted else { return false }
            if !r.origins.isEmpty, !r.origins.contains(row.origin) { return false }
            if !r.destinations.isEmpty, !r.destinations.contains(row.destination) { return false }
            if let a = r.airline, !row.isFlown(by: a) { return false }
            if let d = r.rowDay, let out = row.scheduledOut, LocalDay(out, in: zone(row.origin)) != d { return false }
            return true
        }
        return ordered(kept, r)
    }

    /// By departure, or by distance to the time of day asked for. A one-place search groups rows by
    /// their other end, the ends the traveller already knows first, then by earliest departure.
    func ordered(_ rows: [SearchResult], _ r: SearchRoute) -> [SearchResult] {
        func minutes(_ row: SearchResult) -> Int {
            guard let t = r.timeOfDay, let out = row.scheduledOut else { return 0 }
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = zone(row.origin)
            let c = cal.dateComponents([.hour, .minute], from: out)
            let d = abs((c.hour ?? 0) * 60 + (c.minute ?? 0) - t)
            return min(d, 1440 - d)
        }
        func before(_ a: SearchResult, _ b: SearchResult) -> Bool {
            (minutes(a), a.scheduledOut ?? .distantFuture, a.ident) < (minutes(b), b.scheduledOut ?? .distantFuture, b.ident)
        }
        guard let grouping = r.grouping else { return rows.sorted(by: before) }
        let end: (SearchResult) -> String = grouping == .byDestination ? { $0.destination } : { $0.origin }
        let knownEnds = Set(known.map { grouping == .byDestination ? $0.destination : $0.origin })
        let groups = Dictionary(grouping: rows, by: end).map { (end: $0.key, rows: $0.value.sorted(by: before)) }
        func rank(_ g: (end: String, rows: [SearchResult])) -> (Int, Date, String) {
            (knownEnds.contains(g.end) ? 0 : 1, g.rows.compactMap(\.scheduledOut).min() ?? .distantFuture, g.end)
        }
        return groups.sorted { rank($0) < rank($1) }.flatMap(\.rows)
    }

    /// Shows `answer` for `r`.
    private func show(_ answer: Answer, _ r: SearchRoute) {
        items = rows(answer, r)
        resultsKey = r.key
        note = answer.note
    }

    /// The lookups for what is typed, when the gate allows them: a whole flight number in any form the
    /// intent reads ("84 af", "air france 84"), a route both of whose ends are typed in full ("paris
    /// marseille"), or a sentence with a day. A half-typed place ("Paris to San F") waits. A later change
    /// of text cancels them and drops their answer. Errors stay quiet while typing (return shows them),
    /// but a limit stops live lookups for a while.
    func lookUpLive() async {
        intent = readIntent()
        let bothEnds = !intent.origins.isEmpty && !intent.destinations.isEmpty && intent.leftover.isEmpty
        guard liveQuery() != nil || intent.ident != nil || bothEnds || (intent.day != nil && intent.isSearchable),
              let r = currentRoute() else { return }
        let cost = cost(r)
        switch gate.verdict(for: r.key, cost: cost, now: now()) {
        case .wait: return
        case .reuse:
            // Asked a moment ago (the text went back to it): the answer then, no second call.
            if resultsKey != r.key, let a = answers[r.key] {
                show(a, r)
                if items.isEmpty, note == nil { resultsKey = nil }
            }
            return
        case .send: break
        }
        gate.didSend(now: now(), cost: cost)
        searchGeneration += 1
        let gen = searchGeneration
        isSearching = true
        let a = await fetch(r)
        guard gen == searchGeneration, !Task.isCancelled else {
            // Dropped because the text moved on, with no newer lookup to end the spinner in its place.
            if gen == searchGeneration { isSearching = false }
            return
        }
        if let e = a.error {
            if e == .rateLimited || e == .planLimit { gate.didHitLimit(now: now()) }
            if e == .notFound { answer(r.key, a) }
            items = []; resultsKey = nil
        } else {
            show(a, r); error = nil
            answer(r.key, a)
        }
        isSearching = false
    }

    // MARK: Picking

    /// The row the user tapped: the field takes its text, and a whole query (a flight number, a route,
    /// a recent search) runs at once.
    @discardableResult
    public func pick(_ s: SearchSuggestion) -> SearchPick {
        if case .board(let a) = s { return .openAirport(a.id) }
        guard let fill = s.fill else { return .filled }
        text = fill
        textChanged()
        guard s.searches else {
            suggestNow()
            return .filled
        }
        liveTask?.cancel()
        searchTask?.cancel()
        searchTask = Task { [weak self] in await self?.search() }
        return .searching
    }

    /// Return: the top suggestion when there is one, else a search of the text as typed.
    @discardableResult
    public func submit() -> SearchPick {
        suggestNow()
        if let top = suggestions.top { return pick(top) }
        liveTask?.cancel()
        searchTask?.cancel()
        searchTask = Task { [weak self] in await self?.search() }
        return .searching
    }

    // MARK: Search

    /// On any error `text` stays as typed. The latest call wins; a superseded call drops its result.
    public func search() async {
        liveTask?.cancel()
        searchGeneration += 1
        let gen = searchGeneration
        intent = readIntent()
        guard let r = currentRoute() else {
            items = []; resultsKey = nil; isSearching = false
            if intent.isBeyondReach { note = Self.beyondReachNote; error = nil } else { note = nil; error = .notFound }
            return
        }
        isSearching = true
        let a = await fetch(r)
        guard gen == searchGeneration else { return }
        if let e = a.error {
            error = e
            if e == .rateLimited { gate.didHitLimit(now: now()) }
            if e == .notFound { items = []; resultsKey = nil; note = nil; answer(r.key, a) }
        } else {
            show(a, r)
            answer(r.key, a)
            error = items.isEmpty && note == nil ? .notFound : nil
            if !items.isEmpty { remember(text) }
        }
        isSearching = false
    }

    /// Keeps an answer for the gate's reuse window.
    private func answer(_ key: String, _ a: Answer) {
        gate.didAnswer(key, now: now())
        answers = answers.filter { gate.verdict(for: $0.key, now: now()) == .reuse }
        answers[key] = a
    }

    /// True when the flight is now followed. Plan and rate limits set `error` and add nothing.
    public func follow(_ flight: Flight) async -> Bool {
        do {
            try await flights.follow(flight.id, notify: true)
            error = nil
            return true
        } catch {
            self.error = error
            return false
        }
    }

    public func clearRecent() {
        recent = []
        defaults?.removeObject(forKey: Self.recentKey)
    }

    #if DEBUG
    /// Replaces the recent list without persisting it (previews and snapshots).
    func seedRecent(_ queries: [String]) {
        recent = Array(queries.prefix(Self.recentLimit))
    }
    #endif

    /// What `query` reads as now (a recent search's description).
    func intent(for query: String) -> SearchIntent {
        SearchIntent.parse(query, now: now(), tz: timeZone, monthFirst: monthFirst, suggester: suggester)
    }

    /// Trimmed and as typed, moved to the front, deduplicated whatever the case, capped.
    private func remember(_ raw: String) {
        let q = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        recent = Array(([q] + recent.filter { $0.caseInsensitiveCompare(q) != .orderedSame }).prefix(Self.recentLimit))
        defaults?.set(recent, forKey: Self.recentKey)
    }
}
