import SwiftUI

/// The airport sheet: header, issues card on bad days, departure and arrival performance with
/// delay trends, weather, security waits (US airports), the day's totals, the most disrupted routes and airlines, traffic
/// numbers, Runway Regulars, the user's history here, then the departures and arrivals boards, with a bottom
/// bar (boards, favourite, more, share). The sheet shell supplies the close button.
public struct AirportView: View {
    var store: AirportStore
    var lookup: (String) -> Airport?
    var fixedNow: Date?
    var scrolls: Bool
    var rowLimit: Int?
    var favorites: AirportFavorites?
    var pastFlights: [PastFlight]
    @State private var boardRequest: BoardRequest?
    @State private var shareImage: Image?
    @Environment(\.colorScheme) private var scheme
    @Environment(\.displayScale) private var displayScale

    /// - Parameters:
    ///   - lookup: airport by ICAO for the far ends (city names on the boards, countries served).
    ///   - now: a fixed clock for previews; nil follows the real time, refreshed each minute.
    ///   - favorites: the favourite airports the bar's star toggles; nil hides the bar.
    ///   - pastFlights: the user's Passport, for "Your History Here".
    public init(store: AirportStore, lookup: @escaping (String) -> Airport? = { _ in nil }, now: Date? = nil,
                favorites: AirportFavorites? = nil, pastFlights: [PastFlight] = []) {
        self.init(store: store, lookup: lookup, now: now, scrolls: true, rowLimit: nil, favorites: favorites,
                  pastFlights: pastFlights)
    }

    /// `scrolls: false` lays everything out in one tall stack (snapshots); `rowLimit` caps board rows.
    init(store: AirportStore, lookup: @escaping (String) -> Airport?, now: Date?, scrolls: Bool, rowLimit: Int?,
         favorites: AirportFavorites? = nil, pastFlights: [PastFlight] = []) {
        self.store = store; self.lookup = lookup; self.fixedNow = now
        self.scrolls = scrolls; self.rowLimit = rowLimit
        self.favorites = favorites; self.pastFlights = pastFlights
    }

    static let boardAnchor = "airport-board"

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
                ScrollViewReader { proxy in
                    ScrollView { sections(now: now) }
                        .safeAreaInset(edge: .bottom) { bar(proxy) }
                }
            } else {
                sections(now: now)
            }
        }
        .onChange(of: ShareKey(airport: store.airport?.id, status: store.status, scheme: scheme), initial: true) {
            renderShare()
        }
    }

    private func sections(now: Date) -> some View {
        AirportSections(store: store, lookup: lookup, now: now, rowLimit: rowLimit, lazy: scrolls,
                        history: store.airport.flatMap { AirportHistory.of(pastFlights, icao: $0.id) },
                        boardRequest: boardRequest)
    }

    @ViewBuilder private func bar(_ proxy: ScrollViewProxy) -> some View {
        if let favorites, let airport = store.airport {
            AirportBottomBar(isFavorite: favorites.contains(airport.id),
                             hasBoards: store.departures != nil || store.arrivals != nil,
                             shareImage: shareImage, shareTitle: airport.name,
                             onDepartures: { show(.departures, proxy) }, onArrivals: { show(.arrivals, proxy) },
                             onFavorite: { withAnimation(.snappy) { favorites.toggle(airport.id) } },
                             copyCode: airport.iata ?? airport.id)
                .scaledPadding(.bottom, 4)
        }
    }

    private func show(_ kind: BoardKind, _ proxy: ScrollViewProxy) {
        boardRequest = BoardRequest(kind: kind, id: (boardRequest?.id ?? 0) + 1)
        withAnimation(.snappy) { proxy.scrollTo(Self.boardAnchor, anchor: .top) }
    }

    private struct ShareKey: Equatable { var airport: String?; var status: AirportStatus; var scheme: ColorScheme }

    /// The share picture, rendered again when the airport or its status changes.
    private func renderShare() {
        guard favorites != nil, let airport = store.airport else { return }
        let card = AirportShareCard(airport: airport, status: store.status, weather: store.overview?.weather)
            .environment(\.colorScheme, scheme)
        let renderer = ImageRenderer(content: card)
        renderer.scale = max(displayScale, 2)
        shareImage = renderer.cgImage.map { Image(decorative: $0, scale: renderer.scale) }
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
    var history: AirportHistory?
    var boardRequest: BoardRequest?

    @State private var scope: DailyScope = .departures
    @State private var totalsCache: (key: TotalsKey, stats: DelayStats)?
    @State private var showingReport = false
    @Environment(\.units) private var units

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
            let faa = FAAFacts.airportRows(programs: store.programs, notams: store.notams, code: code, timeZone: tz,
                                           clock: units.clock, now: now, includeWeatherNow: store.stats == nil)
            let severity = FAAFacts.issuesSeverity(stats: store.stats, rows: faa)
            if severity != .normal {
                IssuesCard(severity: severity, departures: store.stats?.departures, arrivals: store.stats?.arrivals,
                           weather: store.weather, programs: faa)
                    .scaledPadding(.horizontal, 16).scaledPadding(.top, 16)
            } else if store.overview != nil || store.liveStats?.available == true {
                AirportStatusCard(status: store.status, live: store.liveStats, weather: store.overview?.weather)
                    .scaledPadding(.horizontal, 16).scaledPadding(.top, 16)
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
            AirportBriefSection(store: store)
            if let security = store.security {
                section { AirportSecuritySection(wait: security, timeZone: tz) }
            }
            if store.stats != nil { daily }
            if store.liveStats?.today != nil || store.liveStats?.next7Days != nil {
                section {
                    LiveTrafficSection(today: store.liveStats?.today, week: store.liveStats?.next7Days, lookup: lookup)
                }
            } else if let dep = store.departures?.flights, let arr = store.arrivals?.flights {
                section {
                    SectionHeader("Airport Stats", subtitle: "Today in numbers", large: true)
                        .scaledPadding(.bottom, 18)
                    AirportCountsGrid(counts: AirportFacts.counts(departures: dep, arrivals: arr, lookup: lookup))
                }
            }
            if !store.regulars.isEmpty {
                section { RunwayRegularsSection(regulars: store.regulars, code: code) }
            }
            if let history {
                section { AirportHistorySection(history: history, code: code, lookup: lookup) }
            }
            if store.departures != nil || store.arrivals != nil {
                BoardSection(departures: store.departures, arrivals: store.arrivals, timeZone: tz, now: now,
                             lookup: lookup, fetchedAt: store.fetchedAt, rowLimit: rowLimit, lazy: lazy,
                             request: boardRequest)
                .id(AirportView.boardAnchor)
                .scaledPadding(.top, 24)
                .scaledPadding(.bottom, 40)
            }
            if !store.hasLoaded && store.airport == nil && store.error == nil {
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
            } else if let trend = (dep ? store.liveStats?.departures : store.liveStats?.arrivals)?.trend, !trend.isEmpty {
                LiveTrendChart(trend: trend, timeZone: tz, now: now)
                    .scaledPadding(.top, 24)
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
        SectionFreshness(fetchedAt: store.fetchedAt[part], ttl: ttl, now: now) { await store.load() }
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
            let s = AirportStore(code: code, airports: svc, security: FakeSecurityWaitService(now: PreviewData.now),
                                 faa: FakeFAAService(now: PreviewData.now))
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
