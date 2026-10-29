import Foundation
import SwiftUI
import Testing
@testable import FlightKit

/// Task 6b fix round 1: the clock setting, the load states, grouping and wording fixes.
@Suite @MainActor struct ScreenReviewFixTests {
    // MARK: Clock

    @Test func clockStyles() {
        let utc = TimeZone(identifier: "UTC")!
        let d = { (s: String) in ISO8601DateFormatter().date(from: s)! }
        #expect(Format.clock(d("2026-10-28T00:05:00Z"), utc) == "00:05")
        #expect(Format.clock(d("2026-10-28T00:05:00Z"), utc, .h12) == "12:05 AM")
        #expect(Format.clock(d("2026-10-28T12:00:00Z"), utc, .h12) == "12:00 PM")
        #expect(Format.clock(d("2026-10-28T18:25:00Z"), utc, .h12) == "6:25 PM")
        #expect(Format.clock(d("2026-10-28T18:25:00Z"), utc, .h24) == "18:25")
        #expect(Format.clock(d("2026-10-28T23:59:00Z"), TimeZone(identifier: "America/Chicago")!, .h12) == "6:59 PM")
    }

    // MARK: Loading states

    @Test func myFlightsLoadStates() async {
        let svc = FakeFlightService(now: PreviewData.now)
        let ok = MyFlightsStore(flights: svc)
        #expect(!ok.hasLoaded && ok.fetchedAt == nil)
        await ok.load()
        #expect(ok.hasLoaded && ok.error == nil && ok.fetchedAt != nil)

        // A failure with nothing saved: loaded, empty, and the error is what the screen shows.
        let failing = MyFlightsStore(flights: svc, cache: EmptyPreviewCache())
        await svc.setNextError(.offline)
        await failing.load()
        #expect(failing.hasLoaded && failing.error == .offline && failing.live.isEmpty && failing.upcoming.isEmpty)
        #expect(failing.fetchedAt == nil)

        // Offline with a saved copy: the badge measures the save time.
        let cached = MyFlightsStore(flights: svc, cache: PreviewCache(age: 600))
        await svc.setNextError(.offline)
        await cached.load()
        #expect(cached.fetchedAt == PreviewData.now.addingTimeInterval(-600))
    }

    @Test func passportLoadStates() async {
        let svc = FakeHistoryService()
        let ok = PassportStore(history: svc)
        #expect(!ok.hasLoaded)
        await ok.load()
        #expect(ok.hasLoaded && ok.fetchedAt != nil && ok.error == nil)

        let failing = PassportStore(history: svc, cache: EmptyPreviewCache())
        await svc.setNextError(.providerUnavailable)
        await failing.load()
        #expect(failing.hasLoaded && failing.error == .providerUnavailable && failing.flights.isEmpty)

        let empty = PassportStore(history: EmptyHistory())
        await empty.load()
        #expect(empty.hasLoaded && empty.error == nil && empty.flights.isEmpty)
    }

    // MARK: Wording and grouping

    @Test func airlineGroupsMergeByCode() {
        let d = { (s: String) in ISO8601DateFormatter().date(from: s)! }
        let flights = [
            PastFlight(date: d("2026-01-01T12:00:00Z"), ident: "UA1", originIcao: "KSFO", destinationIcao: "KAUS",
                       airline: nil, aircraftType: nil, distanceKm: 100),
            PastFlight(date: d("2026-02-01T12:00:00Z"), ident: "UA2", originIcao: "KAUS", destinationIcao: "KSFO",
                       airline: "United", aircraftType: nil, distanceKm: 100),
        ]
        let groups = TravelFacts.groups(flights, by: .airline, city: { $0 })
        #expect(groups.count == 1)
        #expect(groups[0].title == "United" && groups[0].flights.count == 2)
    }

