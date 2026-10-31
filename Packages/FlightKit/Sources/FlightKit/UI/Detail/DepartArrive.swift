import CoreLocation
import SwiftUI

// MARK: - Wording

extension DetailFacts {
    /// The arrival's local date against the departure's: "+1", "+2", "-1" (east to west over the date
    /// line), nil on the same local date. Each side is read in its own airport's zone.
    static func dayMarker(departure: Date, depTz: TimeZone, arrival: Date, arrTz: TimeZone) -> String? {
        let days = localDayNumber(arrival, arrTz) - localDayNumber(departure, depTz)
        guard days != 0 else { return nil }
        return days > 0 ? "+\(days)" : "\(days)"
    }

    /// True when the flight lands on a later local date than it leaves.
    static func isOvernight(departure: Date, depTz: TimeZone, arrival: Date, arrTz: TimeZone) -> Bool {
        localDayNumber(arrival, arrTz) > localDayNumber(departure, depTz)
    }

    /// Days since the epoch of the date `date` falls on in `tz`.
    private static func localDayNumber(_ date: Date, _ tz: TimeZone) -> Int {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        let c = cal.dateComponents([.year, .month, .day], from: date)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = .gmt
        let midnight = utc.date(from: c) ?? date
        return Int((midnight.timeIntervalSince1970 / 86_400).rounded(.down))
    }

    /// The word under a big time: "Actual" once it happened, "Estimated" when the estimate is a minute
    /// or more off the schedule (or there is no schedule), else "Scheduled".
    static func timeWord(scheduled: Date?, estimated: Date?, actual: Date?) -> String {
        if actual != nil { return "Actual" }
        if let estimated {
            guard let scheduled else { return "Estimated" }
            if abs(estimated.timeIntervalSince(scheduled)) >= 60 { return "Estimated" }
        }
        return "Scheduled"
    }

    /// How a side runs against its schedule, in whole minutes (positive late), from the actual time
    /// else the estimate; nil while only the schedule is known.
    static func offsetMinutes(scheduled: Date?, estimated: Date?, actual: Date?) -> Int? {
        guard let scheduled, let best = actual ?? estimated else { return nil }
        return Int((best.timeIntervalSince(scheduled) / 60).rounded())
    }

    /// The word under a big time once there is an estimate or an actual: "3m Late", "32m Early",
    /// "On Time"; nil while only the schedule is known (the view then says `timeWord`).
    static func offsetWord(_ minutes: Int?) -> String? {
        guard let minutes else { return nil }
        if minutes >= 1 { return "\(span(minutes: minutes)) Late" }
        if minutes <= -1 { return "\(span(minutes: -minutes)) Early" }
        return "On Time"
    }

    /// "SFO · San Francisco Intl.": the code and a shortened airport name.
    static func airportLine(code: String, airport: Airport?) -> String {
        guard let airport else { return code }
        return "\(airport.iata ?? code) · \(shortName(airport.name))"
    }

    /// "San Francisco International" as "San Francisco Intl.", without a trailing "Airport".
    static func shortName(_ name: String) -> String {
        var n = name
        for suffix in [" Airport", " airport"] where n.hasSuffix(suffix) { n.removeLast(suffix.count) }
        for (long, short) in [(" International", " Intl."), (" Intercontinental", " Intercont.")] where n.hasSuffix(long) {
            n.removeLast(long.count)
            n += short
        }
        return n
    }

    /// Departure and arrival as best known: actual, else estimated, else scheduled gate times.
    static func bestOut(_ f: Flight) -> Date? { f.actualOut ?? f.estimatedOut ?? f.scheduledOut }
    static func bestIn(_ f: Flight) -> Date? { f.actualIn ?? f.estimatedIn ?? f.scheduledIn }

    /// Great-circle distance between the two airports in whole kilometres; nil when either is unknown.
    static func distanceKm(origin: Airport?, destination: Airport?) -> Int? {
        guard let o = origin, let d = destination else { return nil }
        let km = FlightKit.distanceKm(CLLocationCoordinate2D(latitude: o.lat, longitude: o.lon),
                                      CLLocationCoordinate2D(latitude: d.lat, longitude: d.lon))
        return Int(km.rounded())
    }

