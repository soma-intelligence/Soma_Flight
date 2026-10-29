import SwiftUI

/// The travel record: year chips, the passport card with lifetime or yearly totals, time lost to
/// delays, the aircraft flown most, and every past flight, sortable. The route arcs live on the
/// shell's globe, not here.
public struct PassportView: View {
    @Bindable var store: PassportStore
    var lookup: (String) -> Airport?
    var fixedNow: Date?
    var scrolls: Bool

    @State private var sort: TravelFacts.Sort = .date
    @Environment(\.units) private var units

    /// - Parameters:
    ///   - lookup: airport by ICAO for city names and local dates in the list.
    ///   - now: a fixed clock for previews; nil follows the real time.
    public init(store: PassportStore, lookup: @escaping (String) -> Airport? = { _ in nil }, now: Date? = nil) {
        self.init(store: store, lookup: lookup, now: now, scrolls: true)
    }

    init(store: PassportStore, lookup: @escaping (String) -> Airport?, now: Date?, scrolls: Bool) {
        self.store = store; self.lookup = lookup; self.fixedNow = now; self.scrolls = scrolls
    }

    /// The offline copy turns amber after a day.
    static let ttl: Duration = .seconds(86_400)

    public var body: some View {
        ClockView(fixed: fixedNow) { now in
            VStack(alignment: .leading, spacing: 0) {
                ScreenTitle("Passport")
                    .padding(.horizontal, Theme.gutter)
                    .padding(.top, 22)
                    .padding(.bottom, 10)
                if !store.years.isEmpty {
                    YearChips(years: store.years, selection: $store.year)
                        .padding(.bottom, 10)
                }
                ScreenScroll(scrolls: scrolls) { content(now: now) }
            }
        }
        .background(Theme.background)
    }

    private func content(now: Date) -> some View {
        let stats = store.stats
        let flights = store.flights
        return VStack(alignment: .leading, spacing: 12) {
            if store.isOffline {
                ErrorBanner(error: .offline, retry: reload)
                if let saved = store.lastUpdated {
                    StaleBadge(fetchedAt: saved, ttl: Self.ttl, now: now)
                }
            } else if let error = store.error {
                ErrorBanner(error: error, retry: reload)
            }
            if flights.isEmpty {
                emptyState
            } else {
                PassportCard(stats: stats, year: store.year, since: store.years.last, units: units)
                DelaysCard(stats: stats)
                if let most = stats.mostFlownAircraft {
                    AircraftCard(type: most.type, count: most.count)
                }
                PastFlightsSection(flights: flights, lookup: lookup, sort: $sort)
                    .padding(.horizontal, -16)
                    .padding(.top, 14)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 32)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Text("No past flights yet")
                .scaledFont(17, weight: .semibold)
                .foregroundStyle(Theme.secondary)
            Text("Flights you follow land here once they're done.")
                .scaledFont(15)
                .foregroundStyle(Theme.secondary.opacity(0.8))
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    private func reload() { Task { await store.load() } }
}

// MARK: - Previews

/// A Passport store from the seed history, optionally failing or offline.
struct PassportPreview: View {
    enum Mode { case full, year, sparse, empty, error, offline }
    var mode: Mode = .full
    @State private var store: PassportStore?

    var body: some View {
        Group {
            if let store {
                PassportView(store: store, lookup: PreviewData.airport, now: PreviewData.now)
            } else {
                ProgressView()
            }
        }
        .task { store = await Self.makeStore(mode) }
    }

    static func makeStore(_ mode: Mode) async -> PassportStore {
        let svc = FakeHistoryService()
        switch mode {
        case .full, .year, .sparse:
            let s = PassportStore(history: svc)
            await s.load()
            if mode == .year { s.year = 2025 }
            if mode == .sparse { s.year = s.years.last }
            return s
        case .empty:
            let s = PassportStore(history: svc, cache: EmptyPreviewCache())
            await svc.setNextError(.offline)
            await s.load()
            return s
        case .error:
            let s = PassportStore(history: svc)
            await s.load()
            await svc.setNextError(.providerUnavailable)
            await s.load()
            return s
        case .offline:
            let s = PassportStore(history: svc, cache: PreviewCache(age: 2 * 86_400))
            await svc.setNextError(.offline)
            await s.load()
            return s
        }
    }
}

#Preview("All time, dark") { PassportPreview().preferredColorScheme(.dark) }
#Preview("All time, light") { PassportPreview().preferredColorScheme(.light) }
#Preview("One year, miles") { PassportPreview(mode: .year).environment(\.units, Units(distance: .mi)).preferredColorScheme(.dark) }
#Preview("Sparse year") { PassportPreview(mode: .sparse).preferredColorScheme(.dark) }
#Preview("Empty") { PassportPreview(mode: .empty).preferredColorScheme(.dark) }
#Preview("Error, data kept") { PassportPreview(mode: .error).preferredColorScheme(.dark) }
#Preview("Offline, stale") { PassportPreview(mode: .offline).preferredColorScheme(.light) }
