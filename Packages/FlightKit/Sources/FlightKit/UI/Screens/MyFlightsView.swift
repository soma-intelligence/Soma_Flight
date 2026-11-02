import SwiftUI

/// The home sheet: followed flights as rows, in the air first, then the ones still to come,
/// then the finished, canceled and diverted ones until they are removed. Offline it shows the
/// last saved list with its age, and online it flags a list older than the TTL. With nothing followed
/// it invites a search; before the first load finishes it shows a spinner, and after a failed load with
/// nothing saved it shows only the error banner with its retry.
///
/// The shell owns loading: call `store.load()` and `store.startUpdates()` when it appears (the view
/// itself only reloads on pull to refresh and on the banner's retry).
public struct MyFlightsView: View {
    var store: MyFlightsStore
    var onSelect: (Flight) -> Void
    var onSearch: (() -> Void)?
    var lookup: (String) -> Airport?
    var fixedNow: Date?
    var scrolls: Bool
    var planned: [UpcomingFlight]
    var onRemovePlanned: (UpcomingFlight.ID) -> Void
    @Environment(\.reference) private var reference
    @Environment(\.connectivity) private var connectivity

    /// - Parameters:
    ///   - onSearch: opens the search sheet from the empty state; nil hides the button.
    ///   - lookup: airport by ICAO, for city names and local times on the rows.
    ///   - now: a fixed clock for previews; nil follows the real time.
    ///   - planned: flights added ahead of time and not followed yet (the follow-later queue), listed in
    ///     Upcoming with a "PLANNED" row; they have no detail screen, so tapping one does nothing.
    ///   - onRemovePlanned: deletes a planned flight by its id (swipe or the long-press menu).
    public init(store: MyFlightsStore, onSelect: @escaping (Flight) -> Void, onSearch: (() -> Void)? = nil,
                lookup: @escaping (String) -> Airport? = { _ in nil }, now: Date? = nil,
                planned: [UpcomingFlight] = [], onRemovePlanned: @escaping (UpcomingFlight.ID) -> Void = { _ in }) {
        self.init(store: store, onSelect: onSelect, onSearch: onSearch, lookup: lookup, now: now, scrolls: true,
                  planned: planned, onRemovePlanned: onRemovePlanned)
    }

    init(store: MyFlightsStore, onSelect: @escaping (Flight) -> Void, onSearch: (() -> Void)?,
         lookup: @escaping (String) -> Airport?, now: Date?, scrolls: Bool,
         planned: [UpcomingFlight] = [], onRemovePlanned: @escaping (UpcomingFlight.ID) -> Void = { _ in }) {
        self.store = store; self.onSelect = onSelect; self.onSearch = onSearch
        self.lookup = lookup; self.fixedNow = now; self.scrolls = scrolls
        self.planned = planned; self.onRemovePlanned = onRemovePlanned
    }

    /// One row of a group: a followed flight or a planned one, with the time it leaves for ordering.
    struct Row: Identifiable {
        enum Kind { case followed(Flight), planned(UpcomingFlight) }
        var id: String
        var departure: Date
        var kind: Kind
    }

    /// Cached-list age past which the offline badge turns amber.
    static let ttl: Duration = .seconds(300)

    public var body: some View {
        ClockView(fixed: fixedNow) { now in
            VStack(alignment: .leading, spacing: 0) {
                ScreenTitle("My Flights")
                    .scaledPadding(.horizontal, Theme.gutter)
                    .scaledPadding(.top, 22)
                    .scaledPadding(.bottom, 12)
                ScreenScroll(scrolls: scrolls, refresh: { await store.load() }) { content(now: now) }
            }
        }
        .background(Theme.background)
    }

