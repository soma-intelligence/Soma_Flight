import SwiftUI

/// What the "Other flights" card does with a flight it just followed.
struct FollowedAlternateAction {
    var run: @MainActor (Flight) async -> Void
}

extension EnvironmentValues {
    /// Opens a flight the user just followed from the "Other flights" card (the shell shows it and says
    /// so); nil leaves the sheet where it is once the follow worked.
    @Entry var followedAlternate: FollowedAlternateAction?
}

extension View {
    /// What the "Other flights" card does once it followed a flight: the shell opens it.
    public func onFollowedAlternate(_ action: @escaping @MainActor (Flight) async -> Void) -> some View {
        environment(\.followedAlternate, FollowedAlternateAction(run: action))
    }
}

/// The flight sheet's Connection Assistant: a Connection card for each followed flight this one connects
/// with, then, when the flight is canceled or a connection is at risk, the other direct flights on the
/// route later that day. The loading lives in `connectionUpdates`, on the sheet, so a flight with neither
/// card leaves no gap in the sheet.
struct ConnectionSections: View {
    var store: ConnectionStore
    var flight: Flight
    var now: Date
    @Environment(\.units) private var units
    @Environment(\.followedAlternate) private var followedAlternate

    /// True when there is a card to draw.
    static func isShown(_ store: ConnectionStore, flight: Flight, now: Date) -> Bool {
        !store.connections.isEmpty || store.alternateRequest(for: flight, now: now) != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(store.connections) { c in
                ConnectionCard(connection: c, assessment: store.assessment(c))
            }
            if let request = store.alternateRequest(for: flight, now: now) {
                AlternateFlightsCard(request: request, store: store, lookup: store.lookup(_:), clock: units.clock,
                                     onFollow: follow)
            }
        }
    }

    private func follow(_ alt: AlternateFlight) {
        Task {
            guard let f = await store.follow(alt) else { return }
            await followedAlternate?.run(f)
        }
    }
}

extension View {
    /// Runs the Connection Assistant for the sheet's flight: finds its connections and follows both flights of
    /// each (`ConnectionStore.run`), so the verdict moves with every new estimate; feeds in the sheet's own
    /// copy of the flight as it reloads; asks for other flights whenever the request moves; says when a follow
    /// from the "Other flights" card failed. Nothing for a nil store (a Passport flight).
    func connectionUpdates(_ store: ConnectionStore?, flight: Flight, now: Date) -> some View {
        modifier(ConnectionUpdates(store: store, flight: flight, now: now))
    }
}

private struct ConnectionUpdates: ViewModifier {
    var store: ConnectionStore?
    var flight: Flight
    var now: Date

    func body(content: Content) -> some View {
        if let store {
            let request = store.alternateRequest(for: flight, now: now)
            content
                .task(id: flight.id) { await store.run(flight: flight) }
                .task(id: request) { await store.loadAlternates(request) }
                .onChange(of: flight) { _, f in store.apply(f) }
                .alert("Could Not Follow", isPresented: Binding(
                    get: { store.followError != nil },
                    set: { if !$0 { store.clearFollowError() } })) {
                    Button("OK", role: .cancel) { store.clearFollowError() }
                } message: {
                    Text(store.followError.map(ConnectionCopy.followFailed) ?? "")
                }
        } else {
            content
        }
    }
}

/// One connection: the verdict and layover, why, the two gates, what the airport usually asks for this kind
/// of connection, and the steps between the gates with their typical minutes.
struct ConnectionCard: View {
    var connection: Connection
    var assessment: ConnectionAssessment

