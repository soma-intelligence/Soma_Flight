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

    private static func words(_ value: String.LocalizationValue) -> String {
        String(localized: value, bundle: .main)
    }

    /// "On Time", "25m Late", "10m Early", "In the Air", "Canceled": from format keys in the app's catalog,
    /// so it reads in the user's language (A1).
    var statusText: String {
        switch level {
        case .canceled: return Self.words("Canceled")
        case .diverted: return Self.words("Diverted")
        case .late, .veryLate:
            let span = Format.minutes(Format.minutes(delay ?? .zero))
            return Self.words("\(span) Late")
        case .onTime:
            switch flight.status {
            case .landed: return Self.words("Landed")
            case .arrived: return Self.words("Arrived")
            case .departed, .enRoute: return isArrival ? Self.words("In the Air") : Self.words("Departed")
            default:
                if let d = delay, Format.minutes(d) <= -5 {
                    let span = Format.minutes(Format.minutes(d))
                    return Self.words("\(span) Early")
                }
                return Self.words("On Time")
            }
        }
    }

    private var gateLine: String? {
        if isArrival { return flight.baggageBelt.map { belt in Self.words("Belt \(belt)") } ?? flight.gateDestination }
        return flight.gateOrigin
    }

    /// The schedule moved by a minute or more: the scheduled time is struck through and the real one shown.
    private var changed: Bool {
        guard let scheduled, let best else { return false }
        return abs(best.timeIntervalSince(scheduled)) >= 60
    }

    /// What VoiceOver reads (A10): "AF 84, Paris, 25m Late, scheduled 18:25, now 18:41, gate F11". Says
    /// which time is the schedule and which the real one, instead of reading two bare times.
    var spokenText: String {
        var parts = [Format.ident(flight.ident), place, statusText]
        if let scheduled {
            let planned = Format.clock(scheduled, timeZone, units.clock)
            if changed, let best, level != .canceled {
                let now = Format.clock(best, timeZone, units.clock)
                parts.append(Self.words("scheduled \(planned), now \(now)"))
            } else {
                parts.append(Self.words("scheduled \(planned)"))
            }
        }
        if isArrival, let belt = flight.baggageBelt {
            parts.append(Self.words("Belt \(belt)"))
        } else if let gate = isArrival ? flight.gateDestination : flight.gateOrigin, !gate.isEmpty {
            parts.append(Self.words("gate \(gate)"))
        }
        return parts.joined(separator: ", ")
    }

    @ScaledMetric(relativeTo: .body) private var timeColumn: CGFloat = 84

    public var body: some View {
        HStack(alignment: .top, spacing: 0) {
            times
                .frame(width: timeColumn, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(ui: place)
                    .scaledFont(16.5)
                    .foregroundStyle(Theme.primary)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Circle().fill(level.color).frame(width: 8, height: 8)
                    Text(ui: statusText)
                        .scaledFont(14.5)
                        .foregroundStyle(level == .onTime || level == .canceled ? Theme.secondary : level.textColor)
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: spokenText))
    }

    @ViewBuilder private var times: some View {
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
                    .foregroundStyle(level.textColor)
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
