import SwiftUI

/// One followed flight in full: the airline, flight number and route pinned at the top; then the
/// countdown card, a canceled or diverted notice, departure and arrival with their gates, the booking
/// code and seat tiles, the timeline, the aircraft, what changed, and the notes. A floating bar shares
/// the flight, turns its alerts on or off and holds the rarer actions. The map arc and live plane
/// belong to the shell.
public struct FlightDetailView: View {
    var store: FlightDetailStore
    var onAirport: (String) -> Void
    var onClose: (() -> Void)?
    var onStopTracking: ((Flight.ID) async -> APIError?)?
    var fixedNow: Date?
    var scrolls: Bool
    @State private var editing: DetailField?
    @State private var pasteHint: String?
    @State private var pasteFailures = 0
    @Environment(\.reference) private var reference
    @Environment(\.units) private var units
    @Environment(\.openURL) private var openURL

    /// - Parameters:
    ///   - onAirport: opens the airport sheet for an ICAO code.
    ///   - onClose: closes the sheet; nil hides the close button.
    ///   - onStopTracking: unfollows the flight through the shell's list and returns the error, nil on
    ///     success; when nil the store asks the service. The sheet closes (`onClose`) once it worked.
    ///   - now: a fixed clock for previews; nil follows the real time.
    public init(store: FlightDetailStore, onAirport: @escaping (String) -> Void, onClose: (() -> Void)? = nil,
                onStopTracking: ((Flight.ID) async -> APIError?)? = nil, now: Date? = nil) {
        self.init(store: store, onAirport: onAirport, onClose: onClose, onStopTracking: onStopTracking,
                  now: now, scrolls: true)
    }

    init(store: FlightDetailStore, onAirport: @escaping (String) -> Void, onClose: (() -> Void)? = nil,
         onStopTracking: ((Flight.ID) async -> APIError?)? = nil, now: Date?, scrolls: Bool) {
        self.store = store; self.onAirport = onAirport; self.onClose = onClose
        self.onStopTracking = onStopTracking; self.fixedNow = now; self.scrolls = scrolls
    }

    public var body: some View {
        ClockView(fixed: fixedNow) { now in
            VStack(spacing: 0) {
                if let flight = store.flight {
                    DetailHeader(flight: flight, origin: store.origin, destination: plannedDestination(flight),
                                 airline: airline(flight), onClose: onClose)
                        .scaledPadding(.leading, Theme.gutter)
                        .scaledPadding(.trailing, 16)
                        .scaledPadding(.top, 16)
                        .scaledPadding(.bottom, 12)
                    Hairline()
                    ScreenScroll(scrolls: scrolls) { sections(flight, now: now) }
                        .defaultScrollAnchor(Self.startAnchor)
                } else {
                    if let onClose {
                        HStack { Spacer(); RoundButton(systemImage: "xmark", label: "Close", action: onClose) }
                            .scaledPadding(.top, 16)
                            .scaledPadding(.trailing, 16)
                    }
                    if let error = store.error {
                        ErrorBanner(error: error, retry: reload)
                            .scaledPadding(.all, 16)
                        Spacer(minLength: 0)
                    } else {
                        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }
        .background(Theme.background)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let flight = store.flight {
                bottomBar(flight)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .scaledPadding(.leading, Theme.gutter)
                    .scaledPadding(.bottom, 6)
            }
        }
        .sheet(item: $editing) { field in
            DetailEditSheet(field: field, store: store)
                .environment(\.units, units)
        }
        .alert("Could Not Stop Tracking", isPresented: Binding(
            get: { store.trackingError != nil },
            set: { if !$0 { store.clearTrackingError() } })) {
            Button("OK", role: .cancel) { store.clearTrackingError() }
        } message: {
            Text(store.trackingError?.message ?? "")
        }
        .sensoryFeedback(.error, trigger: pasteFailures)
    }

    private func reload() { Task { await store.load() } }

    /// Where the sheet opens: the top, or the bottom for screenshot runs (`-detailScroll bottom`).
    private static var startAnchor: UnitPoint? {
        #if DEBUG
        UserDefaults.standard.string(forKey: "detailScroll") == "bottom" ? .bottom : nil
        #else
        nil
        #endif
    }

    private func airline(_ f: Flight) -> Airline? {
        f.operator.flatMap { reference.airline($0) } ?? reference.airline(ident: f.ident)
    }

    /// Live flights go stale after 5 minutes, the rest after an hour.
    static func ttl(_ f: Flight) -> Duration {
        f.status == .departed || f.status == .enRoute ? .seconds(300) : .seconds(3600)
    }

    private func sections(_ flight: Flight, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                if let error = store.error {
                    ErrorBanner(error: error, retry: reload)
                }
                if let error = store.detailsError {
                    ErrorBanner(error: error)
                }
                SectionFreshness(fetchedAt: flight.updatedAt, ttl: Self.ttl(flight), now: now)
                if let notice = notice(flight) { notice }
                CountdownCard(title: DetailFacts.countdown(flight, destination: store.destination, now: now),
                              caption: DetailFacts.countdownCaption(flight, airline: airline(flight)))
                DepartArrive(flight: flight, origin: store.origin, destination: plannedDestination(flight), now: now,
                             onAirport: onAirport)
                    .scaledPadding(.top, 16)
                if let details = store.details {
                    DetailTiles(details: details, onEdit: { editing = $0 }, onPaste: paste, hint: pasteHint)
                        .scaledPadding(.top, 12)
                }
            }
            .scaledPadding(.horizontal, Theme.gutter)
            .scaledPadding(.top, 16)
            .scaledPadding(.bottom, 24)

            section {
                SectionHeader("Timeline", subtitle: "Local times at each airport")
                    .scaledPadding(.bottom, 16)
                FlightTimeline(flight: flight, origin: store.origin, destination: plannedDestination(flight), now: now)
            }
            section {
                SectionHeader("Aircraft")
                    .scaledPadding(.bottom, 12)
                AircraftRow(type: flight.aircraftType, registration: flight.registration)
            }
            if !store.events.isEmpty {
                section {
                    SectionHeader("Changes", subtitle: "What moved since you started tracking")
                        .scaledPadding(.bottom, 8)
                    ForEach(store.events.reversed()) { e in
                        EventRow(event: e, timeZone: store.origin?.timeZone ?? .current)
                    }
                }
            }
            if flight.status == .diverted, let diverted = store.destination, diverted.id != flight.destinationIcao {
                section {
                    AirportLinkRow(role: "Diverted to", code: diverted.id, airport: diverted, tag: "Diverted") {
                        onAirport(diverted.id)
                    }
                }
            }
            if let details = store.details {
                NotesCard(notes: details.notes) { editing = .notes }
                    .scaledPadding(.horizontal, Theme.gutter)
                    .scaledPadding(.top, 8)
            }
        }
        // Room for the floating bar over the last card.
        .scaledPadding(.bottom, 88)
    }

