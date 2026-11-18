import Foundation

/// The words of FAA programs and NOTAMs on every screen: the flight sheet's Good to Know, the airport
/// sheet's issues card and the Operations Report. No SwiftUI here, so the tests read the exact text the
/// screens show.
public enum FAAFacts {
    /// Which end of a flight an airport is.
    public enum End: Sendable { case origin, destination }

    /// Whether a program at one end matters to a passenger (as the backend's alert sweep decides):
    /// departure delays and deicing only at the origin, arrival delays only at the destination;
    /// closures, ground stops and ground delay programs at either end.
    public static func matters(_ kind: AirportProgram.Kind, at end: End) -> Bool {
        switch kind {
        case .departureDelay, .deicing: end == .origin
        case .arrivalDelay: end == .destination
        case .closure, .groundStop, .groundDelay: true
        }
    }

    /// The programs that matter at that end (every one for nil, the airport sheet), most serious first,
    /// without any that ended before `now`.
    public static func programs(_ p: AirportPrograms?, at end: End?, now: Date) -> [AirportProgram] {
        AirportProgram.sorted((p?.programs ?? []).filter { prog in
            let here = end.map { matters(prog.kind, at: $0) } ?? true
            return here && (prog.endsAt.map { $0 > now } ?? true)
        })
    }

    /// Whether a flight sheet asks for advisories at all: the flight has not landed and is not canceled
    /// or diverted (a program or notice no longer changes anything for it).
    public static func worthLoading(_ status: FlightStatus) -> Bool {
        [.scheduled, .unknown, .departed, .enRoute].contains(status)
    }

    static func capitalized(_ s: String) -> String { s.prefix(1).uppercased() + s.dropFirst() }

    /// "Until 20:59", "From 23:00 to 06:00", "From 23:00"; nil without times. A start in the past is left
    /// out: the program already runs.
    static func window(_ p: AirportProgram, timeZone: TimeZone, clock: TimeStyle, now: Date) -> String? {
        let start = p.startsAt.flatMap { $0 > now ? Format.clock($0, timeZone, clock) : nil }
        let end = p.endsAt.map { Format.clock($0, timeZone, clock) }
        switch (start, end) {
        case let (s?, e?): return Format.words("From \(s) to \(e)")
        case let (s?, nil): return Format.words("From \(s)")
        case let (nil, e?): return Format.words("Until \(e)")
        case (nil, nil): return nil
        }
    }

    /// "Average 31m and rising", "Average 22m and easing", "Average 47m".
    static func average(_ p: AirportProgram) -> String? {
        guard let m = p.averageMinutes, m > 0 else { return nil }
        let span = Format.minutes(m)
        switch p.trend {
        case .increasing?: return Format.words("Average \(span) and rising")
        case .decreasing?: return Format.words("Average \(span) and easing")
        default: return Format.words("Average \(span)")
        }
    }

    /// One program as a title and a line, e.g. "Ground delay program at SFO" and
    /// "Average 47m · Low clouds · Until 20:59". `code` is the airport as the app shows it.
    public static func row(_ p: AirportProgram, code: String, timeZone: TimeZone, clock: TimeStyle = .h24,
                           now: Date) -> (title: String, text: String) {
        let reason = p.reason.map { UIText.localized(capitalized($0)) }
        let when = window(p, timeZone: timeZone, clock: clock, now: now)
        func line(_ parts: [String?]) -> String { parts.compactMap { $0 }.joined(separator: " · ") }
        switch p.kind {
        case .groundDelay:
            return (Format.words("Ground delay program at \(code)"),
                    line([average(p), reason, when]))
        case .groundStop:
            let ext: String? = switch p.extensionChance {
            case .high?: Format.words("Likely to be extended")
            case .medium?: Format.words("May be extended")
            default: nil
            }
            return (Format.words("Ground stop at \(code)"),
                    line([Format.words("Flights to \(code) are held before take-off"), reason, when, ext]))
        case .closure:
            return (Format.words("\(code) is closed"),
                    line([when ?? Format.words("Until further notice"), Format.words("Check with your airline")]))
        case .departureDelay:
            return (Format.words("Departure delays at \(code)"), line([average(p), reason]))
        case .arrivalDelay:
            return (Format.words("Arrival delays at \(code)"), line([average(p), reason]))
        case .deicing:
            return (Format.words("Deicing at \(code)"),
                    Format.words("Planes are deiced before take-off, which adds a few minutes."))
        }
    }

