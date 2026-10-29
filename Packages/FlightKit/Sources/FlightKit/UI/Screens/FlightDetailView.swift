import SwiftUI

/// One followed flight in full: chips and route title, the card with times and progress, a
/// canceled or diverted notice, the timeline, gates and terminals, the aircraft, what changed,
/// and both airports as links to their sheets. The map arc and live plane belong to the shell.
public struct FlightDetailView: View {
    var store: FlightDetailStore
    var onAirport: (String) -> Void
    var fixedNow: Date?
    var scrolls: Bool

    /// - Parameters:
    ///   - onAirport: opens the airport sheet for an ICAO code.
    ///   - now: a fixed clock for previews; nil follows the real time.
    public init(store: FlightDetailStore, onAirport: @escaping (String) -> Void, now: Date? = nil) {
        self.init(store: store, onAirport: onAirport, now: now, scrolls: true)
    }

    init(store: FlightDetailStore, onAirport: @escaping (String) -> Void, now: Date?, scrolls: Bool) {
        self.store = store; self.onAirport = onAirport; self.fixedNow = now; self.scrolls = scrolls
    }

    public var body: some View {
        ClockView(fixed: fixedNow) { now in
            VStack(spacing: 0) {
                if let flight = store.flight {
                    FlightHeader(flight: flight, origin: store.origin, destination: store.destination)
                        .padding(.horizontal, Theme.gutter)
                        .padding(.top, 18)
                        .padding(.bottom, 12)
                    Hairline()
                    ScreenScroll(scrolls: scrolls) { sections(flight, now: now) }
                } else if let error = store.error {
                    ErrorBanner(error: error, retry: reload)
                        .padding(16)
                    Spacer(minLength: 0)
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .background(Theme.background)
    }

    private func reload() { Task { await store.load() } }

    /// Live flights go stale after 5 minutes, the rest after an hour.
    static func ttl(_ f: Flight) -> Duration {
        f.status == .departed || f.status == .enRoute ? .seconds(300) : .seconds(3600)
    }

    private func sections(_ flight: Flight, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                if let error = store.error {
                    ErrorBanner(error: error, retry: reload)
                }
                SectionFreshness(fetchedAt: flight.updatedAt, ttl: Self.ttl(flight), now: now)
                if let notice = notice(flight) { notice }
                FlightCard(flight: flight, origin: store.origin, destination: plannedDestination(flight), now: now)
                if let line = DetailFacts.progressLine(flight, now: now) {
                    Text(line)
                        .scaledFont(13, weight: .medium)
                        .foregroundStyle(Theme.secondary)
                        .padding(.horizontal, 4)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)

            section {
                SectionHeader("Timeline", subtitle: "Local times at each airport")
                    .padding(.bottom, 16)
                FlightTimeline(flight: flight, origin: store.origin, destination: plannedDestination(flight), now: now)
            }
            section {
                SectionHeader("Gates and Terminals", subtitle: "Updated as the airline posts them")
                    .padding(.bottom, 16)
                GatesGrid(flight: flight)
            }
            section {
                SectionHeader("Aircraft")
                    .padding(.bottom, 12)
                AircraftRow(type: flight.aircraftType, registration: flight.registration)
            }
            if !store.events.isEmpty {
                section {
                    SectionHeader("Changes", subtitle: "What moved since you started tracking")
                        .padding(.bottom, 8)
                    ForEach(store.events.reversed()) { e in
                        EventRow(event: e, timeZone: store.origin?.timeZone ?? .current)
                    }
                }
            }
            section {
                SectionHeader("Airports")
                    .padding(.bottom, 4)
                AirportLinkRow(role: "Departure", code: flight.originIcao, airport: store.origin, tag: nil) {
                    onAirport(store.origin?.id ?? flight.originIcao)
                }
                Hairline(leading: 52)
                if flight.status == .diverted, let diverted = store.destination, diverted.id != flight.destinationIcao {
                    AirportLinkRow(role: "Diverted to", code: diverted.id, airport: diverted, tag: "Diverted") {
                        onAirport(diverted.id)
                    }
                    Hairline(leading: 52)
                    AirportLinkRow(role: "Planned arrival", code: flight.destinationIcao, airport: nil,
                                   iata: flight.destinationIata, tag: nil) {
                        onAirport(flight.destinationIcao)
                    }
                } else {
                    AirportLinkRow(role: "Arrival", code: flight.destinationIcao, airport: store.destination,
                                   iata: flight.destinationIata, tag: nil) {
                        onAirport(store.destination?.id ?? flight.destinationIcao)
                    }
                }
            }
        }
        .padding(.bottom, 32)
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
            .padding(.horizontal, Theme.gutter)
            .padding(.vertical, 22)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .top) { Hairline() }
    }
}

// MARK: - Pieces

/// Chips (flight number, aircraft, day), "Paris to San Francisco", airline and status in caps.
struct FlightHeader: View {
    var flight: Flight
    var origin: Airport?
    var destination: Airport?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                CodeChip(Format.ident(flight.ident))
                if let type = flight.aircraftType { CodeChip(type) }
                if let out = flight.scheduledOut {
                    CodeChip(ScreenFormat.chipDay(out, origin?.timeZone ?? .current).uppercased())
                }
            }
            .padding(.bottom, 6)
            Text(ScreenFormat.route(origin?.city ?? flight.originCode, destination?.city ?? flight.destinationCode))
                .font(Theme.Font.sheetTitle)
                .foregroundStyle(Theme.primary)
                .lineLimit(2)
            Text(DetailFacts.caption(flight).uppercased())
                .scaledFont(13, weight: .medium)
                .foregroundStyle(Theme.secondary)
                .lineLimit(1)
                .padding(.top, 3)
        }
        .padding(.trailing, 60)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

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
            .padding(.top, 3)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).scaledFont(17, weight: .semibold).foregroundStyle(Theme.primary)
                Text(text).scaledFont(15).foregroundStyle(Theme.primary.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(color.opacity(0.16)))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(color.opacity(0.35), lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}