    private func bottomBar(_ flight: Flight) -> some View {
        DetailBottomBar(shareText: DetailFacts.shareText(flight, origin: store.origin,
                                                         destination: plannedDestination(flight), clock: units.clock),
                        notify: DetailFacts.takesAlerts(flight) ? store.notify : nil,
                        onNotify: { on in Task { await store.setNotify(on) } }) {
            if store.isFollowed {
                Button("Stop Tracking", systemImage: "minus.circle", role: .destructive) { stopTracking() }
            }
            Button("Copy Flight Number", systemImage: "doc.on.doc") { Pasteboard.copy(Format.ident(flight.ident)) }
            Button("Report a Data Issue", systemImage: "exclamationmark.bubble") { openURL(SettingsView.supportURL) }
        }
    }

    private func stopTracking() {
        Task {
            if await store.stopTracking(via: onStopTracking) { onClose?() }
        }
    }

    /// Keeps pasted text only when it reads as a booking code; anything else says so under the tiles
    /// for a few seconds.
    private func paste(_ text: String) {
        guard var next = store.details else { return }
        guard let code = DetailFacts.pastedBookingCode(text) else {
            pasteFailures += 1
            let attempt = pasteFailures
            pasteHint = DetailFacts.pasteHint
            Task {
                try? await Task.sleep(for: .seconds(3))
                if pasteFailures == attempt { pasteHint = nil }
            }
            return
        }
        pasteHint = nil
        next.bookingCode = code
        Task { await store.saveDetails(next) }
    }

    /// The card and timeline describe the planned trip; a diversion target only shows when it is
    /// the planned airport.
    private func plannedDestination(_ f: Flight) -> Airport? {
        store.destination?.id == f.destinationIcao ? store.destination : nil
    }

    private func notice(_ f: Flight) -> AnyView? {
        switch f.status {
        case .canceled:
            return AnyView(StatusNotice(color: Theme.veryLate, title: "Canceled",
                                        text: "The airline canceled this flight. Check with them for a new booking."))
        case .diverted:
            // Only a target other than the planned airport is news.
            let to = store.destination.flatMap { $0.id == f.destinationIcao ? nil : "\($0.city) (\($0.iata ?? $0.id))" }
            return AnyView(StatusNotice(color: Theme.diverted, title: "Diverted",
                                        text: to.map { "Landing at \($0) instead of \(f.destinationCode)." }
                                            ?? "Not landing at \(f.destinationCode). The new airport is not known yet."))
        default:
            return nil
        }
    }