    /// The short NOTAM line of Good to Know: closures of the airport or whole runways, then ILS outages,
    /// e.g. "2 runway closures at SFO" and "Runway 10L/28R closed · Runway 01L/19R closed". nil when the
    /// notices hold none of those (taxiways, construction and obstacles only show in the report).
    public static func notamLine(_ r: NotamReport?, code: String) -> (title: String, text: String)? {
        guard let r else { return nil }
        if let closed = r.notams.first(where: \.closesAirport) {
            return (Format.words("\(code) closed by NOTAM"),
                    closed.detail ?? Format.words("Check with your airline before you go."))
        }
        let runways = r.notams.filter(\.closesRunway)
        let ils = r.notams.filter { $0.kind == .ilsOut }
        guard !runways.isEmpty || !ils.isEmpty else { return nil }
        let title: String = if runways.isEmpty {
            ils.count == 1 ? Format.words("ILS out at \(code)") : Format.words("\(ils.count) ILS outages at \(code)")
        } else {
            runways.count == 1 ? Format.words("Runway closure at \(code)")
                : Format.words("\(runways.count) runway closures at \(code)")
        }
        let items = (runways + ils).prefix(3).map(\.title)
        return (title, items.joined(separator: " · "))
    }

    /// When a notice applies: "Until 13:00", "From 05:00 to 13:00", "Until about 13:00", "Permanent".
    public static func notamWindow(_ n: Notam, timeZone: TimeZone, clock: TimeStyle = .h24, now: Date) -> String {
        let start = n.startsAt.flatMap { $0 > now ? Format.clock($0, timeZone, clock) : nil }
        guard let end = n.endsAt else {
            return start.map { Format.words("From \($0), until further notice") } ?? Format.words("Until further notice")
        }
        let time = Format.clock(end, timeZone, clock)
        let e = n.endsEstimated ? Format.words("about \(time)") : time
        return start.map { Format.words("From \($0) to \(e)") } ?? Format.words("Until \(e)")
    }

    /// The source line under the programs.
    public static func programsSource(_ p: AirportPrograms, now: Date) -> String {
        let ago = Format.ago(p.fetchedAt, now: now)
        return p.isStale ? Format.words("FAA NAS status • last read \(ago)") : Format.words("FAA NAS status • updated \(ago)")
    }

    /// Where a reason came from, for the report's line under it.
    public static func reasonSource(_ s: AirportAssessment.Source) -> String {
        switch s {
        case .notam: "NOTAM"
        case .metar: "METAR, observed now"
        case .forecast: "TAF forecast"
        }
    }

    /// The report's line under the likely disruption: what it was read from, and that it is inferred.
    public static func assessmentSource(_ a: AirportAssessment) -> String {
        var read: [String] = []
        if a.readNotams { read.append("NOTAMs") }
        if a.readMetar { read.append("METAR") }
        if a.readTaf { read.append("TAF") }
        let from = read.isEmpty ? "nothing" : read.joined(separator: ", ")
        return "Inferred from \(from) with simple rules, not an official program"
    }

    /// The source line under the notices.
    public static func notamSource(_ r: NotamReport, now: Date) -> String {
        let ago = Format.ago(r.fetchedAt, now: now)
        return r.isStale ? Format.words("FAA NOTAM service • last read \(ago)")
            : Format.words("FAA NOTAM service • updated \(ago)")
    }
}