    @Test func landedAndArrivalWording() {
        var f = PreviewData.enRoute
        let now = PreviewData.now
        f.status = .landed
        f.actualOn = nil
        f.actualIn = now.addingTimeInterval(-20)
        #expect(DetailFacts.progressLine(f, now: now) == "Landed just now")
        f.actualIn = now.addingTimeInterval(-3 * 3600)
        #expect(DetailFacts.progressLine(f, now: now) == "Landed 3h ago")
        f.status = .enRoute; f.actualIn = nil; f.estimatedIn = now.addingTimeInterval(10)
        #expect(DetailFacts.progressLine(f, now: now) == "Arrives in under a minute")
        f.estimatedIn = now.addingTimeInterval(2 * 3600 + 14 * 60)
        #expect(DetailFacts.progressLine(f, now: now) == "Arrives in 2h 14m")
        f.status = .scheduled; f.actualOut = nil; f.estimatedOut = now.addingTimeInterval(45 * 60)
        #expect(DetailFacts.progressLine(f, now: now) == "Leaves the gate in 45m")
    }

    @Test func emailValidationTrimsFirst() {
        #expect(SignInView.isValid("a@b.co"))
        #expect(SignInView.isValid("  a@b.co \n"))
        #expect(!SignInView.isValid("a@b"))
        #expect(!SignInView.isValid("a b@c.co"))
    }

    @Test func distanceRounding() {
        #expect(TravelFacts.distance(1_000, .mi) == "621 mi")
        #expect(TravelFacts.distance(0, .km) == "0 km")
    }

    @Test func eventTextForKinds() {
        let now = PreviewData.now
        func event(_ kind: FlightEventKind, _ payload: [String: String] = [:]) -> FlightEvent {
            FlightEvent(flightId: UUID(), kind: kind, payload: payload, receivedAt: now)
        }
        #expect(DetailFacts.eventText(event(.gateChange, ["gate": "B12"])) == "Gate changed to B12")
        #expect(DetailFacts.eventText(event(.gateChange)) == "Gate changed")
    }

    #if os(macOS)
    // MARK: Rendering: the clock setting and the screen states reach the pixels

    private func render<V: View>(_ view: V, width: CGFloat = 393) throws -> (data: Data, height: Int) {
        let renderer = ImageRenderer(content: view.frame(width: width).background(Theme.background)
            .environment(\.airportStaticControls, true).environment(\.colorScheme, .dark))
        renderer.scale = 2
        let cg = try #require(renderer.cgImage)
        let rep = NSBitmapImageRep(cgImage: cg)
        return (try #require(rep.representation(using: .png, properties: [:])), cg.height)
    }

    private func differs<V: View>(_ make: (Units) -> V) throws -> Bool {
        let a = try render(make(Units(clock: .h24)).environment(\.units, Units(clock: .h24)))
        let b = try render(make(Units(clock: .h12)).environment(\.units, Units(clock: .h12)))
        return a.data != b.data
    }

    @Test func clockSettingChangesEveryTimeDisplay() throws {
        let now = PreviewData.now, tz = PreviewData.kaus.timeZone
        let flight = PreviewData.enRoute
        #expect(try differs { _ in
            FlightCard(flight: flight, origin: PreviewData.airport(flight.originIcao),
                       destination: PreviewData.airport(flight.destinationIcao), now: now)
        })
        #expect(try differs { _ in
            FlightTimeline(flight: flight, origin: PreviewData.airport(flight.originIcao),
                           destination: PreviewData.airport(flight.destinationIcao), now: now)
        })
        let row = PreviewData.board("KAUS", .departures).flights[3]
        #expect(try differs { _ in
            BoardRow(flight: row, kind: .departures, airport: PreviewData.airport(row.destinationIcao),
                     timeZone: tz, now: now, striped: false)
        })
        #expect(try differs { _ in
            ResultRow(flight: flight, origin: PreviewData.airport(flight.originIcao),
                      destination: PreviewData.airport(flight.destinationIcao), state: .idle, onFollow: {})
        })
        let ev = FlightEvent(flightId: flight.id, kind: .gateChange, payload: ["gate": "B12"], receivedAt: now)
        #expect(try differs { _ in EventRow(event: ev, timeZone: tz) })
    }

    @Test func settingsHidesRowsWithoutActions() async throws {
        let session = SettingsPreview.makeSession(plan: .free, failDelete: false)
        let units = Binding.constant(Units())
        let bare = try render(SettingsView(session: session, units: units, scrolls: false))
        let full = try render(SettingsView(session: session, units: units, onExport: { _ in }, onDeleteAccount: {}, scrolls: false))
        #expect(full.height > bare.height)
    }

    @Test func staleListShowsBadgeOnline() async throws {
        let fresh = await MyFlightsPreview.makeStore(.full)
        let stale = await MyFlightsPreview.makeStore(.stale)
        // Same clock for both: the fresh store was fetched after it, the stale one 25 minutes before it.
        let nowForFresh = PreviewData.now
        let a = try render(MyFlightsView(store: fresh, onSelect: { _ in }, onSearch: nil, lookup: PreviewData.airport,
                                         now: nowForFresh, scrolls: false))
        let b = try render(MyFlightsView(store: stale, onSelect: { _ in }, onSearch: nil, lookup: PreviewData.airport,
                                         now: nowForFresh, scrolls: false))
        #expect(b.height > a.height)
    }

    @Test func loadingAndFailedStatesShowNoInvitation() async throws {
        let empty = try render(MyFlightsView(store: await MyFlightsPreview.makeStore(.empty), onSelect: { _ in },
                                             onSearch: {}, lookup: PreviewData.airport, now: PreviewData.now, scrolls: false))
        let loading = try render(MyFlightsView(store: await MyFlightsPreview.makeStore(.loading), onSelect: { _ in },
                                               onSearch: {}, lookup: PreviewData.airport, now: PreviewData.now, scrolls: false))
        let failed = try render(MyFlightsView(store: await MyFlightsPreview.makeStore(.offlineEmpty), onSelect: { _ in },
                                              onSearch: {}, lookup: PreviewData.airport, now: PreviewData.now, scrolls: false))
        #expect(empty.data != loading.data)
        #expect(empty.data != failed.data)
        #expect(loading.data != failed.data)
    }
    #endif
}

