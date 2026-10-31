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

/// Find a flight to follow: one field for a flight number, a route or an airport. Empty, it offers the
/// frequently used airlines and airports, the recent searches and ways to search; while typing, ranked
/// suggestions on the device (`SearchSuggester`) and, after a pause on a whole flight number or route,
/// its live results, each with a Follow button. Return picks the top suggestion. Errors show in a banner
/// and the typed text stays.
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

    @State private var followed: Set<Flight.ID> = []
    @State private var pending: Set<Flight.ID> = []
    @FocusState private var focused: Bool
    @Environment(\.airportStaticControls) private var staticControls

    /// - Parameters:
    ///   - lookup: airport by ICAO or IATA, for city names and local times in the results.
    ///   - alreadyFollowed: flights already followed, which show "Following" instead of a second Follow.
    ///   - frequent: the airlines and airports offered before anything is typed (`HomeModel.frequent`).
    ///   - onImport: opens the Import screen from the "More" rows; nil leaves the row out.
    ///   - onAirport: opens an airport's board (ICAO) from "Flights from ... today"; nil leaves those rows inert.
    ///   - known: the followed and past flights flight numbers are suggested from.
    public init(store: SearchStore, onFollowed: @escaping (Flight) -> Void,
                lookup: @escaping (String) -> Airport? = { _ in nil }, alreadyFollowed: FollowedFlights = .init(),
                frequent: [FrequentItem] = [], onImport: (() -> Void)? = nil,
                onAirport: ((String) -> Void)? = nil, known: [KnownFlight] = []) {
        self.init(store: store, onFollowed: onFollowed, lookup: lookup, alreadyFollowed: alreadyFollowed,
                  frequent: frequent, scrolls: true, onImport: onImport, onAirport: onAirport, known: known)
    }

    init(store: SearchStore, onFollowed: @escaping (Flight) -> Void, lookup: @escaping (String) -> Airport?,
         alreadyFollowed: FollowedFlights = .init(), frequent: [FrequentItem] = [], scrolls: Bool,
         onImport: (() -> Void)? = nil, onAirport: ((String) -> Void)? = nil, known: [KnownFlight] = []) {
        self.store = store; self.onFollowed = onFollowed; self.lookup = lookup
        self.alreadyFollowed = alreadyFollowed; self.frequent = frequent; self.scrolls = scrolls
        self.onImport = onImport; self.onAirport = onAirport; self.known = known
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScreenTitle("Add Flight", subtitle: "Airline, airport, or flight number")
                .scaledPadding(.horizontal, 20)
                .scaledPadding(.top, 22)
            field
                .scaledPadding(.horizontal, 16)
                .scaledPadding(.top, 16)
                .scaledPadding(.bottom, 8)
            ScreenScroll(scrolls: scrolls) { content }
        }
        .background(Theme.background)
        .onAppear { store.known = known }
        .onChange(of: known) { _, k in store.known = k }
        .onChange(of: store.text) { store.textChanged() }
        .onChange(of: store.suggestions) { _, s in
            guard !isBlank else { return }
            AccessibilityNotification.Announcement(SearchSuggestionRow.announcement(count: s.count)).post()
        }
    }

    private var isBlank: Bool { store.text.trimmingCharacters(in: .whitespaces).isEmpty }

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
        .frame(minHeight: 48)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.pill))
    }

    static let prompt = "AF84, CDG SFO, or AUS"

    private var input: some View {
        TextField("", text: $store.text, prompt: Text(Self.prompt).foregroundStyle(Theme.secondary.opacity(0.75)))
            .scaledFont(17)
            .foregroundStyle(Theme.primary)
            .textFieldStyle(.plain)
            .autocorrectionDisabled()
            #if os(iOS)
            .textInputAutocapitalization(.characters)
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
                if store.results.isEmpty { suggestions } else { results }
            } else {
                typing
            }
        }
        .scaledPadding(.bottom, 24)
    }

    /// While typing: the ranked suggestions, then the live (or returned) results.
    @ViewBuilder private var typing: some View {
        SearchSuggestionList(suggestions: store.suggestions, lookup: lookup) { handle(store.pick($0)) }
        if !store.results.isEmpty {
            results
        } else if store.suggestions.isEmpty, !store.isSearching, store.error == nil {
            Text("Press return to search \u{201C}\(store.text.trimmingCharacters(in: .whitespaces))\u{201D}")
                .scaledFont(15)
                .foregroundStyle(Theme.secondary)
                .scaledPadding(.horizontal, 16)
                .scaledPadding(.top, 18)
        }
    }

    private var results: some View {
        VStack(alignment: .leading, spacing: 0) {
            let count = store.results.count
            CapsHeader("Results", trailing: count == 1 ? "1 flight" : "\(count) flights")
                .scaledPadding(.horizontal, 16)
                .scaledPadding(.top, isBlank ? 16 : 22)
                .scaledPadding(.bottom, 4)
            ForEach(store.results) { flight in
                ResultRow(flight: flight, origin: lookup(flight.originIcao), destination: lookup(flight.destinationIcao),
                          state: followState(flight)) { follow(flight) }
                Hairline(leading: 62)
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

    private var suggestions: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !frequent.isEmpty {
                CapsHeader("Frequently used")
                    .scaledPadding(.horizontal, 16)
                    .scaledPadding(.top, 18)
                    .scaledPadding(.bottom, 4)
                ForEach(frequent) { frequentRow($0) }
            }
            if !store.recent.isEmpty {
                CapsHeader("Recent searches")
                    .scaledPadding(.horizontal, 16)
                    .scaledPadding(.top, frequent.isEmpty ? 18 : 22)
                    .scaledPadding(.bottom, 4)
                ForEach(store.recent, id: \.self) { q in
                    OptionRow(icon: icon(for: q), title: q, subtitle: describe(q)) {
                        handle(store.pick(.recent(q)))
                    }
                }
            }
            CapsHeader("More")
                .scaledPadding(.horizontal, 16)
                .scaledPadding(.top, 22)
                .scaledPadding(.bottom, 4)
            OptionRow(icon: Self.routeIcon, title: "Find by route", subtitle: nil) {
                focused = true
            }
            if let onImport {
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

    private func icon(for query: String) -> String {
        switch FlightQuery.parse(query, date: store.date) {
        case .ident: "airplane"
        case .route: Self.routeIcon
        case .airport: "building.columns"
        case nil: "clock.arrow.circlepath"
        }
    }

    /// "Flight", "Austin to San Francisco", "Austin" from the parsed query.
    private func describe(_ query: String) -> String? {
        switch FlightQuery.parse(query, date: store.date) {
        case .ident: return "Flight"
        case .route(let o, let d, _):
            return ScreenFormat.route(lookup(o)?.city ?? o, lookup(d)?.city ?? d)
        case .airport(let code): return lookup(code).map { "\($0.city), all flights today" } ?? "Airport"
        case nil: return nil
        }
    }
}

// MARK: - Rows

/// Round icon, title and grey line, like a settings row without the chevron.
struct OptionRow: View {
    var icon: String
    var title: String
    var subtitle: String?
    var action: () -> Void
    @ScaledMetric(relativeTo: .body) private var glyph = 30

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .scaledFont(19, weight: .medium)
                    .foregroundStyle(Theme.primary)
                    .frame(width: glyph, height: glyph)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).scaledFont(17).foregroundStyle(Theme.primary)
                    if let subtitle {
                        Text(subtitle).scaledFont(15).foregroundStyle(Theme.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .scaledPadding(.horizontal, 16)
            .scaledPadding(.vertical, 12)
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
            HStack(spacing: 16) {
                icon
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).scaledFont(17).foregroundStyle(Theme.primary).lineLimit(1)
                    Text(subtitle).scaledFont(15).foregroundStyle(Theme.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .scaledPadding(.horizontal, 16)
            .scaledPadding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }
}

/// A found flight: number and status, route with local times, and a Follow button.
struct ResultRow: View {
    enum FollowState { case idle, pending, following }

    var flight: Flight
    var origin: Airport?
    var destination: Airport?
    var state: FollowState
    var onFollow: () -> Void
    @Environment(\.units) private var units

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            let code = flight.operator.map(AirportFacts.airlineCode) ?? TravelFacts.airlineCode(ident: flight.ident)
            AirlineMark(code: code, key: flight.operator ?? code, decorative: true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(Format.ident(flight.ident)).scaledFont(15, weight: .semibold).foregroundStyle(Theme.secondary)
                    Text("\(flight.originCode) \u{2192} \(flight.destinationCode)").scaledFont(15).foregroundStyle(Theme.secondary.opacity(0.8))
                }
                RouteText(from: origin?.city ?? flight.originCode, to: destination?.city ?? flight.destinationCode)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Circle().fill(flight.level.color).frame(width: 7, height: 7)
                    Text(times).scaledFont(13).foregroundStyle(Theme.secondary).monospacedDigit()
                }
            }
            Spacer(minLength: 8)
            followButton
        }
        .scaledPadding(.horizontal, 16)
        .scaledPadding(.vertical, 10)
    }

    private var times: String {
        let o = origin?.timeZone ?? .gmt, d = destination?.timeZone ?? .gmt
        let out = (flight.estimatedOut ?? flight.scheduledOut).map { Format.clock($0, o, units.clock) } ?? "--:--"
        let inn = (flight.estimatedIn ?? flight.scheduledIn).map { Format.clock($0, d, units.clock) } ?? "--:--"
        let day = flight.scheduledOut.map { ScreenFormat.chipDay($0, o) } ?? ""
        return "\(day)  \(out) \u{2192} \(inn)"
    }

    @ViewBuilder private var followButton: some View {
        Button(action: onFollow) {
            Group {
                switch state {
                case .idle: Text("Follow")
                case .pending: ProgressView().controlSize(.small)
                case .following: Label("Following", systemImage: "checkmark").labelStyle(.titleAndIcon)
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
        .accessibilityLabel(state == .following ? "Following \(flight.ident)" : "Follow \(flight.ident)")
    }
}

/// "Paris to San Francisco" with the cities bold.
struct RouteText: View {
    var from: String
    var to: String

    var body: some View {
        Text("\(Text(from).fontWeight(.semibold)) to \(Text(to).fontWeight(.semibold))")
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
