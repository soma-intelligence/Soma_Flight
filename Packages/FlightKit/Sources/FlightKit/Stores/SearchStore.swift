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

@MainActor @Observable
public final class SearchStore {
    public var text = ""
    public var date = Date.now
    public private(set) var results: [Flight] = []
    public private(set) var error: APIError?
    public private(set) var isSearching = false
    /// Queries that found something, newest first, at most `recentLimit`.
    public private(set) var recent: [String] = []
    /// What the field offers for `text`, refreshed shortly after each change (`textChanged()`).
    public private(set) var suggestions: SearchSuggestions = .empty
    /// The followed and past flights flight numbers are suggested from; the screen sets them.
    public var known: [KnownFlight] = []

    public static let recentLimit = 6
    nonisolated static let recentKey = "recentSearches"

    private let flights: any FlightService
    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private let suggester: SearchSuggester
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var searchGeneration = 0
    @ObservationIgnored private var gate = LiveLookupGate()
    /// The answers the gate still counts as fresh, by query key.
    @ObservationIgnored private var answers: [String: [Flight]] = [:]
    @ObservationIgnored private var suggestTask: Task<Void, Never>?
    @ObservationIgnored private var liveTask: Task<Void, Never>?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    /// The query `results` answer, so a change of text drops results that no longer fit it.
    @ObservationIgnored private var resultsKey: String?
    /// The text `textChanged()` last handled.
    @ObservationIgnored private var handledText: String?

    /// Long enough to skip the keystrokes of a word, short enough to feel instant.
    @ObservationIgnored var suggestDelay: Duration = .milliseconds(60)
    /// The pause in typing before a complete flight number or route is looked up.
    @ObservationIgnored var liveDelay: Duration = .milliseconds(400)

    /// - Parameters:
    ///   - defaults: where recent searches persist; nil keeps them in memory only.
    ///   - suggester: the airports and airlines suggestions come from (the bundled lists).
    public init(flights: any FlightService, defaults: UserDefaults? = nil, suggester: SearchSuggester = .bundled(),
                now: @escaping @Sendable () -> Date = { .now }) {
        self.flights = flights
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
        if currentQuery().map({ LiveLookupGate.key($0) }) != resultsKey {
            results = []; resultsKey = nil; error = nil
        }
        if typed.trimmingCharacters(in: .whitespaces).isEmpty {
            suggestions = .empty
            isSearching = false
            return
        }
        let suggestDelay = suggestDelay, liveDelay = liveDelay
        suggestTask = Task { [weak self] in
            try? await Task.sleep(for: suggestDelay)
            guard !Task.isCancelled, let self, self.text == typed else { return }
            self.suggestNow()
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

    /// One lookup for what is typed, when the gate allows it; a later change of text cancels it and
    /// drops its answer. Errors stay quiet while typing (return shows them), but a limit stops live
    /// lookups for a while.
    func lookUpLive() async {
        guard let query = liveQuery() else { return }
        let key = LiveLookupGate.key(query)
        switch gate.verdict(for: key, now: now()) {
        case .wait: return
        case .reuse:
            // Asked a moment ago (the text went back to it): the answer then, no second call.
            if resultsKey != key { results = answers[key] ?? []; resultsKey = results.isEmpty ? nil : key }
            return
        case .send: break
        }
        gate.didSend(now: now())
        searchGeneration += 1
        let gen = searchGeneration
        isSearching = true
        do {
            let found = try await flights.lookup(query)
            guard gen == searchGeneration, !Task.isCancelled else { return }
            results = found; resultsKey = key; error = nil
            answer(key, found)
        } catch {
            guard gen == searchGeneration else { return }
            if error == .rateLimited || error == .planLimit { gate.didHitLimit(now: now()) }
            if error == .notFound { answer(key, []) }
            results = []; resultsKey = nil
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
        guard let query = currentQuery() else {
            results = []; error = .notFound; isSearching = false; return
        }
        let key = LiveLookupGate.key(query)
        isSearching = true
        do {
            let found = try await flights.lookup(query)
            guard gen == searchGeneration else { return }
            results = found
            resultsKey = key
            error = nil
            answer(key, found)
            remember(text)
        } catch {
            guard gen == searchGeneration else { return }
            self.error = error
            if error == .rateLimited { gate.didHitLimit(now: now()) }
            if error == .notFound { results = []; resultsKey = nil }
        }
        isSearching = false
    }

    /// Keeps an answer for the gate's reuse window.
    private func answer(_ key: String, _ found: [Flight]) {
        gate.didAnswer(key, now: now())
        answers = answers.filter { gate.verdict(for: $0.key, now: now()) == .reuse }
        answers[key] = found
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

    /// Normalised (trimmed, upper case), moved to the front, deduplicated, capped.
    private func remember(_ raw: String) {
        let q = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !q.isEmpty else { return }
        recent = Array(([q] + recent.filter { $0 != q }).prefix(Self.recentLimit))
        defaults?.set(recent, forKey: Self.recentKey)
    }
}