/// Departure and arrival terminal, gate and belt, "TBA" until known.
struct GatesGrid: View {
    var flight: Flight

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 18) {
            GridRow {
                side("Departure", flight.originCode)
                cell("Terminal", flight.terminalOrigin)
                cell("Gate", flight.gateOrigin)
                Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
            }
            GridRow {
                side("Arrival", flight.destinationCode)
                cell("Terminal", flight.terminalDestination)
                cell("Gate", flight.gateDestination)
                cell("Belt", flight.baggageBelt)
            }
        }
        .monospacedDigit()
    }

    private func side(_ title: String, _ code: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title.uppercased()).scaledFont(12, weight: .medium).foregroundStyle(Theme.secondary)
            Text(code).scaledFont(22, weight: .semibold).foregroundStyle(Theme.primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func cell(_ label: String, _ value: String?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased()).scaledFont(12, weight: .medium).foregroundStyle(Theme.secondary)
            Text(value ?? "TBA")
                .scaledFont(22, weight: .semibold)
                .foregroundStyle(value == nil ? Theme.secondary.opacity(0.7) : Theme.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

struct AircraftRow: View {
    var type: String?
    var registration: String?

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "airplane")
                .scaledFont(18, weight: .semibold)
                .foregroundStyle(Theme.primary)
                .frame(width: 40, height: 40)
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

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Text(airport?.iata ?? iata ?? code)
                    .scaledFont(15, weight: .bold)
                    .foregroundStyle(Theme.primary)
                    .frame(width: 40, height: 40)
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
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens the airport")
    }
}

/// One change seen on the flight, newest first.
struct EventRow: View {
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
                Text(Format.clock(event.receivedAt, timeZone))
                    .scaledFont(14)
                    .monospacedDigit()
                    .foregroundStyle(Theme.secondary)
            }
            .padding(.vertical, 8)
            .accessibilityElement(children: .combine)
        }
    }
}

// MARK: - Wording

enum DetailFacts {
    /// "Air France  ·  In the air" style caption under the title.
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
            return "Landed \(ScreenFormat.span(now.timeIntervalSince(at))) ago"
        case .departed, .enRoute:
            guard let end = f.actualIn ?? f.estimatedIn ?? f.scheduledIn, end > now else { return nil }
            return "Arrives in \(ScreenFormat.span(end.timeIntervalSince(now)))"
        case .scheduled:
            guard let out = f.actualOut ?? f.estimatedOut ?? f.scheduledOut, out > now else { return nil }
            return "Leaves the gate in \(ScreenFormat.span(out.timeIntervalSince(now)))"
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

// MARK: - Previews

/// Loads a detail store from the seed at the seed's own clock.
struct FlightDetailPreview: View {
    enum Mode { case enRoute, sparse, canceled, diverted, error, stale, failed }
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
#Preview("Failed, nothing to show") { FlightDetailPreview(mode: .failed).preferredColorScheme(.light) }
