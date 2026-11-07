import SwiftUI

/// The flights the user already follows, as search results meet them. A flight lookup answers
/// `flights` rows (same `id`), but an airport search answers board rows whose `id` is derived from the
/// provider id, so a row also counts as followed when its `providerId` matches.
public struct FollowedFlights: Sendable, Equatable {
    public var ids: Set<Flight.ID>
    public var providerIDs: Set<String>

    public init(_ flights: [Flight] = []) {
        ids = Set(flights.map(\.id))
        providerIDs = Set(flights.map(\.providerId))
    }

    public func contains(_ f: Flight) -> Bool {
        ids.contains(f.id) || providerIDs.contains(f.providerId)
    }
}

/// Find a flight to follow: one field at the very top, focused on open, for a flight number, a route or
/// an airport in any words ("Paris New York 12 dec", "AF 84 demain", "air france 84"). Under it, chips
/// show what the text reads as, each removable. Empty, it offers the frequently used airlines and
/// airports, the recent searches and Import; while typing, after a short pause on something searchable,
/// its results come first, right under the field (live flights to follow now, planned ones weeks ahead
/// to add for later, each with an Add button and opening its flight on a tap), then the ranked
/// suggestions on the device (`SearchSuggester`). Return picks the top suggestion. Errors show in a
/// banner and the typed text stays.
public struct SearchView: View {
    @Bindable var store: SearchStore
    var onFollowed: (Flight) -> Void
    var lookup: (String) -> Airport?
    var alreadyFollowed: FollowedFlights
    var frequent: [FrequentItem]
    var scrolls: Bool
    var onImport: (() -> Void)?
    var onAirport: ((String) -> Void)?
    var known: [KnownFlight]
    var onPlan: (UpcomingFlight) -> Void
    var planned: Set<UpcomingFlight.ID>
    var onOpen: ((Flight) -> Void)?
    var onClose: (() -> Void)?

    @State private var followed: Set<Flight.ID> = []
    /// Planned flights added from this screen, before `planned` hears of them.
    @State private var plannedHere: Set<UpcomingFlight.ID> = []
    @State private var pending: Set<Flight.ID> = []
    @FocusState private var focused: Bool
    @Environment(\.airportStaticControls) private var staticControls
    @Environment(\.units) private var units

    /// - Parameters:
    ///   - lookup: airport by ICAO or IATA, for city names and local times in the results.
    ///   - alreadyFollowed: flights already followed, which show "Added" instead of a second Add.
    ///   - frequent: the airlines and airports offered before anything is typed (`HomeModel.frequent`).
    ///   - onImport: opens the Import screen from the "More" rows; nil leaves the row out.
    ///   - onAirport: opens an airport's board (ICAO) from "Flights from ... today"; nil leaves those rows inert.
    ///   - known: the followed and past flights flight numbers are suggested from.
    ///   - onPlan: keeps a planned flight to follow once it is within reach (`FollowLaterQueue.add`).
    ///   - planned: the flights already kept that way, which show "Added".
    ///   - onOpen: opens a live result's flight when its row is tapped; nil leaves rows to their Add button.
    ///   - onClose: draws a close button beside the field; nil leaves it to the container.
    public init(store: SearchStore, onFollowed: @escaping (Flight) -> Void,
                lookup: @escaping (String) -> Airport? = { _ in nil }, alreadyFollowed: FollowedFlights = .init(),
                frequent: [FrequentItem] = [], onImport: (() -> Void)? = nil,
                onAirport: ((String) -> Void)? = nil, known: [KnownFlight] = [],
                onPlan: @escaping (UpcomingFlight) -> Void = { _ in }, planned: Set<UpcomingFlight.ID> = [],
                onOpen: ((Flight) -> Void)? = nil, onClose: (() -> Void)? = nil) {
        self.init(store: store, onFollowed: onFollowed, lookup: lookup, alreadyFollowed: alreadyFollowed,
                  frequent: frequent, scrolls: true, onImport: onImport, onAirport: onAirport, known: known,
                  onPlan: onPlan, planned: planned, onOpen: onOpen, onClose: onClose)
    }

