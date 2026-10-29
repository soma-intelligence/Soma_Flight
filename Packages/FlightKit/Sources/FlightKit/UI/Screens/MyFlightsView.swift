import SwiftUI

/// The home sheet: followed flights as cards, in the air first, then the ones still to come,
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

    /// - Parameters:
    ///   - onSearch: opens the search sheet from the empty state; nil hides the button.
    ///   - lookup: airport by ICAO, for city names and local times on the cards.
    ///   - now: a fixed clock for previews; nil follows the real time.
    public init(store: MyFlightsStore, onSelect: @escaping (Flight) -> Void, onSearch: (() -> Void)? = nil,
                lookup: @escaping (String) -> Airport? = { _ in nil }, now: Date? = nil) {
        self.init(store: store, onSelect: onSelect, onSearch: onSearch, lookup: lookup, now: now, scrolls: true)
    }

    init(store: MyFlightsStore, onSelect: @escaping (Flight) -> Void, onSearch: (() -> Void)?,
         lookup: @escaping (String) -> Airport?, now: Date?, scrolls: Bool) {
        self.store = store; self.onSelect = onSelect; self.onSearch = onSearch
        self.lookup = lookup; self.fixedNow = now; self.scrolls = scrolls
    }

    /// Cached-list age past which the offline badge turns amber.
    static let ttl: Duration = .seconds(300)

    public var body: some View {
        ClockView(fixed: fixedNow) { now in
            VStack(alignment: .leading, spacing: 0) {
                ScreenTitle("My Flights")
                    .padding(.horizontal, Theme.gutter)
                    .padding(.top, 22)
                    .padding(.bottom, 12)
                ScreenScroll(scrolls: scrolls, refresh: { await store.load() }) { content(now: now) }
            }
        }
        .background(Theme.background)
    }

    private var groups: [(title: String, flights: [Flight])] {
        let upcoming = store.upcoming
        let later = upcoming.filter { $0.status == .scheduled || $0.status == .unknown }
        let done = upcoming.filter { $0.status != .scheduled && $0.status != .unknown }
        return [("In the Air", store.live), ("Upcoming", later), ("Recent", done)].filter { !$0.flights.isEmpty }
    }

    @ViewBuilder private func content(now: Date) -> some View {
        let groups = self.groups
        VStack(alignment: .leading, spacing: 0) {
            if store.isOffline {
                ErrorBanner(error: .offline, retry: reload)
                    .padding(.bottom, 10)
                if let updated = store.fetchedAt ?? store.lastUpdated, !groups.isEmpty {
                    StaleBadge(fetchedAt: updated, ttl: Self.ttl, now: now)
                        .padding(.bottom, 14)
                }
            } else {
                if let error = store.error {
                    ErrorBanner(error: error, retry: reload)
                        .padding(.bottom, 14)
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
                    CapsHeader(group.title, trailing: group.flights.count == 1 ? "1 flight" : "\(group.flights.count) flights")
                        .padding(.top, 6)
                        .padding(.bottom, 10)
                    ForEach(group.flights) { flight in
                        Button { onSelect(flight) } label: {
                            FlightCard(flight: flight, origin: lookup(flight.originIcao),
                                       destination: lookup(flight.destinationIcao), now: now)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Stop Tracking", systemImage: "minus.circle", role: .destructive) {
                                Task { await store.unfollow(flight) }
                            }
                        }
                        .padding(.bottom, 12)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 24)
    }

    private func reload() { Task { await store.load() } }
}

/// Centered invitation shown when nothing is followed.
struct EmptyFlights: View {
    var onSearch: (() -> Void)?

    var body: some View {
        VStack(spacing: 6) {
            Spacer(minLength: 0)
            Text("Add a flight to start tracking")
                .scaledFont(17, weight: .semibold)
                .foregroundStyle(Theme.secondary)
            Text("Search by flight number, route or airport.")
                .scaledFont(15)
                .foregroundStyle(Theme.secondary.opacity(0.8))
            if let onSearch {
                Button(action: onSearch) {
                    Label("Search", systemImage: "magnifyingglass")
                        .scaledFont(15, weight: .semibold)
                        .foregroundStyle(Theme.primary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 9)
                        .background(Capsule().fill(Theme.pill))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .padding(.top, 10)
            }
            Spacer(minLength: 0)
        }
        .multilineTextAlignment(.center)
        .padding(.vertical, 24)
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