    private func section<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 0) { content() }
            .scaledPadding(.horizontal, Theme.gutter)
            .scaledPadding(.vertical, 22)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .top) { Hairline() }
    }
}

// MARK: - Pieces

/// Tinted card for a canceled or diverted flight.
struct StatusNotice: View {
    var color: Color
    var title: String
    var text: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle().fill(color.opacity(0.25)).frame(width: 16, height: 16)
                Circle().fill(color).frame(width: 7, height: 7)
            }
            .scaledPadding(.top, 3)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).scaledFont(17, weight: .semibold).foregroundStyle(Theme.primary)
                Text(text).scaledFont(15).foregroundStyle(Theme.primary.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scaledPadding(.all, 16)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(color.opacity(0.16)))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(color.opacity(0.35), lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}

/// Departure and arrival terminal, gate and belt, "TBA" until known.
struct AircraftRow: View {
    var type: String?
    var registration: String?
    @ScaledMetric(relativeTo: .body) private var icon = 40

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "airplane")
                .scaledFont(18, weight: .semibold)
                .foregroundStyle(Theme.primary)
                .frame(width: icon, height: icon)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.card))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(type.map(TravelFacts.aircraftName) ?? "Aircraft not assigned yet")
                    .scaledFont(17, weight: .semibold)
                    .foregroundStyle(type == nil ? Theme.secondary : Theme.primary)
                let parts = [type, registration].compactMap { $0 }
                if !parts.isEmpty {
                    Text(parts.joined(separator: "  ·  "))
                        .scaledFont(14)
                        .foregroundStyle(Theme.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

/// One airport with its role, tappable to open the airport sheet.
struct AirportLinkRow: View {
    var role: String
    var code: String
    var airport: Airport?
    var iata: String?
    var tag: String?
    var action: () -> Void
    @ScaledMetric(relativeTo: .body) private var badge = 40

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Text(airport?.iata ?? iata ?? code)
                    .scaledFont(15, weight: .bold)
                    .foregroundStyle(Theme.primary)
                    .frame(width: badge, height: badge)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.card))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(role.uppercased()).scaledFont(12, weight: .medium).foregroundStyle(Theme.secondary)
                        if let tag {
                            Text(tag.uppercased())
                                .scaledFont(11, weight: .semibold)
                                .foregroundStyle(Theme.diverted)
                        }
                    }
                    Text(airport?.name ?? code)
                        .scaledFont(17, weight: .semibold)
                        .foregroundStyle(Theme.primary)
                        .lineLimit(1)
                    if let airport {
                        Text("\(airport.city), \(AirportFacts.countryName(airport.country))")
                            .scaledFont(14)
                            .foregroundStyle(Theme.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                RowChevron()
            }
            .scaledPadding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens the airport")
    }
}

/// One change seen on the flight, newest first.
struct EventRow: View {
    @Environment(\.units) private var units
    var event: FlightEvent
    var timeZone: TimeZone

    var body: some View {
        if let text = DetailFacts.eventText(event) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Image(systemName: DetailFacts.eventIcon(event.kind))
                    .scaledFont(14, weight: .medium)
                    .foregroundStyle(Theme.secondary)
                    .frame(width: 20)
                    .accessibilityHidden(true)
                Text(text).scaledFont(15).foregroundStyle(Theme.primary)
                Spacer(minLength: 8)
                Text(Format.clock(event.receivedAt, timeZone, units.clock))
                    .scaledFont(14)
                    .monospacedDigit()
                    .foregroundStyle(Theme.secondary)
            }
            .scaledPadding(.vertical, 8)
            .accessibilityElement(children: .combine)
        }
    }
}

// MARK: - Wording

enum DetailFacts {
    /// "Air France  ·  In the air" style caption under the title.
    /// Canceled and finished flights send no more alerts, so they show no switch.
    static func takesAlerts(_ f: Flight) -> Bool {
        ![.canceled, .landed, .arrived].contains(f.status)
    }

    static func caption(_ f: Flight) -> String {
        let status: String = switch f.status {
        case .scheduled, .unknown: "Scheduled"
        case .departed: "Left the gate"
        case .enRoute: "In the air"
        case .landed: "Landed"
        case .arrived: "At the gate"
        case .canceled: "Canceled"
        case .diverted: "Diverted"
        }
        let airline = f.operator.map { AirportFacts.airlineCode($0) } ?? TravelFacts.airlineCode(ident: f.ident)
        return "\(airline)  ·  \(f.originCode) to \(f.destinationCode)  ·  \(status)"
    }