    init(store: SearchStore, onFollowed: @escaping (Flight) -> Void, lookup: @escaping (String) -> Airport?,
         alreadyFollowed: FollowedFlights = .init(), frequent: [FrequentItem] = [], scrolls: Bool,
         onImport: (() -> Void)? = nil, onAirport: ((String) -> Void)? = nil, known: [KnownFlight] = [],
         onPlan: @escaping (UpcomingFlight) -> Void = { _ in }, planned: Set<UpcomingFlight.ID> = [],
         onOpen: ((Flight) -> Void)? = nil, onClose: (() -> Void)? = nil) {
        self.store = store; self.onFollowed = onFollowed; self.lookup = lookup
        self.alreadyFollowed = alreadyFollowed; self.frequent = frequent; self.scrolls = scrolls
        self.onImport = onImport; self.onAirport = onAirport; self.known = known
        self.onPlan = onPlan; self.planned = planned; self.onOpen = onOpen; self.onClose = onClose
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The field is the top of the screen: no title over it, the close button beside it.
            HStack(spacing: 10) {
                field
                if let onClose { RoundButton(systemImage: "xmark", label: "Close", action: onClose) }
            }
            .scaledPadding(.horizontal, 16)
            .scaledPadding(.top, 14)
            .scaledPadding(.bottom, 8)
            understood
            ScreenScroll(scrolls: scrolls) { content }
        }
        .background(Theme.background)
        .onAppear {
            store.known = known
            // The keyboard is up on open: typing is the only thing this screen asks.
            if !staticControls { focused = true }
        }
        .onChange(of: known) { _, k in store.known = k }
        .onChange(of: store.text) { store.textChanged() }
        .onChange(of: store.suggestions) { _, s in
            guard !isBlank else { return }
            AccessibilityNotification.Announcement(SearchSuggestionRow.announcement(count: s.count)).post()
        }
    }

    private var isBlank: Bool { store.text.trimmingCharacters(in: .whitespaces).isEmpty }

    private var showsChips: Bool { !isBlank && (!store.intent.chips.isEmpty || store.note != nil) }

    /// What the text reads as, under the field; it fades in and out on its own.
    private var understood: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsChips {
                SearchChipsRow(chips: store.intent.chips, note: store.note) { Self.remove($0, from: store) }
                    .scaledPadding(.horizontal, 16)
                    .scaledPadding(.bottom, 8)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: showsChips)
    }

    /// Takes the chip's words out of the field and reads the rest again.
    static func remove(_ chip: SearchIntent.Chip, from store: SearchStore) {
        store.text = store.intent.removing(chip, from: store.text)
        store.textChanged()
    }

    // MARK: Field

    private var field: some View {
        HStack(spacing: 8) {
            if staticControls {
                // ImageRenderer cannot draw a text field; snapshots get its text.
                Text(store.text.isEmpty ? Self.prompt : store.text)
                    .scaledFont(17)
                    .foregroundStyle(store.text.isEmpty ? Theme.secondary.opacity(0.75) : Theme.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                input
            }
            if store.isSearching {
                ProgressView().controlSize(.small)
            } else if !store.text.isEmpty {
                Button { store.text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear")
            }
        }
        .scaledPadding(.horizontal, 14)
        .frame(minHeight: 44)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.pill))
    }

    /// Fits the field beside the close button on an iPhone SE (375 pt) at the default text size.
    static let prompt = "AF 84 tomorrow, or Paris Rome"

    private var input: some View {
        TextField("", text: $store.text, prompt: Text(ui: Self.prompt).foregroundStyle(Theme.secondary.opacity(0.75)))
            .scaledFont(17)
            .foregroundStyle(Theme.primary)
            .textFieldStyle(.plain)
            .autocorrectionDisabled()
            #if os(iOS)
            .textInputAutocapitalization(.never)
            .submitLabel(.search)
            #endif
            .focused($focused)
            .onSubmit { handle(store.submit()) }
    }

    private func run() {
        Task { await store.search() }
    }

    /// A picked row or return: an airport's board opens; otherwise the field keeps the keyboard.
    private func handle(_ pick: SearchPick) {
        switch pick {
        case .openAirport(let code): onAirport?(code)
        case .filled: focused = true
        case .searching: break
        }
    }

    // MARK: Content

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let error = store.error {
                ErrorBanner(error: error, retry: retryAction(error))
                    .scaledPadding(.horizontal, 16)
                    .scaledPadding(.vertical, 8)
            }
            if isBlank {
                if store.items.isEmpty { suggestions } else { results }
            } else {
                typing
            }
        }
        .scaledPadding(.bottom, 24)
    }

    /// While typing: the live (or returned) results first, right under the field, then the suggestions
    /// they do not already show.
    @ViewBuilder private var typing: some View {
        let shown = Self.typingSuggestions(store.suggestions, results: store.items)
        if !store.items.isEmpty { results }
        SearchSuggestionList(suggestions: shown, lookup: lookup) { handle(store.pick($0)) }
        if store.items.isEmpty, shown.isEmpty, !store.isSearching, store.error == nil, store.note == nil,
                  store.intent.isSearchable || store.intent.chips.isEmpty {
            Text("Press return to search \u{201C}\(store.text.trimmingCharacters(in: .whitespaces))\u{201D}")
                .scaledFont(15)
                .foregroundStyle(Theme.secondary)
                .scaledPadding(.horizontal, 16)
                .scaledPadding(.top, 18)
        }
    }

    /// The suggestions under the results: recent searches only show with the field empty, and a flight
    /// number already in the results is not offered twice.
    static func typingSuggestions(_ s: SearchSuggestions, results: [SearchResult]) -> SearchSuggestions {
        let found = Set(results.map { SearchText.ident($0.ident) })
        let groups = s.groups.compactMap { g -> SearchSuggestions.Group? in
            guard g.kind != .recent else { return nil }
            var g = g
            g.items = g.items.filter {
                if case .flight(let ident, _) = $0 { return !found.contains(SearchText.ident(ident)) }
                return true
            }
            return g.items.isEmpty ? nil : g
        }
        return SearchSuggestions(groups: groups)
    }

    private var results: some View {
        VStack(alignment: .leading, spacing: 0) {
            let count = store.items.count
            CapsHeader("Results", trailing: count == 1 ? "1 flight" : "\(count) flights")
                .scaledPadding(.horizontal, 16)
                .scaledPadding(.top, 8)
                .scaledPadding(.bottom, 2)
            ForEach(store.items) { item in
                switch item {
                case .live(let flight):
                    ResultRow(flight: flight, origin: lookup(flight.originIcao), destination: lookup(flight.destinationIcao),
                              state: followState(flight), onOpen: onOpen.map { open in { open(flight) } }) { follow(flight) }
                case .planned(let p):
                    let origin = lookup(p.origin)
                    ResultRow(planned: p, origin: origin, destination: lookup(p.destination),
                              state: plannedHere.contains(UpcomingFlight(p, tz: origin?.timeZone ?? .gmt).id)
                                  ? .following : Self.planState(p, origin: origin, planned: planned)) { plan(p, origin: origin) }
                }
                Hairline(leading: ResultRow.textInset)
            }
        }
    }

    /// Only a provider outage is worth retrying as is; limits and typos are not.
    private func retryAction(_ e: APIError) -> (() -> Void)? {
        e == .providerUnavailable || e == .offline ? { run() } : nil
    }

    private func followState(_ f: Flight) -> ResultRow.FollowState {
        followed.contains(f.id) || alreadyFollowed.contains(f) ? .following : pending.contains(f.id) ? .pending : .idle
    }

    /// Added when its origin-local day's flight is already kept to follow later.
    static func planState(_ p: ScheduledFlight, origin: Airport?, planned: Set<UpcomingFlight.ID>) -> ResultRow.FollowState {
        planned.contains(UpcomingFlight(p, tz: origin?.timeZone ?? .gmt).id) ? .following : .idle
    }

    private func plan(_ p: ScheduledFlight, origin: Airport?) {
        let u = UpcomingFlight(p, tz: origin?.timeZone ?? .gmt)
        guard !plannedHere.contains(u.id), !planned.contains(u.id) else { return }
        plannedHere.insert(u.id)
        onPlan(u)
    }

    /// The field empty: recent searches first (the likeliest next search), then the frequently used
    /// airlines and airports, then Import. No day shortcuts: a day is one word in the field.
    private var suggestions: some View {
        let start = SearchStart(frequent: frequent)
        return VStack(alignment: .leading, spacing: 0) {
            if !store.recent.isEmpty {
                CapsHeader("Recent searches")
                    .scaledPadding(.horizontal, 16)
                    .scaledPadding(.top, 8)
                    .scaledPadding(.bottom, 2)
                ForEach(store.recent, id: \.self) { q in
                    let intent = store.intent(for: q)
                    OptionRow(icon: Self.recentIcon(intent), title: q, subtitle: Self.recentSubtitle(intent, clock: units.clock)) {
                        handle(store.pick(.recent(q)))
                    }
                }
            }
            if !start.frequent.isEmpty {
                CapsHeader("Frequently used")
                    .scaledPadding(.horizontal, 16)
                    .scaledPadding(.top, store.recent.isEmpty ? 8 : 16)
                    .scaledPadding(.bottom, 2)
                ForEach(start.frequent) { frequentRow($0) }
            }
            if let onImport {
                CapsHeader("More")
                    .scaledPadding(.horizontal, 16)
                    .scaledPadding(.top, 16)
                    .scaledPadding(.bottom, 2)
                OptionRow(icon: "square.and.arrow.down", title: "Import flights",
                          subtitle: "From another app, your calendar, an email or a CSV file", action: onImport)
            }
        }
    }

    /// An airline fills the field with its code and a space, ready for the number; an airport too, and
    /// then offers its board and its routes.
    @ViewBuilder private func frequentRow(_ item: FrequentItem) -> some View {
        switch item {
        case .airline(let a, _):
            FrequentRow(title: a.name, subtitle: Self.subtitle(item)) {
                AirlineLogo(airline: a, code: a.iata ?? a.id, size: Self.frequentIcon, decorative: true)
            } action: {
                handle(store.pick(.airline(a)))
            }
        case .airport(let a, _):
            FrequentRow(title: DetailFacts.shortName(a.name), subtitle: Self.subtitle(item)) {
                CountryFlag(code: a.country, size: Self.frequentIcon, decorative: true)
            } action: {
                handle(store.pick(.airport(a)))
            }
        }
    }

    static let frequentIcon: CGFloat = 24

    /// "F8 · FLE" for an airline, "SFO · KSFO · San Francisco" for an airport.
    static func subtitle(_ item: FrequentItem) -> String {
        switch item {
        case .airline(let a, _): [a.iata, a.id].compactMap { $0 }.joined(separator: " · ")
        case .airport(let a, _): [a.iata, a.id, a.city].compactMap { $0 }.joined(separator: " · ")
        }
    }

    static let routeIcon = "point.topleft.down.to.point.bottomright.curvepath"

    private func follow(_ flight: Flight) {
        guard !followed.contains(flight.id), !alreadyFollowed.contains(flight), !pending.contains(flight.id) else { return }
        pending.insert(flight.id)
        // Not cancelled when the sheet closes: the follow still lands on the server, and My Flights must hear of it.
        Task {
            let ok = await store.follow(flight)
            pending.remove(flight.id)
            if ok {
                followed.insert(flight.id)
                onFollowed(flight)
            }
        }
    }

    /// A recent search's icon, by the first piece it reads as: a plane for a flight or an airline, the
    /// route curve for two places, a building for one, a calendar for a day or a time alone.
    static func recentIcon(_ intent: SearchIntent) -> String {
        switch intent.chips.first {
        case .ident, .airline: "airplane"
        case .place: !intent.origins.isEmpty && !intent.destinations.isEmpty ? routeIcon : "building.columns"
        case .day, .time: "calendar"
        case nil: "clock.arrow.circlepath"
        }
    }

    /// "Paris (CDG, ORY) · Rome (FCO, CIA) · Sat Dec 12": the pieces a recent search reads as, as its
    /// chips name them; nil when it reads as none.
    static func recentSubtitle(_ intent: SearchIntent, clock: TimeStyle) -> String? {
        let labels = intent.chips.map { SearchChipText.label($0, clock: clock) }
        return labels.isEmpty ? nil : labels.joined(separator: " · ")
    }
}