    /// "10h 55m · 8,965 km · Overnight": gate to gate, the distance in the user's unit, and whether it
    /// lands on a later local date. Missing parts drop out; nil when nothing is known.
    static func middleLine(_ f: Flight, origin: Airport?, destination: Airport?, unit: DistanceUnit) -> String? {
        var parts: [String] = []
        let out = bestOut(f), arr = bestIn(f)
        if let out, let arr, arr > out { parts.append(span(minutes: Int(arr.timeIntervalSince(out) / 60))) }
        if let km = distanceKm(origin: origin, destination: destination) { parts.append(TravelFacts.distance(km, unit)) }
        if let out, let arr, let o = origin, let d = destination,
           isOvernight(departure: out, depTz: o.timeZone, arrival: arr, arrTz: d.timeZone) {
            parts.append("Overnight")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

// MARK: - Block

/// Departure and arrival, each with its airport as a link, the big local time, the word saying which
/// time it is, the gate badge and the terminal; between them the duration, distance and overnight line.
struct DepartArrive: View {
    var flight: Flight
    var origin: Airport?
    var destination: Airport?
    var now: Date
    var onAirport: (String) -> Void = { _ in }
    /// The likely departure gate while none is assigned (`FlightDetailStore.gatePrediction`).
    var predictedGate: GatePrediction? = nil
    @Environment(\.units) private var units
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let out = DetailFacts.bestOut(flight), arr = DetailFacts.bestIn(flight)
        // Both zones must be known: a guess from the phone's zone could show a wrong day.
        let marker: String? = if let out, let arr, let o = origin, let d = destination {
            DetailFacts.dayMarker(departure: out, depTz: o.timeZone, arrival: arr, arrTz: d.timeZone)
        } else { nil }
        VStack(alignment: .leading, spacing: 0) {
            side(arriving: false, code: flight.originCode, icao: flight.originIcao, airport: origin, time: out,
                 word: DetailFacts.timeWord(scheduled: flight.scheduledOut, estimated: flight.estimatedOut,
                                            actual: flight.actualOut),
                 scheduled: flight.scheduledOut,
                 offset: DetailFacts.offsetMinutes(scheduled: flight.scheduledOut, estimated: flight.estimatedOut,
                                                   actual: flight.actualOut),
                 gate: flight.gateOrigin, terminal: flight.terminalOrigin, belt: nil, marker: nil)
            middle
                .scaledPadding(.vertical, 18)
            side(arriving: true, code: flight.destinationCode, icao: flight.destinationIcao, airport: destination,
                 time: arr,
                 word: DetailFacts.timeWord(scheduled: flight.scheduledIn, estimated: flight.estimatedIn,
                                            actual: flight.actualIn),
                 scheduled: flight.scheduledIn,
                 offset: DetailFacts.offsetMinutes(scheduled: flight.scheduledIn, estimated: flight.estimatedIn,
                                                   actual: flight.actualIn ?? flight.actualOn),
                 gate: flight.gateDestination, terminal: flight.terminalDestination, belt: flight.baggageBelt,
                 marker: marker)
        }
    }

    @ViewBuilder private var middle: some View {
        let line = DetailFacts.middleLine(flight, origin: origin, destination: destination, unit: units.distance)
        HStack(spacing: 10) {
            if let line {
                HStack(spacing: 5) {
                    Image(systemName: line.hasSuffix("Overnight") ? "moon" : "clock")
                        .scaledFont(13, weight: .medium)
                        .accessibilityHidden(true)
                    Text(line)
                        .scaledFont(14, weight: .medium)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(Theme.secondary.opacity(0.85))
                .layoutPriority(1)
            }
            Rectangle().fill(Theme.separator).frame(height: 1).frame(maxWidth: .infinity)
        }
    }

    private func side(arriving: Bool, code: String, icao: String, airport: Airport?, time: Date?, word: String,
                      scheduled: Date?, offset: Int?, gate: String?, terminal: String?, belt: String?,
                      marker: String?) -> some View {
        let tz = airport?.timeZone ?? .current
        // Late in red, early or on time in green, white while only the schedule is known.
        let tone: Color = switch offset {
        case nil: Theme.primary
        case let m? where m >= 1: Theme.veryLate
        default: Theme.onTime
        }
        let status = DetailFacts.offsetWord(offset) ?? word
        let statusTone = offset == nil ? Theme.secondary : tone
        // The schedule, struck through beside the time, once the best time moved off it.
        let struck: String? = if let scheduled, let offset, offset != 0 {
            Format.clock(scheduled, tz, units.clock)
        } else { nil }
        return VStack(alignment: .leading, spacing: 4) {
            Button { onAirport(airport?.id ?? icao) } label: {
                HStack(spacing: 6) {
                    Image(systemName: arriving ? "arrow.down.right.circle.fill" : "arrow.up.right.circle.fill")
                        .scaledFont(15, weight: .semibold)
                        .accessibilityHidden(true)
                    Text(DetailFacts.airportLine(code: code, airport: airport))
                        .scaledFont(16, weight: .semibold)
                        .lineLimit(1)
                    Image(systemName: "chevron.right")
                        .scaledFont(14, weight: .semibold)
                        .accessibilityHidden(true)
                }
                .foregroundStyle(Theme.primary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(arriving ? "Arrival airport" : "Departure airport")
            .accessibilityValue(airport?.name ?? code)
            .accessibilityHint("Opens the airport")

            // Time and gate side by side; at accessibility sizes the gate and terminal go under the time
            // so the time keeps its size.
            let stacked = typeSize.isAccessibilitySize
            let terminalText = "Terminal \(terminal ?? "--")"
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .center) {
                    HStack(alignment: .lastTextBaseline, spacing: 6) {
                        HStack(alignment: .top, spacing: 2) {
                            Text(time.map { Format.clock($0, tz, units.clock) } ?? "--:--")
                                .scaledFont(40, weight: .semibold)
                                .monospacedDigit()
                                .foregroundStyle(time == nil ? Theme.secondary : tone)
                                .lineLimit(1)
                                .minimumScaleFactor(stacked ? 0.9 : 0.6)
                            if let marker {
                                Text(marker)
                                    .scaledFont(15, weight: .semibold)
                                    .foregroundStyle(tone)
                                    .accessibilityLabel(marker.hasPrefix("-") ? "previous day" : "\(marker) day")
                            }
                        }
                        if let struck {
                            Text(struck)
                                .scaledFont(15, weight: .medium)
                                .monospacedDigit()
                                .strikethrough()
                                .foregroundStyle(Theme.secondary)
                                .lineLimit(1)
                                .accessibilityLabel("scheduled \(struck)")
                        }
                    }
                    if !stacked {
                        Spacer(minLength: 12)
                        badges(gate: gate, belt: belt, arriving: arriving)
                    }
                }
                if stacked {
                    Text(status).scaledFont(14, weight: .medium).foregroundStyle(statusTone)
                    badges(gate: gate, belt: belt, arriving: arriving).scaledPadding(.top, 6)
                    Text(terminalText).scaledFont(14).foregroundStyle(Theme.secondary)
                } else {
                    HStack(alignment: .firstTextBaseline) {
                        Text(status)
                            .scaledFont(14, weight: offset == nil ? .regular : .medium)
                            .foregroundStyle(statusTone)
                        Spacer(minLength: 12)
                        Text(terminalText)
                            .scaledFont(14)
                            .foregroundStyle(Theme.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .accessibilityElement(children: .combine)
        }
    }

    /// The arrival's baggage belt (once known) beside the gate; before the departure gate is known, its
    /// likely value in the dashed guess style.
    @ViewBuilder private func badges(gate: String?, belt: String?, arriving: Bool) -> some View {
        HStack(spacing: 6) {
            if let belt { BeltBadge(belt: belt) }
            if gate == nil, !arriving, let guess = predictedGate?.badge {
                PredictedGateBadge(label: guess, arriving: arriving)
            } else {
                GateBadge(gate: gate, arriving: arriving)
            }
        }
    }
}

/// The baggage belt: a suitcase and the belt on the gate's yellow.
struct BeltBadge: View {
    var belt: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "suitcase.rolling.fill")
                .scaledFont(14, weight: .bold)
            Text(belt).scaledFont(18, weight: .bold)
        }
        .foregroundStyle(.black)
        .scaledPadding(.horizontal, 10)
        .scaledPadding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(GateBadge.yellow))
        .lineLimit(1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Baggage belt \(belt)")
    }
}

/// The gate: yellow with an arrow once assigned, grey "Gate --" until then.
struct GateBadge: View {
    var gate: String?
    var arriving: Bool

    /// The badge's yellow and the ink on it, the same in both schemes.
    static let yellow = Color(red: 0xF4 / 255, green: 0xC4 / 255, blue: 0x30 / 255)

    var body: some View {
        Group {
            if let gate {
                HStack(spacing: 3) {
                    Image(systemName: arriving ? "arrow.down.right" : "arrow.up.right")
                        .scaledFont(14, weight: .heavy)
                    Text(gate).scaledFont(18, weight: .bold)
                }
                .foregroundStyle(.black)
                .scaledPadding(.horizontal, 10)
                .scaledPadding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Self.yellow))
            } else {
                Text("Gate --")
                    .scaledFont(17, weight: .semibold)
                    .foregroundStyle(Theme.secondary)
                    .scaledPadding(.horizontal, 10)
                    .scaledPadding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.pill))
            }
        }
        .lineLimit(1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(gate.map { "Gate \($0)" } ?? "Gate not assigned")
    }
}
