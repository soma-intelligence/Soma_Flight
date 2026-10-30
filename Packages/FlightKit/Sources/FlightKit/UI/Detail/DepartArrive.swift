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
    @Environment(\.units) private var units

    var body: some View {
        let out = DetailFacts.bestOut(flight), arr = DetailFacts.bestIn(flight)
        let marker: String? = if let out, let arr {
            DetailFacts.dayMarker(departure: out, depTz: origin?.timeZone ?? .current,
                                  arrival: arr, arrTz: destination?.timeZone ?? .current)
        } else { nil }
        VStack(alignment: .leading, spacing: 0) {
            side(arriving: false, code: flight.originCode, icao: flight.originIcao, airport: origin, time: out,
                 word: DetailFacts.timeWord(scheduled: flight.scheduledOut, estimated: flight.estimatedOut,
                                            actual: flight.actualOut),
                 gate: flight.gateOrigin, terminal: flight.terminalOrigin, marker: nil)
            middle
                .scaledPadding(.vertical, 18)
            side(arriving: true, code: flight.destinationCode, icao: flight.destinationIcao, airport: destination,
                 time: arr,
                 word: DetailFacts.timeWord(scheduled: flight.scheduledIn, estimated: flight.estimatedIn,
                                            actual: flight.actualIn),
                 gate: flight.gateDestination, terminal: flight.terminalDestination, marker: marker)
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
                      gate: String?, terminal: String?, marker: String?) -> some View {
        let tz = airport?.timeZone ?? .current
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

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .center) {
                    HStack(alignment: .top, spacing: 2) {
                        Text(time.map { Format.clock($0, tz, units.clock) } ?? "--:--")
                            .scaledFont(40, weight: .semibold)
                            .monospacedDigit()
                            .foregroundStyle(time == nil ? Theme.secondary : Theme.primary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                        if let marker {
                            Text(marker)
                                .scaledFont(15, weight: .semibold)
                                .foregroundStyle(Theme.primary)
                                .accessibilityLabel(marker.hasPrefix("-") ? "previous day" : "\(marker) day")
                        }
                    }
                    Spacer(minLength: 12)
                    GateBadge(gate: gate, arriving: arriving)
                }
                HStack(alignment: .firstTextBaseline) {
                    Text(word)
                        .scaledFont(14)
                        .foregroundStyle(Theme.secondary)
                    Spacer(minLength: 12)
                    Text(arriving && flight.baggageBelt != nil
                         ? "Terminal \(terminal ?? "--") · Belt \(flight.baggageBelt ?? "")"
                         : "Terminal \(terminal ?? "--")")
                        .scaledFont(14)
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(1)
                }
            }
            .accessibilityElement(children: .combine)
        }
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