    /// The groups in order: in the air, upcoming (followed and planned flights together, by departure),
    /// then recent. Empty groups are left out, so planned flights alone keep the empty state away.
    static func groups(live: [Flight], upcoming: [Flight], planned: [UpcomingFlight],
                       lookup: (String) -> Airport?) -> [(title: String, rows: [Row])] {
        func followed(_ f: Flight) -> Row { Row(id: f.id.uuidString, departure: f.scheduledOut ?? .distantFuture, kind: .followed(f)) }
        let later = upcoming.filter { $0.status == .scheduled || $0.status == .unknown }.map(followed)
        let waiting = planned.map { u in
            Row(id: u.id, departure: PlannedFlight.departure(u, origin: u.origin.flatMap(lookup)), kind: .planned(u))
        }
        // A stable merge: equal departures keep followed flights first.
        let merged = (later + waiting).enumerated()
            .sorted { $0.element.departure == $1.element.departure ? $0.offset < $1.offset : $0.element.departure < $1.element.departure }
            .map(\.element)
        let done = upcoming.filter { $0.status != .scheduled && $0.status != .unknown }.map(followed)
        return [("In the Air", live.map(followed)), ("Upcoming", merged), ("Recent", done)].filter { !$0.rows.isEmpty }
    }

    private var groups: [(title: String, rows: [Row])] {
        Self.groups(live: store.live, upcoming: store.upcoming, planned: planned, lookup: lookup)
    }

    @ViewBuilder private func content(now: Date) -> some View {
        let groups = self.groups
        VStack(alignment: .leading, spacing: 0) {
            // Offline is not an error here: the saved list keeps working, so the banner stays calm.
            if store.isOffline || connectivity?.isOnline == false {
                OfflineBanner(retry: reload)
                    .scaledPadding(.bottom, 10)
                if let updated = store.fetchedAt ?? store.lastUpdated, !groups.isEmpty {
                    StaleBadge(fetchedAt: updated, ttl: Self.ttl, now: now)
                        .scaledPadding(.bottom, 14)
                }
            } else {
                if let error = store.error {
                    ErrorBanner(error: error, retry: reload)
                        .scaledPadding(.bottom, 14)
                }
                // A live subscription that is healthy keeps the list current even when nothing changes.
                if !groups.isEmpty, !store.isLiveSynced {
                    SectionFreshness(fetchedAt: store.fetchedAt, ttl: Self.ttl, now: now, bottom: 14)
                }
            }
            if groups.isEmpty {
                if !store.hasLoaded || (store.error != nil && store.isLoading) {
                    // First load, or a retry after a failed one with nothing saved.
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 200)
                        .accessibilityLabel("Loading your flights")
                } else if store.error == nil {
                    EmptyFlights(onSearch: onSearch)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 200)
                }
            } else {
                ForEach(groups, id: \.title) { group in
                    CapsHeader(group.title, trailing: group.rows.count == 1 ? "1 flight" : "\(group.rows.count) flights")
                        .scaledPadding(.top, 6)
                        .scaledPadding(.bottom, 10)
                    ForEach(group.rows) { row in
                        switch row.kind {
                        case .followed(let flight): followedRow(flight, now: now)
                        case .planned(let flight): plannedRow(flight, now: now)
                        }
                    }
                    Spacer().frame(height: 0).scaledPadding(.bottom, 14)
                }
            }
        }
        .scaledPadding(.horizontal, 16)
        .scaledPadding(.bottom, 24)
    }

    private func followedRow(_ flight: Flight, now: Date) -> some View {
        Button { onSelect(flight) } label: {
            MyFlightRow(flight: flight, origin: lookup(flight.originIcao),
                        destination: lookup(flight.destinationIcao), airline: airline(flight), now: now)
        }
        .buttonStyle(.plain)
        .swipeToDelete("Delete \(Format.ident(flight.ident))") {
            Task { await store.unfollow(flight) }
        }
        .contextMenu {
            Button("Delete Flight", systemImage: "trash", role: .destructive) {
                Task { await store.unfollow(flight) }
            }
        }
    }

    /// A planned flight has no detail screen, so the row is not a button: a tap does nothing.
    private func plannedRow(_ flight: UpcomingFlight, now: Date) -> some View {
        PlannedFlightRow(flight: flight, origin: flight.origin.flatMap(lookup),
                         destination: flight.destination.flatMap(lookup),
                         airline: reference.airline(ident: flight.ident), now: now)
            .swipeToDelete("Delete \(Format.ident(flight.ident))") { onRemovePlanned(flight.id) }
            .contextMenu {
                Button("Delete Flight", systemImage: "trash", role: .destructive) { onRemovePlanned(flight.id) }
            }
    }

    private func reload() { Task { await store.load() } }

    private func airline(_ f: Flight) -> Airline? {
        f.operator.flatMap { reference.airline($0) } ?? reference.airline(ident: f.ident)
    }
}

