import Foundation

/// The three short texts a language model can write from facts the app already shows. See `flight-brief`
/// (supabase/functions/flight-brief) for what each is.
public enum BriefKind: String, Sendable, Hashable, CaseIterable {
    case doorToDoor = "door_to_door"
    case delayCause = "delay_cause"
    case airportSummary = "airport_summary"
}

/// The value of one fact: the same four shapes the backend accepts (text, whole number, number, flag).
public enum BriefValue: Sendable, Hashable, Encodable {
    case text(String)
    case int(Int)
    case number(Double)
    case flag(Bool)

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .text(let s): try c.encode(s)
        case .int(let n): try c.encode(n)
        case .number(let d): try c.encode(d)
        case .flag(let b): try c.encode(b)
        }
    }
}

/// One fact sent to the model: an id from the backend's fixed list and a typed value. Names, booking codes,
/// documents and the vault have no id, so they cannot be sent.
public struct BriefFact: Sendable, Hashable, Encodable {
    public var id: String
    public var value: BriefValue

    public init(_ id: String, _ value: BriefValue) { self.id = id; self.value = value }
}

/// A text the model wrote, with the ids of the facts it relied on.
public struct FlightBrief: Sendable, Hashable, Equatable {
    public var kind: BriefKind
    public var text: String
    public var factsUsed: [String]
    public var generatedAt: Date

    public init(kind: BriefKind, text: String, factsUsed: [String], generatedAt: Date) {
        self.kind = kind; self.text = text; self.factsUsed = factsUsed; self.generatedAt = generatedAt
    }
}

/// The facts of each brief, built from what a screen already holds. Pure, so the tests read exactly what
/// would leave the device. Every value is checked against the pattern the backend enforces: a value that
/// does not fit is left out, never sent. Times are local to the airport, 24 hour.
public enum BriefFacts {
    // MARK: Shared

    static func fits(_ pattern: String, _ s: String) -> Bool {
        s.range(of: pattern, options: .regularExpression) != nil
    }

    static let identPattern = "^([A-Z]{3}|[A-Z0-9]{2})[0-9]{1,4}[A-Z]?$"
    static let airportPattern = "^[A-Z]{3,4}$"
    static let codePattern = "^[A-Z0-9]{1,6}$"
    static let metarPattern = "^[A-Z0-9/ +\\-$]{1,160}$"

    /// "14:35" at `tz`, always 24 hour (the backend's format whatever the user's clock).
    static func clock(_ date: Date, _ tz: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = tz
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }

    static func clamp(_ n: Int, _ range: ClosedRange<Int>) -> Int { min(range.upperBound, max(range.lowerBound, n)) }

    private static func text(_ id: String, _ raw: String?, _ pattern: String, into out: inout [BriefFact]) {
        guard let v = raw?.trimmingCharacters(in: .whitespaces).uppercased(), fits(pattern, v) else { return }
        out.append(BriefFact(id, .text(v)))
    }

    /// A short advisory line the backend accepts: letters, figures and `, . : + - / ( ) '`, at most 80
    /// characters; anything else becomes a space.
    static func label(_ raw: String) -> String? {
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789 ,.:+-/()'")
        let cleaned = String(raw.map { allowed.contains($0) ? $0 : " " })
            .split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        let cut = String(cleaned.prefix(80)).trimmingCharacters(in: .whitespaces)
        return cut.isEmpty ? nil : cut
    }

    /// "Ground delay program, about 47 min": the FAA's most serious program, in words and figures.
    static func programLine(_ programs: AirportPrograms?) -> String? {
        guard let p = programs.map({ AirportProgram.sorted($0.programs) })?.first else { return nil }
        let name: String = switch p.kind {
        case .closure: "Airport closed"
        case .groundStop: "Ground stop"
        case .groundDelay: "Ground delay program"
        case .departureDelay: "Departure delays"
        case .arrivalDelay: "Arrival delays"
        case .deicing: "Deicing"
        }
        var line = name
        if let m = p.averageMinutes, m > 0 { line += ", about \(m) min" }
        if let r = p.reason, !r.isEmpty { line += ", \(r)" }
        return label(line)
    }

    /// Weather facts of one side, only when the weather is not plain VFR: a clear day is no cause.
    private static func weather(_ w: Weather?, prefix: String, into out: inout [BriefFact]) {
        guard let w, w.category != .VFR else { return }
        out.append(BriefFact("\(prefix)_weather_category", .text(w.category.rawValue)))
        text("\(prefix)_metar", w.metarRaw, metarPattern, into: &out)
    }

    // MARK: Door to door

