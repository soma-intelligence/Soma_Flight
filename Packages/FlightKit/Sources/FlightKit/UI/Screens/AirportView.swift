import SwiftUI

/// The airport sheet: header, issues card on bad days, departure and arrival performance with
/// delay trends, weather, the day's totals, the most disrupted routes and airlines, traffic
/// numbers, then the departures and arrivals boards. The sheet shell supplies the close button.
public struct AirportView: View {
    var store: AirportStore
    var lookup: (String) -> Airport?
    var fixedNow: Date?
    var scrolls: Bool
    var rowLimit: Int?

    /// - Parameters:
    ///   - lookup: airport by ICAO for the far ends (city names on the boards, countries served).
    ///   - now: a fixed clock for previews; nil follows the real time, refreshed each minute.
    public init(store: AirportStore, lookup: @escaping (String) -> Airport? = { _ in nil }, now: Date? = nil) {
        self.init(store: store, lookup: lookup, now: now, scrolls: true, rowLimit: nil)
    }

    /// `scrolls: false` lays everything out in one tall stack (snapshots); `rowLimit` caps board rows.
    init(store: AirportStore, lookup: @escaping (String) -> Airport?, now: Date?, scrolls: Bool, rowLimit: Int?) {
        self.store = store; self.lookup = lookup; self.fixedNow = now
        self.scrolls = scrolls; self.rowLimit = rowLimit
    }

    public var body: some View {
        Group {
            if let fixedNow {
                page(now: fixedNow)
            } else {
                TimelineView(.everyMinute) { page(now: $0.date) }
            }
        }
        .background(Theme.background)
    }

    private func page(now: Date) -> some View {
        VStack(spacing: 0) {
            AirportHeader(airport: store.airport, code: store.airport?.id ?? "", now: now)
                .scaledPadding(.horizontal, Theme.gutter)
                .scaledPadding(.top, 18)
                .scaledPadding(.bottom, 12)
            Rectangle().fill(Theme.separator).frame(height: 1)
            if scrolls {
                ScrollView { sections(now: now) }
            } else {
                sections(now: now)
            }
        }
    }

    private func sections(now: Date) -> some View {
        AirportSections(store: store, lookup: lookup, now: now, rowLimit: rowLimit, lazy: scrolls)
    }
}

/// Everything under the pinned header.
struct AirportSections: View {
    var store: AirportStore
    var lookup: (String) -> Airport?
    var now: Date
    var rowLimit: Int?
    /// LazyVStack root and board rows when scrolling; plain stacks for the snapshot render.
    var lazy = true

    @State private var scope: DailyScope = .departures
    @State private var totalsCache: (key: TotalsKey, stats: DelayStats)?
    @State private var showingReport = false

    /// What the Totals segment depends on, so the core runs once per board refresh.
    struct TotalsKey: Hashable {
        var departures: Date?, arrivals: Date?
        var depCount: Int, arrCount: Int
    }

    private var totalsKey: TotalsKey {
        TotalsKey(departures: store.departures?.fetchedAt, arrivals: store.arrivals?.fetchedAt,
                  depCount: store.departures?.flights.count ?? 0, arrCount: store.arrivals?.flights.count ?? 0)
    }

    private func computeTotals() -> DelayStats {
        let dep = (store.departures?.flights ?? []).map { ($0, BoardKind.departures) }
        let arr = (store.arrivals?.flights ?? []).map { ($0, BoardKind.arrivals) }
        return DelayStats.compute(dep + arr)
    }

    private var tz: TimeZone { store.airport?.timeZone ?? .current }
    private var code: String { store.airport?.iata ?? store.airport?.id ?? "" }