    /// Time left or since, from the best known gate times.
    static func progressLine(_ f: Flight, now: Date) -> String? {
        switch f.status {
        case .canceled, .diverted, .unknown: return nil
        case .landed, .arrived:
            guard let at = f.actualIn ?? f.actualOn else { return nil }
            let since = now.timeIntervalSince(at)
            return since < 60 ? "Landed just now" : "Landed \(ScreenFormat.span(since)) ago"
        case .departed, .enRoute:
            guard let end = f.actualIn ?? f.estimatedIn ?? f.scheduledIn, end > now else { return nil }
            return "Arrives in \(ScreenFormat.span(end.timeIntervalSince(now), floor: "under a minute"))"
        case .scheduled:
            guard let out = f.actualOut ?? f.estimatedOut ?? f.scheduledOut, out > now else { return nil }
            return "Leaves the gate in \(ScreenFormat.span(out.timeIntervalSince(now), floor: "under a minute"))"
        }
    }

    static func eventText(_ e: FlightEvent) -> String? {
        switch e.kind {
        case .gateChange: e.payload["gate"].map { "Gate changed to \($0)" } ?? "Gate changed"
        case .delay: e.payload["minutes"].flatMap(Int.init).map { "Delayed by \(Format.minutes($0))" } ?? "Delayed"
        case .departure: "Left the gate"
        case .arrival: "Arrived at the gate"
        case .cancel: "Canceled"
        case .diversion: e.payload["destination"].map { "Diverted to \($0)" } ?? "Diverted"
        case .position: nil
        }
    }

    static func eventIcon(_ k: FlightEventKind) -> String {
        switch k {
        case .gateChange: "door.left.hand.open"
        case .delay: "clock.badge.exclamationmark"
        case .departure: "airplane.departure"
        case .arrival: "airplane.arrival"
        case .cancel: "xmark.circle"
        case .diversion: "arrow.triangle.branch"
        case .position: "location"
        }
    }
}

#if DEBUG
// MARK: - Previews

/// Loads a detail store from the seed at the seed's own clock.
struct FlightDetailPreview: View {
    enum Mode { case enRoute, sparse, canceled, diverted, error, stale, failed, noted }
    var mode: Mode = .enRoute
    @State private var store: FlightDetailStore?

    var body: some View {
        Group {
            if let store {
                FlightDetailView(store: store, onAirport: { _ in },
                                 now: PreviewData.now.addingTimeInterval(mode == .stale ? 40 * 60 : 0))
            } else {
                ProgressView()
            }
        }
        .task { store = await Self.makeStore(mode) }
    }

    static func makeStore(_ mode: Mode) async -> FlightDetailStore {
        let flights = FakeFlightService(now: PreviewData.now)
        let airports = FakeAirportService(now: PreviewData.now)
        let flight: Flight = switch mode {
        case .sparse: PreviewData.sparse
        case .canceled: PreviewData.canceled
        case .diverted: PreviewData.diverted
        default: PreviewData.enRoute
        }
        let s = FlightDetailStore(id: flight.id, flights: flights, airports: airports)
        if mode == .failed { await flights.setNextError(.providerUnavailable) }
        await s.load()
        if mode == .error {
            await airports.setNextError(.providerUnavailable)
            await s.load()
        }
        if mode == .noted {
            await s.saveDetails(FollowDetails(seatClass: .business, seat: "23A", reason: .personal, bookingCode: "K7PQ2X",
                                              notes: "Lounge on the upper level past security. Ask for the exit row on the way back."))
        }
        return s
    }
}

#Preview("En route, dark") { FlightDetailPreview().preferredColorScheme(.dark) }
#Preview("En route, light") { FlightDetailPreview().preferredColorScheme(.light) }
#Preview("Sparse") { FlightDetailPreview(mode: .sparse).preferredColorScheme(.dark) }
#Preview("Canceled") { FlightDetailPreview(mode: .canceled).preferredColorScheme(.dark) }
#Preview("Diverted") { FlightDetailPreview(mode: .diverted).preferredColorScheme(.dark) }
#Preview("Error, data kept") { FlightDetailPreview(mode: .error).preferredColorScheme(.dark) }
#Preview("Stale") { FlightDetailPreview(mode: .stale).preferredColorScheme(.dark) }
#Preview("Noted") { FlightDetailPreview(mode: .noted).preferredColorScheme(.dark) }
#Preview("Failed, nothing to show") { FlightDetailPreview(mode: .failed).preferredColorScheme(.light) }
#endif
