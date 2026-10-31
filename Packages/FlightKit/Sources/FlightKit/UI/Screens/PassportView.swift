import SwiftUI

/// The travel record: year chips, the passport card with lifetime or yearly totals, time lost to
/// delays, the aircraft flown most, and every past flight, sortable. Each card opens its full page. The route arcs live on the
/// shell's globe, not here. Pull to refresh reloads; the shell calls `store.load()` when the tab opens.
/// Before the first load finishes it shows a spinner, and after a failed load with nothing saved only
/// the error banner with its retry. Offline it shows the age of the saved copy, online a badge once the
/// history is older than the TTL.
public struct PassportView: View {
    @Bindable var store: PassportStore
    var lookup: (String) -> Airport?
    var fixedNow: Date?
    var scrolls: Bool
    var onOpen: (FullPage) -> Void
    var onOpenFlight: ((PastFlight) -> Void)?
    var onImport: (() -> Void)?

    @State private var sort: TravelFacts.Sort = .date
    @State private var editing: EditorTarget?
    @State private var choosingFile = false
    @State private var importState: PastFlightImportState?
    @State private var deleting: PastFlight?
    @Environment(\.units) private var units

    /// The flight the editor sheet opens on: a new one, or one the traveller added.
    enum EditorTarget: Identifiable {
        case add
        case edit(PastFlight)
        var id: String {
            switch self {
            case .add: "add"
            case .edit(let f): f.id.uuidString
            }
        }
    }

    private var actions: PastFlightActions {
        PastFlightActions(add: { editing = .add }, importFile: { choosingFile = true }, importScreen: onImport,
                          edit: { editing = .edit($0) }, delete: { deleting = $0 })
    }

    /// - Parameters:
    ///   - lookup: airport by ICAO for city names and local dates in the list.
    ///   - now: a fixed clock for previews; nil follows the real time.
    ///   - onOpen: a card was tapped; the shell presents that page over the home (`HomeModel.fullPage`).
    ///   - onOpenFlight: a past flight's row was tapped: the shell opens it in the flight sheet; nil leaves rows inert.
    ///   - onImport: opens the Import screen from the add menu and the empty state; nil offers the CSV import alone.
    public init(store: PassportStore, lookup: @escaping (String) -> Airport? = { _ in nil }, now: Date? = nil,
                onOpen: @escaping (FullPage) -> Void = { _ in }, onOpenFlight: ((PastFlight) -> Void)? = nil,
                onImport: (() -> Void)? = nil) {
        self.init(store: store, lookup: lookup, now: now, scrolls: true, onOpen: onOpen, onOpenFlight: onOpenFlight,
                  onImport: onImport)
    }

    init(store: PassportStore, lookup: @escaping (String) -> Airport?, now: Date?, scrolls: Bool,
         onOpen: @escaping (FullPage) -> Void = { _ in }, onOpenFlight: ((PastFlight) -> Void)? = nil,
         onImport: (() -> Void)? = nil) {
        self.store = store; self.lookup = lookup; self.fixedNow = now; self.scrolls = scrolls; self.onOpen = onOpen
        self.onOpenFlight = onOpenFlight; self.onImport = onImport
    }

    /// The offline copy turns amber after a day.
    static let ttl: Duration = .seconds(86_400)