/// Centered invitation shown when nothing is followed: the climbing jet, a short title and Search.
struct EmptyFlights: View {
    var onSearch: (() -> Void)?

    var body: some View {
        VStack(spacing: 6) {
            Spacer(minLength: 0)
            // Smaller than Passport's: the home sheet opens at half height and Search should stay in view.
            EmptyStateIllustration(variant: .climb, size: 240)
                .scaledPadding(.bottom, 10)
            Text("Where to next?")
                .scaledFont(20, weight: .semibold)
                .foregroundStyle(Theme.primary)
                .accessibilityAddTraits(.isHeader)
            Text("Add a flight you're taking by number, route or airport.")
                .scaledFont(15)
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let onSearch {
                Button(action: onSearch) {
                    Label("Search", systemImage: "magnifyingglass")
                        .scaledFont(15, weight: .semibold)
                        .foregroundStyle(Theme.primary)
                        .scaledPadding(.horizontal, 16)
                        .scaledPadding(.vertical, 9)
                        .background(Capsule().fill(Theme.pill))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .scaledPadding(.top, 10)
            }
            Spacer(minLength: 0)
        }
        .multilineTextAlignment(.center)
        .scaledPadding(.vertical, 24)
    }
}

#if DEBUG
// MARK: - Previews

/// Loads a My Flights store from the seed at the seed's own clock.
struct MyFlightsPreview: View {
    enum Mode { case full, empty, error, offline, offlineEmpty, stale, loading }
    var state: Mode = .full
    @State private var store: MyFlightsStore?

    var body: some View {
        Group {
            if let store {
                MyFlightsView(store: store, onSelect: { _ in }, onSearch: {}, lookup: PreviewData.airport,
                              now: PreviewData.now)
            } else {
                ProgressView()
            }
        }
        .task { store = await Self.makeStore(state) }
    }

    static func makeStore(_ state: Mode) async -> MyFlightsStore {
        let svc = FakeFlightService(now: PreviewData.now)
        switch state {
        case .full:
            let s = MyFlightsStore(flights: svc)
            await s.load()
            return s
        case .empty:
            let s = MyFlightsStore(flights: svc)
            await s.load()
            for f in s.live + s.upcoming { await s.unfollow(f) }
            return s
        case .error:
            let s = MyFlightsStore(flights: svc)
            await s.load()
            await svc.setNextError(.providerUnavailable)
            await s.load()
            return s
        case .offline:
            let s = MyFlightsStore(flights: svc, cache: PreviewCache(age: 25 * 60))
            await svc.setNextError(.offline)
            await s.load()
            return s
        case .stale:
            let s = MyFlightsStore(flights: svc)
            await s.load()
            s.fetchedAt = PreviewData.now.addingTimeInterval(-25 * 60)
            return s
        case .loading:
            return MyFlightsStore(flights: svc)
        case .offlineEmpty:
            let s = MyFlightsStore(flights: svc, cache: EmptyPreviewCache())
            await svc.setNextError(.offline)
            await s.load()
            return s
        }
    }
}

#Preview("Flights, dark") {
    MyFlightsPreview().preferredColorScheme(.dark)
}

#Preview("Flights, light") {
    MyFlightsPreview().preferredColorScheme(.light)
}

#Preview("Empty") {
    MyFlightsPreview(state: .empty).preferredColorScheme(.dark)
}

#Preview("Error, list kept") {
    MyFlightsPreview(state: .error).preferredColorScheme(.dark)
}

#Preview("Offline, stale") {
    MyFlightsPreview(state: .offline).preferredColorScheme(.dark)
}

#Preview("Online, list stale") {
    MyFlightsPreview(state: .stale).preferredColorScheme(.dark)
}

#Preview("Loading") {
    MyFlightsPreview(state: .loading).preferredColorScheme(.dark)
}

#Preview("Offline, nothing saved") {
    MyFlightsPreview(state: .offlineEmpty).preferredColorScheme(.light)
}
#endif
