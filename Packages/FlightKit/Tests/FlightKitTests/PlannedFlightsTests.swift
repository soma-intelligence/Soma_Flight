import SwiftUI
import Testing
import FlightImportKit
@testable import FlightKit

/// Task 7: flights added weeks ahead show in My Flights as Planned rows until they are followed.
@MainActor @Suite struct PlannedFlightsTests {
    private let now = PreviewData.now

    private func planned(_ ident: String, daysAhead: Int, departure: Bool = true) -> UpcomingFlight {
        let date = now.addingTimeInterval(Double(daysAhead) * 86_400 + 3600)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .gmt
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return UpcomingFlight(ident: ident, day: LocalDay(year: c.year!, month: c.month!, day: c.day!),
                              origin: "KSFO", destination: "LFPG", departure: departure ? date : nil)
    }

    private func store() async -> MyFlightsStore {
        let s = MyFlightsStore(flights: FakeFlightService(now: now))
        await s.load()
        return s
    }

    private func render<V: View>(_ view: V) throws -> Data {
        let renderer = ImageRenderer(content: view.frame(width: 393).background(Theme.background)
            .environment(\.colorScheme, .dark))
        renderer.scale = 2
        let rep = NSBitmapImageRep(cgImage: try #require(renderer.cgImage))
        return try #require(rep.representation(using: .png, properties: [:]))
    }

    @Test func plannedItemSitsAmongFollowedByDeparture() async {
        let s = await store()
        let later = s.upcoming.filter { $0.status == .scheduled || $0.status == .unknown }
        #expect(!later.isEmpty)
        let first = later.compactMap(\.scheduledOut).min()!
        let last = later.compactMap(\.scheduledOut).max()!
        let early = UpcomingFlight(ident: "ZZ101", day: LocalDay(first.addingTimeInterval(-3600), in: .gmt),
                                   departure: first.addingTimeInterval(-3600))
        let late = UpcomingFlight(ident: "ZZ202", day: LocalDay(last.addingTimeInterval(86_400), in: .gmt),
                                  departure: last.addingTimeInterval(86_400))
        let groups = MyFlightsView.groups(live: s.live, upcoming: s.upcoming, planned: [late, early],
                                          lookup: PreviewData.airport)
        let rows = try! #require(groups.first { $0.title == "Upcoming" }).rows
        #expect(rows.count == later.count + 2)
        #expect(rows.first?.id == early.id)
        #expect(rows.last?.id == late.id)
        #expect(rows.map(\.departure) == rows.map(\.departure).sorted())
    }

    @Test func undatedPlannedFlightSortsByItsDay() {
        let a = planned("AF84", daysAhead: 30, departure: false)
        let b = planned("BA286", daysAhead: 20, departure: false)
        let rows = MyFlightsView.groups(live: [], upcoming: [], planned: [a, b], lookup: { _ in nil })[0].rows
        #expect(rows.map(\.id) == [b.id, a.id])
    }

    @Test func countdownReadsDaysThenHours() {
        let u = planned("AF84", daysAhead: 20)
        func col(_ s: TimeInterval) -> String {
            let c = PlannedFlight.countdown(u, origin: nil, now: u.departure!.addingTimeInterval(-s))
            return "\(c.value)|\(c.unit)"
        }
        #expect(col(20 * 86_400 + 5) == "20|DAYS")
        #expect(col(86_400 + 5) == "1|DAY")
        #expect(col(5 * 3600 + 5) == "5|HRS")
        #expect(col(3600 + 5) == "1|HR")
        #expect(col(40 * 60) == "|PLANNED")
        #expect(col(-60) == "|PLANNED")
    }

    @Test func countdownWithoutATimeUsesTheStartOfTheDayAtTheOrigin() {
        let sfo = DetailPart1Tests.sfo
        let u = UpcomingFlight(ident: "UA990", day: LocalDay(year: 2026, month: 11, day: 20))
        let start = PlannedFlight.departure(u, origin: sfo)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = sfo.timeZone
        #expect(start == cal.date(from: DateComponents(year: 2026, month: 11, day: 20)))
        let c = PlannedFlight.countdown(u, origin: sfo, now: start.addingTimeInterval(-3 * 86_400 - 60))
        #expect(c.value == "3" && c.unit == "DAYS")
        #expect(PlannedFlight.day(u) == "Fri, Nov 20")
    }

    @Test func removingEmptiesTheQueueEntry() {
        let queue = FollowLaterQueue(owner: nil, defaults: nil)
        let u = planned("AF84", daysAhead: 30)
        queue.add([u])
        #expect(queue.items.count == 1)
        queue.remove(u.id)
        #expect(queue.items.isEmpty)
    }

    @Test func swipeAndMenuDeleteCallOnRemovePlannedWithTheId() {
        // The seam is the action `MyFlightsView.plannedRow` hands both the swipe and the menu button.
        let u = planned("AF84", daysAhead: 30)
        var removed: [String] = []
        let view = MyFlightsView(store: MyFlightsStore(flights: FakeFlightService(now: now)), onSelect: { _ in },
                                 onSearch: nil, lookup: { _ in nil }, now: now, scrolls: false, planned: [u],
                                 onRemovePlanned: { removed.append($0) })
        view.deletePlanned(u)
        #expect(removed == [u.id])
    }

    @Test func plannedFlightFollowedByHandShowsOnlyOnce() async {
        let s = await store()
        let f = try! #require(s.upcoming.first { $0.status == .scheduled })
        let zone = PreviewData.airport(f.originIcao)?.timeZone ?? .gmt
        let dup = UpcomingFlight(ident: f.ident, day: LocalDay(f.scheduledOut!, in: zone))
        let other = planned("AF84", daysAhead: 40)
        let rows = MyFlightsView.groups(live: s.live, upcoming: s.upcoming, planned: [dup, other],
                                        lookup: PreviewData.airport)
            .flatMap(\.rows)
        #expect(!rows.contains { $0.id == dup.id })
        #expect(rows.contains { $0.id == other.id })
    }

    @Test func followingByHandDropsTheQueueEntry() async throws {
        let home = HomeModel(env: try await AppEnvironment.fake())
        let f = try #require(try await home.env.flights.followed().first { $0.scheduledOut != nil })
        let zone = home.env.lookup(f.originIcao)?.timeZone ?? .gmt
        let u = UpcomingFlight(ident: f.ident, day: LocalDay(f.scheduledOut!, in: zone))
        let keep = planned("AF84", daysAhead: 40)
        home.followLater.add([u, keep])
        await home.didFollow(f)
        #expect(home.followLater.items.map(\.id) == [keep.id])
    }

    @Test func addingTheSameFlightTwiceKeepsOne() {
        let queue = FollowLaterQueue(owner: nil, defaults: nil)
        let u = planned("AF84", daysAhead: 30)
        queue.add([u])
        queue.add([u])
        #expect(queue.items.count == 1)
    }

    @Test func emptyStateDoesNotShowWhilePlannedRowsExist() async throws {
        let empty = await MyFlightsPreview.makeStore(.empty)
        let u = planned("AF84", daysAhead: 30)
        #expect(MyFlightsView.groups(live: empty.live, upcoming: empty.upcoming, planned: [u],
                                     lookup: PreviewData.airport).count == 1)
        func view(_ items: [UpcomingFlight]) -> some View {
            MyFlightsView(store: empty, onSelect: { _ in }, onSearch: {}, lookup: PreviewData.airport, now: now,
                          scrolls: false, planned: items, onRemovePlanned: { _ in })
        }
        #expect(try render(view([])) != render(view([u])))
    }
}