// MARK: - Rows

/// Round icon, title and grey line, like a settings row without the chevron.
struct OptionRow: View {
    var icon: String
    var title: String
    var subtitle: String?
    var action: () -> Void
    @ScaledMetric(relativeTo: .body) private var glyph = 26

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .scaledFont(17, weight: .medium)
                    .foregroundStyle(Theme.primary)
                    .frame(width: glyph, height: glyph)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(ui: title).scaledFont(16).foregroundStyle(Theme.primary).lineLimit(1)
                    if let subtitle {
                        Text(ui: subtitle).scaledFont(14).foregroundStyle(Theme.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .scaledPadding(.horizontal, 16)
            .scaledPadding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// An icon (logo or flag), a title and a grey line of codes.
struct FrequentRow<Icon: View>: View {
    var title: String
    var subtitle: String
    @ViewBuilder var icon: Icon
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                icon
                VStack(alignment: .leading, spacing: 1) {
                    Text(ui: title).scaledFont(16).foregroundStyle(Theme.primary).lineLimit(1)
                    Text(ui: subtitle).scaledFont(14).foregroundStyle(Theme.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .scaledPadding(.horizontal, 16)
            .scaledPadding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }
}

/// A found flight on two short lines: the airline's mark, the flight number and route codes, then the
/// day and local times with a status dot, and an Add button. A planned flight (from an airline's
/// schedule) has no status yet and says "Planned" after its times. A tap elsewhere on a live row opens
/// its flight.
struct ResultRow: View {
    enum FollowState { case idle, pending, following }

    var result: SearchResult
    var origin: Airport?
    var destination: Airport?
    var state: FollowState
    var onOpen: (() -> Void)?
    var onFollow: () -> Void
    @Environment(\.units) private var units
    @ScaledMetric(relativeTo: .body) private var mark: CGFloat = 32

    /// Where the text starts, for the hairline under the row: padding, mark and gap.
    static let textInset: CGFloat = 16 + 32 + 12

    init(flight: Flight, origin: Airport?, destination: Airport?, state: FollowState, onOpen: (() -> Void)? = nil,
         onFollow: @escaping () -> Void) {
        self.init(result: .live(flight), origin: origin, destination: destination, state: state, onOpen: onOpen,
                  onFollow: onFollow)
    }

    init(planned: ScheduledFlight, origin: Airport?, destination: Airport?, state: FollowState, onFollow: @escaping () -> Void) {
        self.init(result: .planned(planned), origin: origin, destination: destination, state: state, onFollow: onFollow)
    }

    init(result: SearchResult, origin: Airport?, destination: Airport?, state: FollowState, onOpen: (() -> Void)? = nil,
         onFollow: @escaping () -> Void) {
        self.result = result; self.origin = origin; self.destination = destination; self.state = state
        self.onOpen = onOpen; self.onFollow = onFollow
    }

    /// The button's words.
    static func title(_ state: FollowState) -> String { state == .following ? "Added" : "Add" }

    /// "Add AF 84 to My Flights", "Added AF 84".
    static func accessibility(_ state: FollowState, ident: String) -> String {
        state == .following ? "Added \(Format.ident(ident))" : "Add \(Format.ident(ident)) to My Flights"
    }

    /// The carrier code a badge draws and the key it is looked up by.
    private var airline: (code: String, key: String) {
        switch result {
        case .live(let f):
            let code = f.operator.map(AirportFacts.airlineCode) ?? TravelFacts.airlineCode(ident: f.ident)
            return (code, f.operator ?? code)
        case .planned(let p):
            let code = TravelFacts.airlineCode(ident: p.ident)
            return (code, p.airline ?? code)
        }
    }

    private var originCode: String {
        if case .live(let f) = result { return f.originCode }
        return origin?.iata ?? result.origin
    }

    private var destinationCode: String {
        if case .live(let f) = result { return f.destinationCode }
        return destination?.iata ?? result.destination
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            AirlineMark(code: airline.code, key: airline.key, size: mark, decorative: true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(Format.ident(result.ident)).scaledFont(16, weight: .semibold).foregroundStyle(Theme.primary)
                    Text("\(originCode) \u{2192} \(destinationCode)").scaledFont(16).foregroundStyle(Theme.primary)
                }
                .lineLimit(1)
                HStack(spacing: 5) {
                    if case .live(let f) = result {
                        Circle().fill(f.level.color).frame(width: 7, height: 7)
                    }
                    Text(ui: times).scaledFont(13).foregroundStyle(Theme.secondary).monospacedDigit().lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            followButton
        }
        .scaledPadding(.horizontal, 16)
        .scaledPadding(.vertical, 8)
        .contentShape(Rectangle())
        // The Add button keeps its own taps; the rest of the row opens the flight.
        .onTapGesture { onOpen?() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Self.spoken(result, from: origin?.city ?? originCode, to: destination?.city ?? destinationCode))
        .accessibilityAction(named: "Open flight") { onOpen?() }
    }

    /// "AF 84, Paris to New York": the cities the codes stand for.
    static func spoken(_ result: SearchResult, from: String, to: String) -> String {
        "\(Format.ident(result.ident)), \(ScreenFormat.route(from, to))"
    }

    /// Each end's time in its own airport's zone.
    private var times: String {
        let o = origin?.timeZone ?? .gmt, d = destination?.timeZone ?? .gmt
        let (outDate, inDate): (Date?, Date?) = switch result {
        case .live(let f): (f.estimatedOut ?? f.scheduledOut, f.estimatedIn ?? f.scheduledIn)
        case .planned(let p): (p.scheduledOut, p.scheduledIn)
        }
        let out = outDate.map { Format.clock($0, o, units.clock) } ?? "--:--"
        let inn = inDate.map { Format.clock($0, d, units.clock) } ?? "--:--"
        let day = result.scheduledOut.map { ScreenFormat.chipDay($0, o) } ?? ""
        let planned = if case .planned = result { "  \u{00B7}  Planned" } else { "" }
        return "\(day)  \(out) \u{2192} \(inn)\(planned)"
    }

    @ViewBuilder private var followButton: some View {
        Button(action: onFollow) {
            Group {
                switch state {
                case .idle: Text(Self.title(state))
                case .pending: ProgressView().controlSize(.small)
                case .following: Label(Self.title(state), systemImage: "checkmark").labelStyle(.titleAndIcon)
                }
            }
            .scaledFont(14, weight: .semibold)
            .foregroundStyle(state == .following ? Theme.primary : .white)
            .scaledPadding(.horizontal, 12)
            .scaledPadding(.vertical, 4)
            .frame(minHeight: 30)
            .background(Capsule().fill(state == .following ? Theme.pill : Theme.accent))
        }
        .buttonStyle(.plain)
        .disabled(state != .idle)
        .accessibilityLabel(Self.accessibility(state, ident: result.ident))
    }
}

/// "Paris to San Francisco" with the cities bold.
struct RouteText: View {
    var from: String
    var to: String

    var body: some View {
        Text("\(Text(ui: from).fontWeight(.semibold)) to \(Text(ui: to).fontWeight(.semibold))")
            .scaledFont(17)
            .foregroundStyle(Theme.primary)
    }
}

#if DEBUG
// MARK: - Previews

/// A search store from the seed, optionally searched or failing.
struct SearchPreview: View {
    enum Mode { case start, results, sparse, notFound, planLimit, rateLimited, typing, typingRoute, typingCity }
    var mode: Mode = .start
    @State private var store: SearchStore?

    var body: some View {
        Group {
            if let store {
                SearchView(store: store, onFollowed: { _ in }, lookup: SearchPreview.lookup,
                           frequent: FrequentlyUsed.compute(past: [], followed: PreviewData.followed,
                                                            reference: .bundled(), lookup: SearchPreview.lookup),
                           known: KnownFlight.list(followed: PreviewData.followed, past: []))
            } else {
                ProgressView()
            }
        }
        .task { store = await Self.makeStore(mode) }
    }

    /// ICAO or IATA.
    static func lookup(_ code: String) -> Airport? {
        PreviewData.airport(code) ?? PreviewData.airports.first { $0.iata == code }
    }

    static func makeStore(_ mode: Mode) async -> SearchStore {
        let svc = FakeFlightService(now: PreviewData.now)
        let s = SearchStore(flights: svc)
        s.seedRecent(["AUS SFO", "AF84", "SFO"])
        switch mode {
        case .start: break
        case .typing, .typingRoute, .typingCity:
            s.known = KnownFlight.list(followed: PreviewData.followed, past: [])
            s.text = mode == .typing ? "AF 8" : mode == .typingRoute ? "AUS SFO" : "paris"
            s.suggestNow()
            if mode == .typingRoute { await s.search() }
        case .results, .sparse:
            s.text = mode == .sparse ? "AS312" : "UA1527"
            await s.search()
        case .notFound:
            s.text = "ZZ999"
            await s.search()
        case .planLimit, .rateLimited:
            s.text = "AF84"
            await s.search()
            await svc.setNextError(mode == .planLimit ? .planLimit : .rateLimited)
            _ = await s.follow(s.results[0])
        }
        return s
    }
}

#Preview("Start, dark") { SearchPreview().preferredColorScheme(.dark) }
#Preview("Start, light") { SearchPreview().preferredColorScheme(.light) }
#Preview("Results") { SearchPreview(mode: .results).preferredColorScheme(.dark) }
#Preview("Sparse result") { SearchPreview(mode: .sparse).preferredColorScheme(.dark) }
#Preview("Not found") { SearchPreview(mode: .notFound).preferredColorScheme(.dark) }
#Preview("Plan limit") { SearchPreview(mode: .planLimit).preferredColorScheme(.dark) }
#Preview("Rate limited") { SearchPreview(mode: .rateLimited).preferredColorScheme(.light) }
#Preview("Typing a number") { SearchPreview(mode: .typing).preferredColorScheme(.dark) }
#Preview("Typing a route") { SearchPreview(mode: .typingRoute).preferredColorScheme(.dark) }
#Preview("Typing a city") { SearchPreview(mode: .typingCity).preferredColorScheme(.light) }
#endif
