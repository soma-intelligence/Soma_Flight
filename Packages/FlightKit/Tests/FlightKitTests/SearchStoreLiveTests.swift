import Foundation
import Testing
@testable import FlightKit

@MainActor private func eventually(_ cond: () -> Bool) async {
    for _ in 0..<200 where !cond() { try? await Task.sleep(for: .milliseconds(10)) }
}

/// The search store as the user types: suggestions, picking a row, return, and the live lookup a pause
/// in typing makes (once per query, never past a rate limit).
@Suite @MainActor struct SearchStoreLiveTests {
    static func store(_ svc: ScriptedFlights = ScriptedFlights(stall: .zero)) -> SearchStore {
        let s = SearchStore(flights: svc)
        s.suggestDelay = .milliseconds(1)
        s.liveDelay = .milliseconds(20)
        return s
    }

    @Test func typingSuggestsAfterTheDebounce() async {
        let s = Self.store()
        s.known = SearchSuggesterTests.known
        s.text = "AF 8"
        s.textChanged()
        await eventually { !s.suggestions.isEmpty }
        #expect(s.suggestions.groups.first?.kind == .flights)
        s.text = ""
        s.textChanged()
        #expect(s.suggestions.isEmpty)
    }

    @Test func aPauseOnAWholeNumberLooksItUpOnce() async {
        let svc = ScriptedFlights(stall: .zero)
        let s = Self.store(svc)
        s.text = "AF84"
        s.textChanged()
        await eventually { !s.results.isEmpty }
        #expect(s.results.allSatisfy { $0.ident == "AF84" })
        #expect(svc.lookups == 1)
        // The same text again (a space, then back) reuses the answer.
        s.text = "AF84 "; s.textChanged()
        s.text = "AF84"; s.textChanged()
        try? await Task.sleep(for: .milliseconds(80))
        #expect(svc.lookups == 1)
        #expect(!s.results.isEmpty)
        // A live lookup is not a search the user made: recents stay as they were.
        #expect(s.recent.isEmpty)
    }

    /// Every way of typing a flight number looks it up after the pause, no return needed.
    @Test(arguments: ["af84", "AF 84", "air france 84", "84 af"])
    func aPauseOnAnyFormOfANumberLooksItUp(_ text: String) async {
        let svc = ScriptedFlights(stall: .zero)
        let s = Self.store(svc)
        s.text = text
        s.textChanged()
        await eventually { !s.results.isEmpty }
        #expect(s.results.allSatisfy { $0.ident == "AF84" }, "\(text)")
        #expect(svc.lookups == 1, "\(text)")
    }

    /// Two places with no day look the route up on the pause; a lone place still waits for a day.
    @Test func aPauseOnTwoPlacesLooksTheRouteUp() async {
        let svc = ScriptedFlights(stall: .zero)
        let s = Self.store(svc)
        s.text = "paris"
        await s.lookUpLive()
        #expect(svc.lookups == 0)
        s.text = "paris marseille"
        await s.lookUpLive()
        #expect(svc.lookups > 0)
    }

    /// The results come first while typing: the suggestions under them drop the flight number already
    /// found and the recent searches.
    @Test func typingSuggestionsSkipWhatTheResultsShow() async {
        let s = Self.store()
        s.known = SearchSuggesterTests.known
        s.seedRecent(["AF84"])
        s.text = "AF84"
        await s.search()
        s.suggestNow()
        let shown = SearchView.typingSuggestions(s.suggestions, results: s.items)
        #expect(!s.items.isEmpty)
        #expect(!shown.all.contains { if case .flight(let i, _) = $0 { SearchText.ident(i) == "AF84" } else { false } })
        #expect(!shown.groups.contains { $0.kind == .recent })
    }