    /// The leave-by computation and the walk, in one list; nil when the flight has no leave time or has
    /// left. Only what is known goes in: a fixed-rule time has no drive, queue or bag drop.
    public static func doorToDoor(flight f: Flight, leave: LeaveTime?, walk: GateWalk?, tz: TimeZone,
                                  now: Date) -> [BriefFact]? {
        guard let leave, leave.departure > now else { return nil }
        var out: [BriefFact] = []
        text("ident", f.ident, identPattern, into: &out)
        text("origin_iata", f.originIata, airportPattern, into: &out)
        text("destination_iata", f.destinationIata, airportPattern, into: &out)
        out.append(BriefFact("departure_local", .text(clock(leave.departure, tz))))
        out.append(BriefFact("leave_by_local", .text(clock(leave.leaveAt, tz))))
        out.append(BriefFact("international", .flag(leave.international)))
        text("terminal", f.terminalOrigin, codePattern, into: &out)
        text("gate", f.gateOrigin, codePattern, into: &out)
        if let b = leave.breakdown {
            out.append(BriefFact("boarding_local", .text(clock(b.boardingAt, tz))))
            out.append(BriefFact("drive_minutes", .int(clamp(Int(b.drive / 60), 0...600))))
            out.append(BriefFact("bag_drop_minutes", .int(clamp(Int(b.bagDrop / 60), 0...120))))
            out.append(BriefFact("security_wait_minutes", .int(clamp(b.securityMinutes, 0...240))))
            out.append(BriefFact("security_live", .flag(b.securityIsLive)))
            out.append(BriefFact("precheck", .flag(b.precheck)))
            out.append(BriefFact("boarding_lead_minutes", .int(clamp(Int(b.boardingLead / 60), 0...120))))
        }
        if let walk, walk.minutes > 0 { out.append(BriefFact("walk_minutes", .int(clamp(walk.minutes, 0...120)))) }
        if let d = f.departureDelay, Format.minutes(d) >= 15 {
            out.append(BriefFact("delay_minutes", .int(clamp(Format.minutes(d), 0...1440))))
        }
        return out
    }

    // MARK: Why it is late

    /// The causes the sheet already shows for a late flight; nil unless the flight is 15 minutes or more late
    /// and at least one cause is known (a late inbound plane, bad weather, an FAA program, a gate change).
    public static func delayCause(flight f: Flight, inbound: [InboundLeg], originWeather: Weather?,
                                  destinationWeather: Weather?, advisories: FlightAdvisories,
                                  events: [FlightEvent]) -> [BriefFact]? {
        let delay = [f.departureDelay, f.arrivalDelay].compactMap { $0.map(Format.minutes) }.max() ?? 0
        guard delay >= 15, f.status != .canceled else { return nil }
        var out: [BriefFact] = []
        var causes = 0
        text("ident", f.ident, identPattern, into: &out)
        text("origin_iata", f.originIata, airportPattern, into: &out)
        text("destination_iata", f.destinationIata, airportPattern, into: &out)
        out.append(BriefFact("status", .text(f.status.rawValue)))
        out.append(BriefFact("delay_minutes", .int(clamp(delay, 0...1440))))
        if let leg = inbound.first, leg.delayMinutes > 0 {
            out.append(BriefFact("inbound_late_minutes", .int(clamp(leg.delayMinutes, 0...1440))))
            out.append(BriefFact("inbound_status", .text(leg.status.rawValue)))
            text("inbound_origin_iata", leg.originIata, airportPattern, into: &out)
            causes += 1
        }
        let before = out.count
        weather(originWeather, prefix: "origin", into: &out)
        weather(destinationWeather, prefix: "destination", into: &out)
        if out.count > before { causes += 1 }
        for (id, programs) in [("origin_faa_program", advisories.originPrograms),
                               ("destination_faa_program", advisories.destinationPrograms)] {
            if let line = programLine(programs) { out.append(BriefFact(id, .text(line))); causes += 1 }
        }
        let changes = events.filter { $0.kind == .gateChange }.count
        if changes > 0 { out.append(BriefFact("gate_changes", .int(clamp(changes, 0...20)))); causes += 1 }
        return causes > 0 ? out : nil
    }

    // MARK: Airport summary

    /// An airport's weather, delays, FAA program and security wait as the screen holds them; nil with fewer
    /// than two figures beside the code.
    public static func airportSummary(code: String, weather: Weather?, stats: (departures: DelayStats, arrivals: DelayStats)?,
                                      programs: AirportPrograms?, security: SecurityWait?,
                                      level: AirportStatusLevel) -> [BriefFact]? {
        var out: [BriefFact] = []
        text("iata", code, airportPattern, into: &out)
        guard !out.isEmpty else { return nil }
        if let w = weather {
            out.append(BriefFact("weather_category", .text(w.category.rawValue)))
            text("metar", w.metarRaw, metarPattern, into: &out)
            if let kt = w.windKt { out.append(BriefFact("wind_knots", .int(clamp(kt, 0...200)))) }
            if let g = w.gustKt { out.append(BriefFact("gust_knots", .int(clamp(g, 0...250)))) }
            if let v = w.visibilitySm, v >= 0, v <= 99 { out.append(BriefFact("visibility_miles", .number(v))) }
            if let c = w.ceilingFt { out.append(BriefFact("ceiling_feet", .int(clamp(c, 0...60000)))) }
        }
        if let s = stats {
            for (side, d) in [("departures", s.departures), ("arrivals", s.arrivals)] where d.total > 0 {
                out.append(BriefFact("\(side)_delay_minutes", .int(clamp(Int(d.avgDelayMinutes.rounded()), 0...600))))
                out.append(BriefFact("\(side)_on_time_percent", .int(clamp(d.onTime * 100 / d.total, 0...100))))
            }
        }
        if let line = programLine(programs) { out.append(BriefFact("faa_program", .text(line))) }
        if let sec = security, let m = SecurityWaitFacts.shortest(sec, terminal: nil).standard?.standardMinutes {
            out.append(BriefFact("security_wait_minutes", .int(clamp(m, 0...240))))
        }
        out.append(BriefFact("status_level", .text(["normal", "minor", "major"][level.rawValue])))
        return out.count >= 4 ? out : nil
    }
}