    public var body: some View {
        ClockView(fixed: fixedNow) { now in
            VStack(alignment: .leading, spacing: 0) {
                ScreenTitle("Passport")
                    .scaledPadding(.horizontal, Theme.gutter)
                    .scaledPadding(.top, 22)
                    .scaledPadding(.bottom, 10)
                if !store.years.isEmpty {
                    YearChips(years: store.years, selection: $store.year)
                        .scaledPadding(.bottom, 10)
                }
                ScreenScroll(scrolls: scrolls, refresh: { await store.load() }) { content(now: now) }
            }
        }
        .background(Theme.background)
        .sheet(item: $editing) { target in
            switch target {
            case .add: PastFlightEditorSheet(store: store)
            case .edit(let f): PastFlightEditorSheet(store: store, flight: f)
            }
        }
        .fileImporter(isPresented: $choosingFile, allowedContentTypes: PastFlightImportState.contentTypes) { result in
            guard case .success(let url) = result else { return }
            importState = PastFlightImportState.read(url, store: store)
        }
        .sheet(item: Binding(get: { importState.flatMap { if case .preview(let p) = $0 { p } else { nil } }.map(PreviewItem.init) },
                             set: { if $0 == nil { importState = nil } })) { item in
            PastFlightImportSheet(preview: item.preview, store: store, lookup: lookup)
        }
        .alert("Can't Import This File", isPresented: Binding(
            get: { if case .failed = importState { true } else { false } },
            set: { if !$0 { importState = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            if case .failed(let message) = importState { Text(message) }
        }
        .confirmationDialog("Delete this flight from your history?", isPresented: Binding(
            get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible,
            presenting: deleting) { f in
            Button("Delete Flight", role: .destructive) { Task { await store.delete(f.id) } }
        }
    }

    /// The import preview as a sheet item.
    private struct PreviewItem: Identifiable {
        var preview: PastFlightImport.Preview
        var id: Int { preview.hashValue }
    }

    private func content(now: Date) -> some View {
        let stats = store.stats
        let flights = store.flights
        return VStack(alignment: .leading, spacing: 12) {
            if store.isOffline {
                ErrorBanner(error: .offline, retry: reload)
                if let saved = store.fetchedAt ?? store.lastUpdated {
                    StaleBadge(fetchedAt: saved, ttl: Self.ttl, now: now)
                }
            } else {
                if let error = store.error {
                    ErrorBanner(error: error, retry: reload)
                }
                if !flights.isEmpty {
                    SectionFreshness(fetchedAt: store.fetchedAt, ttl: Self.ttl, now: now)
                }
            }
            if flights.isEmpty {
                if !store.hasLoaded {
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 200)
                        .accessibilityLabel("Loading your passport")
                } else if store.error == nil {
                    emptyState
                }
            } else {
                PassportCard(stats: stats, year: store.year, units: units) { onOpen(.passport) }
                    .fullPageSource(.passport)
                DelaysCard(stats: stats) { onOpen(.delays) }
                    .fullPageSource(.delays)
                if let most = store.aircraft.mostFlown {
                    AircraftCard(typeCode: most.icaoType, type: store.mostFlownType, airline: store.mostFlownAirline,
                                 count: Int(most.flights)) { onOpen(.aircraftStats) }
                        .fullPageSource(.aircraftStats)
                }
                PastFlightsSection(flights: flights, lookup: lookup, sort: $sort, actions: actions, onOpen: onOpenFlight)
                    .scaledPadding(.horizontal, -16)
                    .scaledPadding(.top, 14)
            }
        }
        .scaledPadding(.horizontal, 16)
        .scaledPadding(.top, 4)
        .scaledPadding(.bottom, 32)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Text("No past flights yet")
                .scaledFont(17, weight: .semibold)
                .foregroundStyle(Theme.secondary)
            Text("Flights you follow land here once they're done.")
                .scaledFont(15)
                .foregroundStyle(Theme.secondary.opacity(0.8))
            HStack(spacing: 10) {
                Chip(title: "Add Past Flight", symbol: "plus", selected: false) { editing = .add }
                if let onImport {
                    Chip(title: "Import", symbol: "square.and.arrow.down", selected: false) { onImport() }
                } else {
                    Chip(title: "Import CSV", symbol: "square.and.arrow.down", selected: false) { choosingFile = true }
                }
            }
            .scaledPadding(.top, 18)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .scaledPadding(.vertical, 60)
    }

    private func reload() { Task { await store.load() } }
}

#if DEBUG
// MARK: - Previews

/// A history with nothing in it, for the empty state.
struct EmptyHistory: HistoryService {
    func pastFlights() async throws(APIError) -> [PastFlight] { [] }
    func export(_ format: ExportFormat) async throws(APIError) -> Data { Data() }
    func add(_ flight: PastFlight) async throws(APIError) -> PastFlight { flight }
    func addAll(_ flights: [PastFlight]) async throws(APIError) -> [PastFlight] { flights }
    func update(_ flight: PastFlight) async throws(APIError) -> PastFlight { flight }
    func delete(_ id: PastFlight.ID) async throws(APIError) {}
}

/// A Passport store from the seed history, optionally failing or offline.
struct PassportPreview: View {
    enum Mode { case full, year, sparse, empty, failed, error, offline, stale, loading }
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
            let s = PassportStore(history: EmptyHistory())
            await s.load()
            return s
        case .failed:
            let s = PassportStore(history: svc, cache: EmptyPreviewCache())
            await svc.setNextError(.offline)
            await s.load()
            return s
        case .stale:
            let s = PassportStore(history: svc)
            await s.load()
            s.fetchedAt = PreviewData.now.addingTimeInterval(-2 * 86_400)
            return s
        case .loading:
            return PassportStore(history: svc)
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
#Preview("Failed, nothing saved") { PassportPreview(mode: .failed).preferredColorScheme(.dark) }
#Preview("Online, history stale") { PassportPreview(mode: .stale).preferredColorScheme(.dark) }
#Preview("Loading") { PassportPreview(mode: .loading).preferredColorScheme(.dark) }
#Preview("Error, data kept") { PassportPreview(mode: .error).preferredColorScheme(.dark) }
#Preview("Offline, stale") { PassportPreview(mode: .offline).preferredColorScheme(.light) }
#endif