    var body: some View {
        MaybeLazyVStack(lazy: lazy) {
            if let error = store.error {
                ErrorBanner(error: error, retry: { Task { await store.load() } })
                    .scaledPadding(.horizontal, 16).scaledPadding(.top, 16)
            }
            if let stats = store.stats {
                let severity = AirportFacts.worst(stats.departures.severity, stats.arrivals.severity)
                if severity != .normal {
                    IssuesCard(severity: severity, departures: stats.departures, arrivals: stats.arrivals, weather: store.weather)
                        .scaledPadding(.horizontal, 16).scaledPadding(.top, 16)
                }
            }
            if store.stats != nil || store.weather != nil {
                OperationsReportRow(impact: store.weather.map(WeatherImpact.of)) { showingReport = true }
                    .scaledPadding(.horizontal, 16).scaledPadding(.top, 16)
            }
            if let stats = store.stats {
                performance(.departures, stats.departures)
                performance(.arrivals, stats.arrivals)
            }
            if let weather = store.weather {
                section {
                    SectionHeader("Current Weather", subtitle: "Latest METAR from \(code)", large: true)
                        .scaledPadding(.bottom, 10)
                    freshness(.weather, AirportFacts.weatherTTL, bottom: 12)
                    WeatherBlock(weather: weather, timeZone: tz, now: now)
                }
            }
            if store.stats != nil { daily }
            if let dep = store.departures?.flights, let arr = store.arrivals?.flights {
                section {
                    SectionHeader("Airport Stats", subtitle: "Today in numbers", large: true)
                        .scaledPadding(.bottom, 18)
                    AirportCountsGrid(counts: AirportFacts.counts(departures: dep, arrivals: arr, lookup: lookup))
                }
            }
            if store.departures != nil || store.arrivals != nil {
                BoardSection(departures: store.departures, arrivals: store.arrivals, timeZone: tz, now: now,
                             lookup: lookup, fetchedAt: store.fetchedAt, rowLimit: rowLimit, lazy: lazy)
                .scaledPadding(.top, 24)
                .scaledPadding(.bottom, 40)
            }
            if store.airport == nil && store.stats == nil && store.departures == nil && store.error == nil {
                ProgressView().frame(maxWidth: .infinity).scaledPadding(.vertical, 60)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: TotalsTrigger(key: totalsKey, scope: scope), initial: true) {
            if scope == .totals, totalsCache?.key != totalsKey { totalsCache = (totalsKey, computeTotals()) }
        }
        .sheet(isPresented: $showingReport) {
            OperationsReportView(store: store, onClose: { showingReport = false })
                #if os(macOS)
                .frame(minWidth: 460, minHeight: 640)
                #endif
        }
    }

    private struct TotalsTrigger: Equatable { var key: TotalsKey; var scope: DailyScope }

    // MARK: Sections

    private func performance(_ kind: BoardKind, _ stats: DelayStats) -> some View {
        let dep = kind == .departures
        let flights = (dep ? store.departures : store.arrivals)?.flights ?? []
        let window = flights.filter {
            guard let s = AirportFacts.scheduled($0, kind) else { return false }
            return s >= now.addingTimeInterval(-4 * 3600) && s < now.addingTimeInterval(4 * 3600)
        }
        return section {
            SectionHeader(dep ? "Departure Performance" : "Arrival Performance", subtitle: "Today so far and the hours ahead")
            freshness(.stats, AirportFacts.boardTTL, top: 8)
            PerformanceSplit(stats: stats)
                .scaledPadding(.top, 12)
            SectionHeader(dep ? "Departure Delay Trend" : "Arrival Delay Trend",
                          subtitle: "Average gate delay, actual then estimated", info: true)
                .scaledPadding(.top, 22)
            if !window.isEmpty {
                DelayTrendChart(flights: window, kind: kind, timeZone: tz, now: now, binMinutes: 20, windowMinutes: 60)
                    .scaledPadding(.top, 6)
            }
        }
    }

    private var daily: some View {
        let stats = dailyStats
        return section {
            SectionHeader("Daily Performance", subtitle: "The whole day, flown and planned", large: true)
                .scaledPadding(.bottom, 14)
            freshness(.stats, AirportFacts.boardTTL, bottom: 12)
            HStack {
                PillPicker(options: [(DailyScope.departures, "Departures"), (.arrivals, "Arrivals"), (.totals, "Totals")],
                           selection: $scope)
                Spacer()
                FilterPill(icon: nil, title: "Today", options: [(0, "Today")], selection: .constant(0))
            }
            .scaledPadding(.bottom, 14)
            DailyPerformanceCard(stats: stats, scope: scope, day: now, timeZone: tz)
            Text("Most disrupted routes")
                .themeFont(.sectionTitle).foregroundStyle(Theme.primary)
                .scaledPadding(.top, 26).scaledPadding(.bottom, 8)
            DisruptionBars(items: stats.worstRoutes.map {
                .init(id: $0.icao, code: lookup($0.icao)?.iata ?? $0.icao, caption: lookup($0.icao)?.city,
                      delayed: $0.delayed, canceled: $0.canceled)
            })
            Text("Most disrupted airlines")
                .themeFont(.sectionTitle).foregroundStyle(Theme.primary)
                .scaledPadding(.top, 22).scaledPadding(.bottom, 8)
            DisruptionBars(items: stats.worstAirlines.map {
                .init(id: $0.operator, code: AirportFacts.airlineCode($0.operator), caption: nil,
                      delayed: $0.delayed, canceled: $0.canceled)
            })
        }
    }

    private var dailyStats: DelayStats {
        guard let stats = store.stats else { return DelayStats.compute([]) }
        switch scope {
        case .departures: return stats.departures
        case .arrivals: return stats.arrivals
        case .totals:
            return totalsCache?.key == totalsKey ? totalsCache!.stats : computeTotals()
        }
    }

    // MARK: Pieces

    private func freshness(_ part: BoardKind, _ ttl: Duration, top: CGFloat = 0, bottom: CGFloat = 0) -> some View {
        SectionFreshness(fetchedAt: store.fetchedAt[part], ttl: ttl, now: now, top: top, bottom: bottom)
    }

    private func section<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 0) { content() }
            .scaledPadding(.horizontal, Theme.gutter)
            .scaledPadding(.vertical, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.separator).frame(height: 1) }
    }
}

#if DEBUG
// MARK: - Previews

#Preview("Austin, dark") {
    AirportPreview(code: "KAUS")
        .preferredColorScheme(.dark)
}

#Preview("San Francisco, light") {
    AirportPreview(code: "KSFO")
        .preferredColorScheme(.light)
}

#Preview("Error, data kept") {
    AirportPreview(code: "KAUS", failSecondLoad: .providerUnavailable)
        .preferredColorScheme(.dark)
}

#Preview("Stale") {
    AirportPreview(code: "KAUS", age: 40 * 60)
        .preferredColorScheme(.dark)
}

/// Loads a store from the seed at the seed's own clock, optionally failing a reload or ageing the data.
struct AirportPreview: View {
    var code: String
    var failSecondLoad: APIError?
    /// Seconds added to the clock after loading, so every section is that much older.
    var age: TimeInterval = 0
    @State private var store: AirportStore?

    var body: some View {
        Group {
            if let store {
                AirportView(store: store, lookup: PreviewData.airport, now: PreviewData.now.addingTimeInterval(age))
            } else {
                ProgressView()
            }
        }
        .task {
            let svc = FakeAirportService(now: PreviewData.now)
            let s = AirportStore(code: code, airports: svc)
            await s.load()
            if let failSecondLoad {
                await svc.setNextError(failSecondLoad)
                await s.load()
            }
            store = s
        }
    }
}
#endif
