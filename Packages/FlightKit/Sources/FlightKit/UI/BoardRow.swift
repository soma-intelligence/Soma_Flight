import SwiftUI

/// One line of a departures or arrivals board: struck schedule over the real time, the other
/// end's city with a coloured status, and the flight number with gate (or belt) on the right.
public struct BoardRow: View {
    @Environment(\.units) private var units
    var flight: Flight
    var kind: BoardKind
    var airport: Airport?
    var timeZone: TimeZone
    var now: Date
    var striped: Bool

    /// - Parameters:
    ///   - airport: the other end of the flight (destination on departures, origin on arrivals), for its city.
    ///   - timeZone: the board airport's zone; times show as local wall clock.
    ///   - striped: alternate rows use a lighter fill.
    public init(flight: Flight, kind: BoardKind, airport: Airport?, timeZone: TimeZone = .current,
                now: Date = .now, striped: Bool = false) {
        self.flight = flight; self.kind = kind; self.airport = airport
        self.timeZone = timeZone; self.now = now; self.striped = striped
    }

    private var isArrival: Bool { kind == .arrivals }
    private var scheduled: Date? { isArrival ? flight.scheduledIn : flight.scheduledOut }
    private var best: Date? {
        isArrival ? (flight.actualIn ?? flight.actualOn ?? flight.estimatedIn) : (flight.actualOut ?? flight.estimatedOut)
    }
    private var delay: Duration? { isArrival ? flight.arrivalDelay : flight.departureDelay }
    private var level: DelayLevel { DelayLevel.for(delay: delay, status: flight.status) }

    private var place: String {
        airport?.city ?? (isArrival ? flight.originCode : flight.destinationCode)
    }

    private var statusText: String {
        switch level {
        case .canceled: return "Canceled"
        case .diverted: return "Diverted"
        case .late, .veryLate: return "\(Format.minutes(Format.minutes(delay ?? .zero))) Late"
        case .onTime:
            switch flight.status {
            case .landed: return "Landed"
            case .arrived: return "Arrived"
            case .departed, .enRoute: return isArrival ? "In the Air" : "Departed"
            default:
                if let d = delay, Format.minutes(d) <= -5 { return "\(Format.minutes(Format.minutes(d))) Early" }
                return "On Time"
            }
        }
    }

    private var gateLine: String? {
        if isArrival { return flight.baggageBelt.map { "Belt \($0)" } ?? flight.gateDestination }
        return flight.gateOrigin
    }

    @ScaledMetric(relativeTo: .body) private var timeColumn: CGFloat = 84

    public var body: some View {
        HStack(alignment: .top, spacing: 0) {
            times
                .frame(width: timeColumn, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(place)
                    .scaledFont(16.5)
                    .foregroundStyle(Theme.primary)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Circle().fill(level.color).frame(width: 8, height: 8)
                    Text(statusText)
                        .scaledFont(14.5)
                        .foregroundStyle(level == .onTime || level == .canceled ? Theme.secondary : level.color)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 3) {
                Text(Format.ident(flight.ident))
                    .scaledFont(15.5)
                    .foregroundStyle(Theme.primary)
                Text(gateLine ?? " ")
                    .scaledFont(15)
                    .foregroundStyle(Theme.secondary)
            }
        }
        .monospacedDigit()
        .scaledPadding(.horizontal, 16)
        .scaledPadding(.vertical, 7)
        .frame(minHeight: 54)
        .background(striped ? Theme.rowAlt : Theme.background)
        // Three fixed columns: past accessibility2 the row would truncate the city.
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var times: some View {
        let changed = scheduled != nil && best != nil && abs(best!.timeIntervalSince(scheduled!)) >= 60
        VStack(alignment: .leading, spacing: 2) {
            if let scheduled {
                Text(Format.clock(scheduled, timeZone, units.clock))
                    .scaledFont(16.5, weight: .medium)
                    .strikethrough(changed || level == .canceled, color: Theme.secondary)
                    .foregroundStyle(changed || level == .canceled ? Theme.secondary : Theme.primary)
            }
            if changed, let best, level != .canceled {
                Text(Format.clock(best, timeZone, units.clock))
                    .scaledFont(15.5, weight: .medium)
                    .foregroundStyle(level == .onTime ? Theme.onTime : level.color)
            }
        }
    }
}

#if DEBUG
#Preview("Departures") {
    let board = PreviewData.board("KAUS", .departures)
    ScrollView {
        LazyVStack(spacing: 0) {
            ForEach(Array(board.flights.enumerated()), id: \.element.id) { i, f in
                BoardRow(flight: f, kind: .departures, airport: PreviewData.airport(f.destinationIcao),
                         timeZone: PreviewData.kaus.timeZone, now: PreviewData.now, striped: i.isMultiple(of: 2) == false)
            }
        }
    }
    .background(Theme.background)
    .preferredColorScheme(.dark)
}

#Preview("Sparse") {
    BoardRow(flight: PreviewData.sparse, kind: .departures, airport: nil)
        .preferredColorScheme(.dark)
}
#endif