    @Test func typingOnCancelsThePendingLookup() async {
        let svc = ScriptedFlights(stall: .zero)
        let s = Self.store(svc)
        s.liveDelay = .milliseconds(100)
        s.text = "AF84"; s.textChanged()
        s.text = "air fr"; s.textChanged()
        try? await Task.sleep(for: .milliseconds(200))
        #expect(svc.lookups == 0)
        #expect(s.results.isEmpty)
    }

    @Test func newTextDropsResultsThatNoLongerFit() async {
        let s = Self.store()
        s.text = "AF84"
        await s.search()
        #expect(!s.results.isEmpty)
        s.text = "paris"; s.textChanged()
        #expect(s.results.isEmpty)
    }

    @Test func aRateLimitStopsLiveLookups() async {
        let svc = ScriptedFlights(stall: .zero)
        let s = Self.store(svc)
        await svc.inner.setNextError(.rateLimited)
        s.text = "AF84"
        await s.lookUpLive()
        #expect(svc.lookups == 1)
        #expect(s.error == nil)                 // quiet while typing
        s.text = "UA1527"
        await s.lookUpLive()
        #expect(svc.lookups == 1)
        // Return still searches.
        await s.search()
        #expect(svc.lookups == 2)
        #expect(s.results.first?.ident == "UA1527")
    }

    @Test func nothingLiveForPartialText() async {
        let svc = ScriptedFlights(stall: .zero)
        let s = Self.store(svc)
        for t in ["paris", "CDG", "air fr", "Paris to San F"] {
            s.text = t
            await s.lookUpLive()
        }
        #expect(svc.lookups == 0)
    }

    @Test func pickingAnAirlineFillsItsCode() {
        let s = Self.store()
        let pick = s.pick(.airline(ReferenceData.bundled().airline("AFR")!))
        #expect(pick == .filled)
        #expect(s.text == "AF ")
        #expect(!s.suggestions.isEmpty)
    }

    @Test func pickingAnAirportOffersItsBoard() {
        let s = Self.store()
        let cdg = AirportDirectory.bundled().airport("CDG")!
        #expect(s.pick(.airport(cdg)) == .filled)
        #expect(s.text == "CDG ")
        #expect(s.suggestions.top == .board(cdg))
        #expect(s.pick(.board(cdg)) == .openAirport("LFPG"))
    }

    @Test func returnPicksTheTopSuggestion() async throws {
        // The fakes move their flights to around now, and a route lists only the asked day's departures
        // in Paris: the store's clock sits at AF84's departure, so late evening UTC (already tomorrow in
        // Paris) does not drop it.
        let af84 = try await FakeFlightService().lookup(.route(origin: "LFPG", destination: "KSFO", date: .now))
        let out = try #require(af84.first?.scheduledOut)
        let s = SearchStore(flights: ScriptedFlights(stall: .zero), now: { out })
        s.suggestDelay = .milliseconds(1)
        s.liveDelay = .milliseconds(20)
        s.text = "air fr"
        #expect(s.submit() == .filled)
        #expect(s.text == "AF ")
        s.text = "Paris to San Francisco"
        #expect(s.submit() == .searching)
        #expect(s.text == "CDG SFO")
        await eventually { !s.results.isEmpty }
        #expect(!s.results.isEmpty)
        #expect(s.results.allSatisfy { $0.originIcao == "LFPG" && $0.destinationIcao == "KSFO" })
        #expect(s.recent.first == "CDG SFO")
    }

    @Test func returnOnAFlightNumberSearchesIt() async {
        let s = Self.store()
        s.text = "UA 1527"
        #expect(s.submit() == .searching)
        await eventually { !s.results.isEmpty }
        #expect(s.results.first?.ident == "UA1527")
    }

    @Test func returnWithNoSuggestionStillSearches() async {
        let s = Self.store()
        s.text = "ZZ999"
        // "ZZ999" is offered as typed, so return searches it, and the fakes do not know it.
        #expect(s.submit() == .searching)
        await eventually { s.error != nil }
        #expect(s.error == .notFound)
        #expect(s.text == "ZZ999")
    }
}
