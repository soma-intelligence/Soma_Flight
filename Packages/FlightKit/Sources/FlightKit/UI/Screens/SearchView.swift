import SwiftUI

/// Find a flight to follow: one field for a flight number, a route or an airport, the recent
/// searches and ways to search under it, and the results with a Follow button each. Errors show
/// in a banner and the typed text stays.
public struct SearchView: View {
    @Bindable var store: SearchStore
    var onFollowed: (Flight) -> Void
    var lookup: (String) -> Airport?
    var followedIDs: Set<Flight.ID>
    var scrolls: Bool

    @State private var followed: Set<Flight.ID> = []
    @State private var pending: Set<Flight.ID> = []
    @FocusState private var focused: Bool
    @Environment(\.airportStaticControls) private var staticControls

    /// - Parameters:
    ///   - lookup: airport by ICAO or IATA, for city names and local times in the results.
    ///   - followedIDs: flights already followed, which show "Following" instead of a second Follow.
    public init(store: SearchStore, onFollowed: @escaping (Flight) -> Void,
                lookup: @escaping (String) -> Airport? = { _ in nil }, followedIDs: Set<Flight.ID> = []) {
        self.init(store: store, onFollowed: onFollowed, lookup: lookup, followedIDs: followedIDs, scrolls: true)
    }

    init(store: SearchStore, onFollowed: @escaping (Flight) -> Void, lookup: @escaping (String) -> Airport?,
         followedIDs: Set<Flight.ID> = [], scrolls: Bool) {
        self.store = store; self.onFollowed = onFollowed; self.lookup = lookup
        self.followedIDs = followedIDs; self.scrolls = scrolls
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScreenTitle("Find a Flight", subtitle: "Flight number, route, or airport")
                .padding(.horizontal, 20)
                .padding(.top, 22)
            field
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 8)
            ScreenScroll(scrolls: scrolls) { content }
        }
        .background(Theme.background)
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
        .padding(.horizontal, 14)
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
            .onSubmit(run)
    }

    private func run() {
        Task { await store.search() }
    }

    // MARK: Content

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let error = store.error {
                ErrorBanner(error: error, retry: retryAction(error))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
            }
            if store.results.isEmpty {
                suggestions
            } else {
                results
            }
        }
        .padding(.bottom, 24)
    }

    private var results: some View {
        VStack(alignment: .leading, spacing: 0) {
            let count = store.results.count
            CapsHeader("Results", trailing: count == 1 ? "1 flight" : "\(count) flights")
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 4)
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
        followed.contains(f.id) || followedIDs.contains(f.id) ? .following : pending.contains(f.id) ? .pending : .idle
    }

    private var suggestions: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !store.recent.isEmpty {
                CapsHeader("Recent searches")
                    .padding(.horizontal, 16)
                    .padding(.top, 18)
                    .padding(.bottom, 4)
                ForEach(store.recent, id: \.self) { q in
                    OptionRow(icon: icon(for: q), title: q, subtitle: describe(q)) {
                        store.text = q
                        run()
                    }
                }
            }
            CapsHeader("Ways to search")
                .padding(.horizontal, 16)
                .padding(.top, 22)
                .padding(.bottom, 4)
            OptionRow(icon: "number", title: "By flight number", subtitle: "Airline code and number, like UA1527") {
                focused = true
            }
            OptionRow(icon: Self.routeIcon, title: "By route", subtitle: "Two airports, like AUS SFO") {
                focused = true
            }
            OptionRow(icon: "building.columns", title: "By airport", subtitle: "One airport code for its flights today") {
                focused = true
            }
        }
    }

    static let routeIcon = "point.topleft.down.to.point.bottomright.curvepath"

    private func follow(_ flight: Flight) {
        guard !followed.contains(flight.id), !followedIDs.contains(flight.id), !pending.contains(flight.id) else { return }
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
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
            AirlineBadge(code: code, key: flight.operator ?? code)
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
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
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
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
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

/// Round tinted badge with the airline code, standing in for a logo.
struct AirlineBadge: View {
    var code: String
    var key: String
    @ScaledMetric(relativeTo: .body) private var size = 34

    var body: some View {
        Text(code)
            .scaledFont(12, weight: .bold)
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Circle().fill(TravelFacts.airlineTint(key)))
            .accessibilityHidden(true)
    }
}

#if DEBUG
// MARK: - Previews

/// A search store from the seed, optionally searched or failing.
struct SearchPreview: View {
    enum Mode { case start, results, sparse, notFound, planLimit, rateLimited }
    var mode: Mode = .start
    @State private var store: SearchStore?

    var body: some View {
        Group {
            if let store {
                SearchView(store: store, onFollowed: { _ in }, lookup: SearchPreview.lookup)
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
#endif
