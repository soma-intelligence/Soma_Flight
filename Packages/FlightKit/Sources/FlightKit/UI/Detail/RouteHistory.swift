import SwiftUI

/// What the user has flown between the flight's two airports, both directions together, canceled
/// flights left out.
struct RouteHistory: Equatable, Sendable {
    var flights: Int
    var distanceKm: Int
    /// Block minutes added up; a flight without a block time adds nothing.
    var minutes: Int
    /// The newest two, newest first.
    var recent: [PastFlight]

    static let title = "Your history on this route"

    /// nil when the user never flew the route. `excluding` is the flight on screen: once it is in the
    /// user's past (same flight number, leaving within 24 hours of its schedule) it does not count, so the
    /// card stays about the other times.
    static func compute(_ past: [PastFlight], origin: String, destination: String,
                        excluding current: Flight? = nil) -> RouteHistory? {
        let ends: Set = [origin, destination]
        let route = past.filter {
            $0.status != .canceled && Set([$0.originIcao, $0.destinationIcao]) == ends && $0.originIcao != $0.destinationIcao
                && !isSameFlight($0, current)
        }
        guard !route.isEmpty else { return nil }
        return RouteHistory(flights: route.count,
                            distanceKm: route.reduce(0) { $0 + $1.distanceKm },
                            minutes: route.reduce(0) { $0 + ($1.blockMinutes ?? 0) },
                            recent: Array(route.sorted { $0.date > $1.date }.prefix(2)))
    }

    private static func isSameFlight(_ p: PastFlight, _ f: Flight?) -> Bool {
        guard let f, p.ident.uppercased() == f.ident.uppercased(),
              let out = f.scheduledOut ?? f.estimatedOut ?? f.actualOut else { return false }
        return abs(p.date.timeIntervalSince(out)) < 86_400
    }

    /// "SFO → CDG", in the direction of the flight on screen.
    static func subtitle(from: String, to: String) -> String { "\(from) → \(to)" }

    /// "F-GZND · Boeing 777-300ER", whichever of the two is known.
    static func detail(_ p: PastFlight) -> String {
        [p.registration, p.aircraftType.map(TravelFacts.aircraftName)].compactMap { $0 }.joined(separator: " · ")
    }
}

/// The history card: flights, distance and flight time on the route, then the two most recent flights.
struct RouteHistoryCard: View {
    var history: RouteHistory
    var from: String
    var to: String
    @Environment(\.reference) private var reference
    @Environment(\.units) private var units
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        DetailCard {
            CardTitle(RouteHistory.title, subtitle: RouteHistory.subtitle(from: from, to: to))
            let layout = typeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
                : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
            layout {
                figure("Flights", symbol: "airplane.departure", value: "\(history.flights)")
                figure("Distance", symbol: "arrow.up.right.circle.fill", value: distance)
                figure("Flight Time", symbol: "clock", value: DetailFacts.span(minutes: history.minutes))
            }
            .scaledPadding(.top, 18)
            Text("Most recent flights")
                .scaledFont(16, weight: .medium)
                .foregroundStyle(Theme.secondary)
                .scaledPadding(.top, 18)
                .scaledPadding(.bottom, 6)
            ForEach(Array(history.recent.enumerated()), id: \.element.id) { index, p in
                if index > 0 { Hairline().scaledPadding(.leading, 58) }
                row(p)
            }
        }
    }

    private var distance: String {
        let value = units.distance == .mi ? Int((Double(history.distanceKm) / 1.609_344).rounded()) : history.distanceKm
        return "\(value.formatted(.number.locale(Locale(identifier: "en_US")))) \(units.distance.rawValue)"
    }

    private func figure(_ label: String, symbol: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).scaledFont(16, weight: .medium).foregroundStyle(Theme.secondary)
            HStack(spacing: 6) {
                Image(systemName: symbol).scaledFont(17, weight: .semibold).accessibilityHidden(true)
                Text(value).scaledFont(19).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            }
            .foregroundStyle(Theme.primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func row(_ p: PastFlight) -> some View {
        let airline = p.airline.flatMap { reference.airline($0) } ?? reference.airline(ident: p.ident)
        let tz = p.originTz.flatMap(TimeZone.init(identifier:)) ?? .gmt
        return HStack(alignment: .center, spacing: 14) {
            AirlineLogo(airline: airline, code: airline?.id ?? TravelFacts.airlineCode(ident: p.ident), size: 40,
                        decorative: true)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(ScreenFormat.day(p.date, tz)).scaledFont(20, weight: .semibold)
                    Spacer(minLength: 8)
                    Text(Format.ident(p.ident)).scaledFont(20, weight: .semibold)
                }
                .foregroundStyle(Theme.primary)
                HStack(alignment: .firstTextBaseline) {
                    Text(p.blockMinutes.map(DetailFacts.span(minutes:)) ?? "--")
                    Spacer(minLength: 8)
                    Text(RouteHistory.detail(p)).lineLimit(1).minimumScaleFactor(0.8)
                }
                .scaledFont(16)
                .foregroundStyle(Theme.secondary)
            }
        }
        .scaledPadding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }
}
