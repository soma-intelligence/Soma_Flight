import Foundation
import SwiftUI
import Testing
@testable import FlightKit

// The home, search and shell side of the 2026-11-18 premium checklist audit
// (docs/audits/2026-11-18-premium-checklist-audit.md): one test or more per finding id.

@MainActor private func eventually(_ cond: () -> Bool) async {
    for _ in 0..<300 where !cond() { try? await Task.sleep(for: .milliseconds(10)) }
}

@MainActor @Suite struct HomeShellFixTests {
    private static let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private static func store() -> SearchStore { SearchStore(flights: FakeFlightService()) }

    // MARK: I11

    @Test func i11ReopeningSoonBringsTheSameSearchBack() {
        let keeper = SearchKeeper()
        let first = keeper.open(now: Self.t0, make: Self.store)
        first.text = "AF84"
        keeper.close(now: Self.t0)
        let again = keeper.open(now: Self.t0.addingTimeInterval(60), make: Self.store)
        #expect(again === first)
        #expect(again.text == "AF84")
    }

    @Test func i11AnOldOrClearedSearchStartsFresh() {
        let keeper = SearchKeeper()
        let first = keeper.open(now: Self.t0, make: Self.store)
        first.text = "AF84"
        keeper.close(now: Self.t0)
        let later = keeper.open(now: Self.t0.addingTimeInterval(SearchKeeper.keepFor + 1), make: Self.store)
        #expect(later !== first)

        later.text = "  "
        keeper.close(now: Self.t0)
        let cleared = keeper.open(now: Self.t0.addingTimeInterval(5), make: Self.store)
        #expect(cleared !== later)
    }

    @Test func i11AnOpenSearchIsKeptAndAnAccountChangeForgetsIt() {
        let keeper = SearchKeeper()
        let open = keeper.open(now: Self.t0, make: Self.store)
        // Presented again while open (a fold): the same store, whatever its text.
        #expect(keeper.open(now: Self.t0.addingTimeInterval(3600), make: Self.store) === open)
        keeper.forget()
        #expect(keeper.current == nil)
        #expect(keeper.open(now: Self.t0, make: Self.store) !== open)
    }

    // MARK: D6

    @Test func d6NoResultIsWordedForWhatWasSearched() {
        var number = SearchIntent(); number.ident = "AF84"
        var route = SearchIntent(); route.origins = ["LFPG"]; route.destinations = ["LIRF"]
        var airport = SearchIntent(); airport.origins = ["KSFO"]
        let nothing = SearchIntent()
        #expect(SearchEmptyState.kind(number) == .flightNumber)
        #expect(SearchEmptyState.kind(route) == .route)
        #expect(SearchEmptyState.kind(airport) == .airport)
        #expect(SearchEmptyState.kind(nothing) == .other)
        #expect(SearchEmptyState.title(.route) != SearchEmptyState.title(.flightNumber))
        // "Check the number" only for a flight number.
        #expect(!SearchEmptyState.message(.route).contains("number"))
    }

    @Test func d6ASearchThatFindsNothingIsNotFoundForTheEmptyState() async {
        let s = SearchStore(flights: FakeFlightService(now: PreviewData.now))
        s.text = "ZZ999"
        await s.search()
        #expect(s.error == .notFound)
        #expect(SearchEmptyState.kind(s.intent) == .flightNumber)
    }

    // MARK: I10

    @Test func i10ReselectPopsCardsFirstThenScrollsUp() {
        #expect(TabReselect.action(cardsOpen: true) == .popCards)
        #expect(TabReselect.action(cardsOpen: false) == .scrollToTop)
    }

    @Test func i10TabsSitInThePillsOrder() {
        #expect(TabPager<EmptyView>.slot(of: .flights, selected: .flights) == 0)
        #expect(TabPager<EmptyView>.slot(of: .friends, selected: .flights) == 1)
        #expect(TabPager<EmptyView>.slot(of: .flights, selected: .passport) == -2)
    }

    // MARK: E3, E16

    @Test func e3AnExpiryOverTheHomeKeepsTheHome() {
        let expiredOverHome = SignInGate<EmptyView>.screen(needsSignIn: true, sessionExpired: true, homeShown: true,
                                                           awaitingSession: false, gate: .hidden, profileWaitOver: false)
        #expect(expiredOverHome == .home)
        let signedOut = SignInGate<EmptyView>.screen(needsSignIn: true, sessionExpired: false, homeShown: true,
                                                     awaitingSession: false, gate: .hidden, profileWaitOver: false)
        #expect(signedOut == .signIn)
        let firstLaunch = SignInGate<EmptyView>.screen(needsSignIn: true, sessionExpired: true, homeShown: false,
                                                       awaitingSession: false, gate: .hidden, profileWaitOver: false)
        #expect(firstLaunch == .signIn)
    }

    @Test func e16TheProfileWaitIsCapped() {
        let waiting = SignInGate<EmptyView>.screen(needsSignIn: false, sessionExpired: false, homeShown: false,
                                                   awaitingSession: false, gate: .unknown, profileWaitOver: false)
        #expect(waiting == .placeholder)
        let capped = SignInGate<EmptyView>.screen(needsSignIn: false, sessionExpired: false, homeShown: false,
                                                  awaitingSession: false, gate: .unknown, profileWaitOver: true)
        #expect(capped == .home)
        #expect(SignInGate<EmptyView>.profileWaitCap <= .seconds(5))
        #expect(LaunchPlaceholder.progressDelay <= .seconds(1))
    }

    // MARK: E15, I1

    @Test func e15TheRowStaysHiddenWhileTheRemovalWaitsAndComesBackOnUndo() async throws {
        var env = try await AppEnvironment.fake()
        env.fixedConnectivity = true
        let home = HomeModel(env: env)
        // A long Undo window: the test undoes before the server is asked.
        home.toastSleep = { _ in try await Task.sleep(for: .seconds(30)) }
        await home.myFlights.load()
        let f = try #require(home.followed.first)
        func shownIDs() -> [String] {
            MyFlightsView.groups(live: home.myFlights.live, upcoming: home.myFlights.upcoming, planned: [],
                                 lookup: { _ in nil }).flatMap { $0.rows.map(\.id) }
        }
        #expect(shownIDs().contains(f.id.uuidString))
        home.unfollowWithUndo(f)
        #expect(!shownIDs().contains(f.id.uuidString))
        #expect(home.myFlights.contains(f.id))
        home.undoUnfollow(f.id)
        #expect(shownIDs().contains(f.id.uuidString))
    }

    // MARK: D3, A1

    @Test func d3StopFollowingIsTheWordForAFollowedFlight() {
        #expect(MyFlightsView.stopFollowing == "Stop Following")
        #expect(!MyFlightsView.removePlannedAction.contains("Delete"))
    }

    // MARK: E2

    @Test func e2TheOfflinePillSaysHowOldTheListIs() {
        #expect(OfflineBanner.Pill.text(fetchedAt: nil, now: Self.t0) == OfflineBanner.Pill.text)
        let aged = OfflineBanner.Pill.text(fetchedAt: Self.t0.addingTimeInterval(-25 * 60), now: Self.t0)
        #expect(aged.hasPrefix("Offline"))
        #expect(aged.contains("25"))
    }
}
