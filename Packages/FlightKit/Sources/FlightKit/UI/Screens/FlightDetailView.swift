import SwiftUI

/// One followed flight in full: the airline, flight number and route pinned at the top; then the
/// countdown card, a canceled or diverted notice, departure and arrival with their gates, the booking
/// code and seat tiles, Good to Know, the arrival forecast and where the plane is (fakes only for
/// now), the detailed timetable, the airline, the user's
/// history on the route, every update, the notes and a link to report a data issue. A floating bar shares
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
                                 airline: airline(flight), onClose: onClose,
                                 actions: Self.barInHeader ? AnyView(bottomBar(flight, compact: true)) : nil)
                        .scaledPadding(.leading, Theme.gutter)
                        .scaledPadding(.trailing, 16)
                        .scaledPadding(.top, 16)
                        .scaledPadding(.bottom, 12)
                    Hairline()
                    ScrollViewReader { proxy in
                        ScreenScroll(scrolls: scrolls) { sections(flight, now: now) }
                            .defaultScrollAnchor(Self.startAnchor)
                            .task(id: store.routeHistory != nil) { await jumpForScreenshots(proxy) }
                    }
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
            if let flight = store.flight, !Self.barInHeader {
                bottomBar(flight)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .scaledPadding(.leading, Theme.gutter)
                    .scaledPadding(.bottom, 6)
            }
        }
        // The Mac shows the editors as popovers on their tile (`detailEditor`); iOS as sheets.
        .sheet(item: Self.barInHeader ? .constant(nil) : $editing) { field in
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
        .task(id: store.flight?.id) {
            if store.flight != nil { await store.loadExtras() }
        }
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

    /// Screenshot runs: `-detailScroll goodToKnow|forecast|plane|timetable|airline` opens the sheet with that card at
    /// the top, once the extras are in.
    private func jumpForScreenshots(_ proxy: ScrollViewProxy) async {
        #if DEBUG
        guard let target = UserDefaults.standard.string(forKey: "detailScroll"), target != "bottom" else { return }
        try? await Task.sleep(for: .milliseconds(400))
        proxy.scrollTo(target, anchor: .top)
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
                    DetailTiles(details: details, onEdit: { editing = $0 }, onPaste: paste, hint: pasteHint,
                                editing: $editing, store: store)
                        .scaledPadding(.top, 12)
                }
            }
            .scaledPadding(.horizontal, Theme.gutter)
            .scaledPadding(.top, 16)
            .scaledPadding(.bottom, 24)

            VStack(alignment: .leading, spacing: 16) {
                GoodToKnow(origin: .init(icao: flight.originIcao, code: flight.originCode, stats: store.originStats,
                                         weather: store.originWeather, departures: true),
                           destination: arrivalSide(flight),
                           timeZone: timeZoneChange(flight),
                           onAirport: onAirport)
                    .id("goodToKnow")
                ForecastSection(forecast: store.forecast)
                    .id("forecast")
                let type = flight.aircraftType.flatMap { reference.type($0) }
                if PlaneSection.isShown(type: type, inbound: store.inbound) {
                    PlaneSection(flight: flight, type: type, airline: airline(flight), inbound: store.inbound)
                        .id("plane")
                } else {
                    DetailCard {
                        CardTitle("Aircraft")
                            .scaledPadding(.bottom, 12)
                        AircraftRow(type: flight.aircraftType, registration: flight.registration)
                    }
                }
                TimetableCard(rows: Timetable.rows(flight, originTz: store.origin?.timeZone ?? .gmt,
                                                   destinationTz: plannedDestination(flight)?.timeZone ?? .gmt,
                                                   clock: units.clock))
                    .id("timetable")
                AirlineCard(airline: airline(flight))
                    .id("airline")
                if let history = store.routeHistory {
                    RouteHistoryCard(history: history, from: flight.originCode, to: flight.destinationCode)
                }
                UpdatesCard(events: store.events, timeZone: store.origin?.timeZone ?? .current)
                if flight.status == .diverted, let diverted = store.destination, diverted.id != flight.destinationIcao {
                    DetailCard {
                        AirportLinkRow(role: "Diverted to", code: diverted.id, airport: diverted, tag: "Diverted") {
                            onAirport(diverted.id)
                        }
                    }
                }
                if let details = store.details {
                    NotesCard(notes: details.notes) { editing = .notes }
                        .detailEditor(.notes, editing: $editing, store: store)
                }
                ReportLink(url: DetailFacts.reportURL(flight, origin: store.origin?.timeZone ?? .gmt))
                    .scaledPadding(.top, 24)
            }
            .scaledPadding(.horizontal, Theme.gutter)
        }
        // Room for the floating bar over the last card (the Mac has it in the header).
        .scaledPadding(.bottom, Self.barInHeader ? 24 : 88)
    }

    /// The Mac's 360 pt panel has no room for a floating bar: its three buttons go in the header.
    static var barInHeader: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }

    private func bottomBar(_ flight: Flight, compact: Bool = false) -> some View {
        DetailBottomBar(shareText: DetailFacts.shareText(flight, origin: store.origin,
                                                         destination: plannedDestination(flight), clock: units.clock),
                        notify: DetailFacts.takesAlerts(flight) ? store.notify : nil,
                        onNotify: { on in Task { await store.setNotify(on) } }, compact: compact) {
            if store.isFollowed {
                Button("Stop Tracking", systemImage: "minus.circle", role: .destructive) { stopTracking() }
            }
            Button("Copy Flight Number", systemImage: "doc.on.doc") { Pasteboard.copy(Format.ident(flight.ident)) }
            Button(DetailFacts.reportLabel, systemImage: "exclamationmark.bubble") {
                // No mail app: the address goes to the pasteboard, as under the report link.
                openURL(DetailFacts.reportURL(flight, origin: store.origin?.timeZone ?? .gmt)) { accepted in
                    if !accepted { Pasteboard.copy(DetailFacts.supportAddress) }
                }
            }
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

    /// The destination's Good to Know block: where the flight actually lands.
    private func arrivalSide(_ f: Flight) -> GoodToKnow.Side {
        let icao = store.destination?.id ?? f.destinationIcao
        let code = store.destination.map { $0.iata ?? $0.id } ?? f.destinationCode
        return .init(icao: icao, code: code, stats: store.destinationStats, weather: store.destinationWeather,
                     departures: false)
    }

    private func timeZoneChange(_ f: Flight) -> (title: String, text: String)? {
        guard let o = store.origin, let d = plannedDestination(f), let arrival = DetailFacts.bestIn(f) else { return nil }
        return DetailFacts.timeZoneChange(origin: o, destination: d, arrival: arrival, clock: units.clock)
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

/// Every change the backend saw on the flight, newest first, along a thin line; never blurred.
/// Draws nothing until there is one. "Every event" means every event a person can read: live position
/// samples (`position`, `eventText` nil) are left out, and the count line counts the rows shown.
struct UpdatesCard: View {
    var events: [FlightEvent]
    var timeZone: TimeZone
    @Environment(\.units) private var units

    private var shown: [(event: FlightEvent, text: String)] {
        events.reversed().compactMap { e in DetailFacts.eventText(e).map { (e, $0) } }
    }

    var body: some View {
        let rows = shown
        if !rows.isEmpty {
            DetailCard {
                CardTitle("Updates", subtitle: DetailFacts.updatesLine(rows.count))
                    .scaledPadding(.bottom, 10)
                ForEach(Array(rows.enumerated()), id: \.element.event.id) { index, row in
                    HStack(alignment: .top, spacing: 12) {
                        VStack(spacing: 0) {
                            Image(systemName: DetailFacts.eventIcon(row.event.kind))
                                .scaledFont(13, weight: .semibold)
                                .foregroundStyle(Theme.primary)
                                .frame(width: 28, height: 28)
                                .background(Circle().fill(Theme.pill))
                            if index < rows.count - 1 {
                                Rectangle().fill(Theme.separator).frame(width: 2).frame(maxHeight: .infinity)
                            }
                        }
                        .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.text).scaledFont(17, weight: .medium).foregroundStyle(Theme.primary)
                            Text("\(ScreenFormat.day(row.event.receivedAt, timeZone)), "
                                 + Format.clock(row.event.receivedAt, timeZone, units.clock))
                                .scaledFont(14)
                                .monospacedDigit()
                                .foregroundStyle(Theme.secondary)
                        }
                        .scaledPadding(.bottom, index < rows.count - 1 ? 14 : 0)
                        Spacer(minLength: 0)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }
}

/// "Report a Data Issue", centred under the last card; opens a mail to support about this flight. With no
/// mail app to take it, the address goes to the pasteboard and a line under the link says so.
struct ReportLink: View {
    var url: URL
    @Environment(\.openURL) private var openURL
    @State private var copied = false

    var body: some View {
        VStack(spacing: 4) {
            Button {
                openURL(url) { accepted in
                    guard !accepted else { return }
                    Pasteboard.copy(DetailFacts.supportAddress)
                    copied = true
                }
            } label: {
                Label(DetailFacts.reportLabel, systemImage: "exclamationmark.bubble")
                    .scaledFont(18)
                    .foregroundStyle(Theme.secondary)
                    .frame(maxWidth: .infinity)
                    .scaledPadding(.vertical, 12)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Writes to support about this flight")
            if copied {
                Text(DetailFacts.reportCopied)
                    .scaledFont(14)
                    .foregroundStyle(Theme.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }
}

// MARK: - Wording

enum DetailFacts {
    static let reportLabel = "Report a Data Issue"
    static let supportAddress = "support@somalabs.me"
    /// Shown when no mail app opened the report.
    static let reportCopied = "No mail app found. We copied support@somalabs.me for you."

    /// "3 updates for this flight".
    static func updatesLine(_ count: Int) -> String {
        "\(count) \(count == 1 ? "update" : "updates") for this flight"
    }

    /// A mail to support about this flight: "Soma Flight data issue: UA990 2026-10-30", with the day it
    /// leaves in the origin's zone.
    static func reportURL(_ f: Flight, origin: TimeZone = .gmt) -> URL {
        var subject = "Soma Flight data issue: \(f.ident)"
        if let out = f.scheduledOut ?? f.estimatedOut ?? f.actualOut {
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = origin
            let c = cal.dateComponents([.year, .month, .day], from: out)
            subject += String(format: " %04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
        }
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let encoded = subject.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        return URL(string: "mailto:\(supportAddress)?subject=\(encoded)")!
    }

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
        let s = FlightDetailStore(id: flight.id, flights: flights, airports: airports, history: FakeHistoryService(),
                                  insights: FakeInsightsService(flights: flights))
        if mode == .failed { await flights.setNextError(.providerUnavailable) }
        await s.load()
        await s.loadExtras()
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