    var body: some View {
        let a = assessment
        DetailCard {
            CardTitle(ConnectionCopy.title, subtitle: ConnectionCopy.subtitle(connection))
            verdict(a).scaledPadding(.top, 16)
            Text(ConnectionCopy.caption(connection, a))
                .scaledFont(15)
                .foregroundStyle(Theme.primary.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
                .scaledPadding(.top, 8)
            gates(a).scaledPadding(.top, 16)
            VStack(spacing: 0) {
                fact("Connection", ConnectionCopy.kind(a))
                fact(ConnectionCopy.mctLabel(a), Format.minutes(a.mctMinutes))
                fact("Terminal change", ConnectionCopy.terminalChange(a))
                fact("Passport control", ConnectionCopy.passport(a))
                fact("Security again", ConnectionCopy.security(a))
            }
            .scaledPadding(.top, 12)
            steps(a).scaledPadding(.top, 16)
        }
        .id("connection")
    }

    private func verdict(_ a: ConnectionAssessment) -> some View {
        HStack(alignment: .firstTextBaseline) {
            HStack(spacing: 8) {
                Circle().fill(ConnectionCopy.color(a.verdict)).frame(width: 10, height: 10).accessibilityHidden(true)
                Text(ConnectionCopy.verdict(a.verdict))
                    .scaledFont(22, weight: .bold)
                    .foregroundStyle(ConnectionCopy.color(a.verdict))
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(ConnectionCopy.layover(a)).scaledFont(22, weight: .semibold).monospacedDigit()
                    .foregroundStyle(Theme.primary)
                Text("Layover").scaledFont(13, weight: .medium).foregroundStyle(Theme.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func gates(_ a: ConnectionAssessment) -> some View {
        HStack(alignment: .top, spacing: 10) {
            place("Arrive", Format.ident(connection.arriving.ident),
                  ConnectionCopy.place(terminal: a.arrivalTerminal, gate: a.arrivalGate))
            Image(systemName: "arrow.right").scaledFont(15, weight: .semibold).foregroundStyle(Theme.secondary)
                .scaledPadding(.top, 20)
                .accessibilityHidden(true)
            place("Depart", Format.ident(connection.departing.ident),
                  ConnectionCopy.place(terminal: a.departureTerminal, gate: a.departureGate))
        }
    }

    private func place(_ label: String, _ ident: String, _ where_: String?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("\(label) · \(ident)").scaledFont(13, weight: .medium).foregroundStyle(Theme.secondary)
            Text(where_ ?? "Gate not known yet")
                .scaledFont(17, weight: .semibold)
                .foregroundStyle(where_ == nil ? Theme.secondary : Theme.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .scaledPadding(.all, 12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.pill.opacity(0.6)))
        .accessibilityElement(children: .combine)
    }

    private func fact(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).scaledFont(15).foregroundStyle(Theme.secondary)
            Spacer(minLength: 12)
            Text(value).scaledFont(15, weight: .medium).foregroundStyle(Theme.primary).multilineTextAlignment(.trailing)
        }
        .scaledPadding(.vertical, 7)
        .accessibilityElement(children: .combine)
    }

    private func steps(_ a: ConnectionAssessment) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(ConnectionCopy.stepsTotal(a)).scaledFont(15, weight: .semibold).foregroundStyle(Theme.primary)
                .scaledPadding(.bottom, 6)
            ForEach(Array(a.steps.enumerated()), id: \.offset) { _, s in
                HStack(spacing: 12) {
                    Image(systemName: ConnectionCopy.stepIcon(s))
                        .scaledFont(15, weight: .semibold)
                        .foregroundStyle(Theme.secondary)
                        .frame(width: 24)
                        .accessibilityHidden(true)
                    Text(ConnectionCopy.step(s)).scaledFont(15).foregroundStyle(Theme.primary)
                    Spacer(minLength: 8)
                    Text(Format.minutes(s.minutes)).scaledFont(15, weight: .medium).monospacedDigit()
                        .foregroundStyle(Theme.secondary)
                }
                .scaledPadding(.vertical, 6)
                .accessibilityElement(children: .combine)
            }
        }
    }
}

/// "Other flights to SFO today": direct flights on the route in the request's window, each with its times
/// at the two airports and its status. Tapping one follows it.
struct AlternateFlightsCard: View {
    var request: AlternateRequest
    var store: ConnectionStore
    var lookup: (String) -> Airport?
    var clock: TimeStyle
    var onFollow: (AlternateFlight) -> Void

    var body: some View {
        DetailCard {
            CardTitle(ConnectionCopy.alternatesTitle(request), subtitle: ConnectionCopy.alternatesSubtitle)
            VStack(spacing: 0) {
                if store.alternates.isEmpty {
                    if store.alternatesLoaded {
                        Text(ConnectionCopy.alternatesEmpty).scaledFont(15).foregroundStyle(Theme.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .scaledPadding(.vertical, 8)
                    } else {
                        ProgressView().frame(maxWidth: .infinity).scaledPadding(.vertical, 12)
                    }
                }
                ForEach(store.alternates) { f in
                    Button { onFollow(f) } label: { row(f) }
                        .buttonStyle(.plain)
                        .disabled(store.pending != nil)
                    if f.id != store.alternates.last?.id { Hairline() }
                }
            }
            .scaledPadding(.top, 12)
            Text(ConnectionCopy.alternatesFootnote).scaledFont(13).foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .scaledPadding(.top, 10)
        }
        .id("alternates")
    }

    private func row(_ f: AlternateFlight) -> some View {
        let status = ConnectionCopy.alternateStatus(f)
        let out = Format.clock(f.bestOut, lookup(f.originIata)?.timeZone ?? .gmt, clock)
        let arrive = Format.clock(f.bestIn, lookup(f.destinationIata)?.timeZone ?? .gmt, clock)
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(Format.ident(f.ident)).scaledFont(17, weight: .semibold).foregroundStyle(Theme.primary)
                Text("\(out) to \(arrive)").scaledFont(15).monospacedDigit().foregroundStyle(Theme.secondary)
            }
            Spacer(minLength: 8)
            if store.pending == f.id {
                ProgressView().controlSize(.small)
            } else {
                Text(status.text).scaledFont(15, weight: .medium).foregroundStyle(status.color)
                Image(systemName: "plus.circle").scaledFont(17).foregroundStyle(Theme.accent).accessibilityHidden(true)
            }
        }
        .scaledPadding(.vertical, 10)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Follows this flight")
    }
}
