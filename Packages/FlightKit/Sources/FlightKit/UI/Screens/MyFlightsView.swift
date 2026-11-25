import SwiftUI
import TipKit

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
    var onImport: (() -> Void)?
    var onUnfollow: ((Flight) -> Void)?
    @Environment(\.reference) private var reference
    @Environment(\.connectivity) private var connectivity
    @Environment(\.sheetDetentActions) private var detentActions
    @Environment(\.requestSignIn) private var requestSignIn
    /// The planned flight whose options are up (I9): a tap, the swipe or the menu asks before removing it.
    @State private var plannedToRemove: UpcomingFlight?

    /// - Parameters:
    ///   - onSearch: opens the search sheet from the empty state; nil hides the button.
    ///   - lookup: airport by ICAO, for city names and local times on the rows.
    ///   - now: a fixed clock for previews; nil follows the real time.
    ///   - planned: flights added ahead of time and not followed yet (the follow-later queue), listed in
    ///     Upcoming with a "PLANNED" row; they have no detail screen, so tapping one does nothing.
    ///   - onRemovePlanned: deletes a planned flight by its id (swipe or the long-press menu).
    ///   - onImport: opens Import from the empty state's second button; nil leaves the button out.
    ///   - onUnfollow: stops following a flight from the swipe or the menu. Shells pass
    ///     `HomeModel.unfollowWithUndo`, which hides the row at once and offers Undo (I1, E15); nil asks the
    ///     store straight away.
    public init(store: MyFlightsStore, onSelect: @escaping (Flight) -> Void, onSearch: (() -> Void)? = nil,
                lookup: @escaping (String) -> Airport? = { _ in nil }, now: Date? = nil,
                planned: [UpcomingFlight] = [], onRemovePlanned: @escaping (UpcomingFlight.ID) -> Void = { _ in },
                onImport: (() -> Void)? = nil, onUnfollow: ((Flight) -> Void)? = nil) {
        self.init(store: store, onSelect: onSelect, onSearch: onSearch, lookup: lookup, now: now, scrolls: true,
                  planned: planned, onRemovePlanned: onRemovePlanned, onImport: onImport, onUnfollow: onUnfollow)
    }

    init(store: MyFlightsStore, onSelect: @escaping (Flight) -> Void, onSearch: (() -> Void)?,
         lookup: @escaping (String) -> Airport?, now: Date?, scrolls: Bool,
         planned: [UpcomingFlight] = [], onRemovePlanned: @escaping (UpcomingFlight.ID) -> Void = { _ in },
         onImport: (() -> Void)? = nil, onUnfollow: ((Flight) -> Void)? = nil) {
        self.store = store; self.onSelect = onSelect; self.onSearch = onSearch
        self.lookup = lookup; self.fixedNow = now; self.scrolls = scrolls
        self.planned = planned; self.onRemovePlanned = onRemovePlanned; self.onImport = onImport
        self.onUnfollow = onUnfollow
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
                header
                ScreenScroll(scrolls: scrolls, refresh: { await store.load() }) { content(now: now) }
            }
        }
        .background(Theme.background)
        .confirmDestructive(item: $plannedToRemove, title: Self.removePlannedTitle,
                            message: { Self.removePlannedMessage($0) }, actionTitle: Self.removePlannedAction) {
            deletePlanned($0)
        }
    }

    /// The planned flight's removal (I9). A planned flight lives only on this device, so its removal cannot
    /// be undone: it asks first (`.confirmDestructive`).
    static let removePlannedTitle = "Remove this planned flight?"
    static let removePlannedAction = "Remove Planned Flight"
    static func removePlannedMessage(_ u: UpcomingFlight) -> String {
        let ident = Format.ident(u.ident), day = PlannedFlight.day(u)
        return String(localized: "\(ident) on \(day) leaves My Flights. This can't be undone.", bundle: .main)
    }

    /// The menu's and the swipe's word for a followed flight (D3): following can be undone, so it is
    /// "Stop Following", never "Delete".
    static let stopFollowing = "Stop Following"
    static func stopFollowingLabel(_ f: Flight) -> String {
        let ident = Format.ident(f.ident)
        return String(localized: "Stop Following \(ident)", bundle: .main)
    }

    /// No connection, by the store (its last load failed offline) or by the system's path monitor.
    private var isOffline: Bool { store.isOffline || connectivity?.isOnline == false }

    /// The root header (R5): the large title, the shell's profile button overlaid on its right (a clear
    /// 44 pt slot keeps the room). VoiceOver's "Expand" and "Collapse" on it move the sheet a detent.
    private var header: some View {
        SheetHeader.root("My Flights") {
            ShellAvatarSlot()
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
        .accessibilityActions {
            if let expand = detentActions?.expand { Button("Expand", action: expand) }
            if let collapse = detentActions?.collapse { Button("Collapse", action: collapse) }
        }
        .scaledPadding(.top, SheetHeader.rootTop)
        .scaledPadding(.bottom, SheetHeader.rootBottom)
    }

    /// The groups in order: in the air, upcoming (followed and planned flights together, by departure),
    /// then recent. Empty groups are left out, so planned flights alone keep the empty state away. A planned
    /// flight that is also followed (same number, same day at the origin) shows once, as the followed one.
    /// Given `now`, a flight that is over (`LandedFlights.isOver`) is left out, Passport shows it, and so is
    /// a planned flight whose day passed more than a day ago without being followed (the next load drops it
    /// from the queue).
    static func groups(live: [Flight], upcoming: [Flight], planned: [UpcomingFlight],
                       lookup: (String) -> Airport?,
                       reference: ReferenceData = .bundled(), now: Date? = nil) -> [(title: String, rows: [Row])] {
        let upcoming = now.map { t in upcoming.filter { !LandedFlights.isOver($0, now: t) } } ?? upcoming
        let all = live + upcoming
        let planned = planned.filter { u in
            (now.map { ImportFollower.daysAhead(u, now: $0, zone: .current) >= -1 } ?? true)
                && !all.contains { PlannedFlight.matches(u, $0, reference: reference, airport: lookup) }
        }
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

    private func groups(now: Date) -> [(title: String, rows: [Row])] {
        Self.groups(live: store.live, upcoming: store.upcoming, planned: planned, lookup: lookup,
                    reference: reference, now: now)
    }

    @ViewBuilder private func content(now: Date) -> some View {
        let groups = self.groups(now: now)
        VStack(alignment: .leading, spacing: 0) {
            // Offline is not an error here: the saved list keeps working, so only a small pill says so, with
            // the list's age (R8, E2). With nothing saved the calm banner explains the empty list instead (E8).
            if isOffline {
                if groups.isEmpty {
                    OfflineBanner(OfflineBanner.text(hasContent: false), retry: reload)
                        .scaledPadding(.bottom, 10)
                } else {
                    OfflineBanner.Pill(retry: reload, fetchedAt: store.fetchedAt, now: fixedNow)
                        .scaledPadding(.bottom, 14)
                }
            } else {
                if let error = store.error {
                    ErrorBanner(error: error, hasContent: !groups.isEmpty, retry: reload, signIn: signIn)
                        .scaledPadding(.bottom, 14)
                } else if let fetchedAt = store.fetchedAt, !groups.isEmpty, !store.isLiveSynced {
                    // The saved copy while the network answers, or a list past its TTL (E1, E2).
                    StaleBadge(fetchedAt: fetchedAt, ttl: Self.ttl, now: fixedNow,
                               hidesWhileFresh: !store.isShowingCache)
                        .scaledPadding(.bottom, 12)
                }
            }
            // A failed action (a removal from the flight sheet) with its own Retry, apart from the load (E6).
            if let failure = store.actionError {
                ErrorBanner(error: failure.error, hasContent: !groups.isEmpty,
                            retry: { Task { await failure.retry() } }, signIn: signIn)
                    .scaledPadding(.bottom, 14)
            }
            // A live subscription that is healthy keeps the list current even when nothing changes. Offline
            // too, so the list reloads by itself once it is stale and the connection is back (E2).
            if !groups.isEmpty, !store.isLiveSynced {
                SectionFreshness(fetchedAt: store.fetchedAt, ttl: Self.ttl, now: now) { await store.load() }
            }
            if groups.isEmpty {
                if (!store.hasLoaded && !store.isShowingCache) || (store.error != nil && store.isLoading) {
                    // First load with nothing saved, or a retry after a failed one.
                    LoadingBoard(label: "Loading your flights")
                } else if store.error == nil {
                    HomeEmptyFlights(onAdd: onSearch, onImport: onImport)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 200)
                }
            } else {
                #if os(iOS)
                TipView(AskSiriTip())
                    .tipBackground(Theme.card)
                    .scaledPadding(.bottom, 14)
                #endif
                ForEach(groups, id: \.title) { group in
                    CapsHeader(group.title, trailing: group.rows.count == 1 ? "1 flight" : String(localized: "\(group.rows.count) flights", bundle: .main))
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
                        destination: lookup(flight.destinationIcao), airline: airline(flight), now: now,
                        estimated: isOffline)
        }
        .buttonStyle(.plain)
        .swipeToDelete(Self.stopFollowingLabel(flight)) { unfollow(flight) }
        .contextMenu {
            Button(role: .destructive) { unfollow(flight) } label: {
                Label { Text(ui: Self.stopFollowing) } icon: { Image(systemName: "minus.circle") }
            }
        }
        .accessibilityAction(named: Text(ui: Self.stopFollowing)) { unfollow(flight) }
    }

    /// Stops following: through the home's undoable removal when the shell gives one (I1), else the store.
    private func unfollow(_ flight: Flight) {
        if let onUnfollow { onUnfollow(flight) } else { Task { await store.unfollow(flight) } }
    }

    /// A planned flight has no detail screen: a tap opens its options, which remove it after a confirmation
    /// (I9), as the swipe and the long-press menu do. A small "…" on the row says it can be tapped.
    private func plannedRow(_ flight: UpcomingFlight, now: Date) -> some View {
        Button { plannedToRemove = flight } label: {
            PlannedFlightRow(flight: flight, origin: flight.origin.flatMap(lookup),
                             destination: flight.destination.flatMap(lookup),
                             airline: reference.airline(ident: flight.ident), now: now)
        }
        .buttonStyle(.plain)
        .accessibilityHint(Text(ui: "Shows the options for this planned flight"))
        .swipeToDelete(UIText.localized(Self.removePlannedAction)) { plannedToRemove = flight }
        .contextMenu {
            Button(role: .destructive) { plannedToRemove = flight } label: {
                Label { Text(ui: Self.removePlannedAction) } icon: { Image(systemName: "trash") }
            }
        }
    }

    /// What the confirmation's Remove Planned Flight does.
    func deletePlanned(_ flight: UpcomingFlight) { onRemovePlanned(flight.id) }

    private func reload() { Task { await store.load() } }

    /// The banners' Sign In: the sign-in sheet over the home (E3), when the shell gives one.
    private var signIn: (() -> Void)? { requestSignIn.map { open in { open() } } }

    private func airline(_ f: Flight) -> Airline? {
        f.operator.flatMap { reference.airline($0) } ?? reference.airline(ident: f.ident)
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