/// Task 6b fix round 2: live freshness, retry progress, hour labels and pinned wording.
@Suite @MainActor struct ScreenReviewFixRound2Tests {
    @Test func liveStreamIsFreshWhateverTheAge() async {
        let svc = FakeFlightService(now: PreviewData.now)
        let store = MyFlightsStore(flights: svc)
        #expect(!store.isLiveSynced)
        await store.load()
        #expect(!store.isLiveSynced)            // loaded, but no update loop yet
        store.startUpdates()
        #expect(store.isLiveSynced)
        store.fetchedAt = Date.now.addingTimeInterval(-3600)
        #expect(store.isLiveSynced)             // quiet stream, still fresh

        await svc.setNextError(.providerUnavailable)
        await store.load()
        #expect(!store.isLiveSynced)            // failed refresh: age decides again
        await store.load()
        #expect(store.isLiveSynced)             // recovered

        let offline = MyFlightsStore(flights: svc, cache: PreviewCache(age: 600))
        offline.startUpdates()
        await svc.setNextError(.offline)
        await offline.load()
        #expect(!offline.isLiveSynced)
    }

    @Test func retryShowsLoading() async {
        let svc = FakeFlightService(now: PreviewData.now)
        let store = MyFlightsStore(flights: svc, cache: EmptyPreviewCache())
        #expect(!store.isLoading)
        await svc.setNextError(.providerUnavailable)
        await store.load()
        #expect(store.hasLoaded && store.error != nil && !store.isLoading)
        let retry = Task { await store.load() }
        await Task.yield()
        await retry.value
        #expect(!store.isLoading && store.error == nil)
    }

    @Test func hourLabelsFollowTheClock() {
        #expect(DelayTrendChart.hourLabel(0, .h24) == "0")
        #expect(DelayTrendChart.hourLabel(18, .h24) == "18")
        #expect(DelayTrendChart.hourLabel(0, .h12) == "12 AM")
        #expect(DelayTrendChart.hourLabel(12, .h12) == "12 PM")
        #expect(DelayTrendChart.hourLabel(18, .h12) == "6 PM")
    }

    @Test func dayWordingIsEnglishWhateverTheDeviceLocale() {
        let d = ISO8601DateFormatter().date(from: "2026-10-23T12:00:00Z")!
        let utc = TimeZone(identifier: "UTC")!
        #expect(ScreenFormat.day(d, utc) == "Oct 23, 2026")
        #expect(ScreenFormat.chipDay(d, utc) == "Fri, Oct 23")
    }
}
