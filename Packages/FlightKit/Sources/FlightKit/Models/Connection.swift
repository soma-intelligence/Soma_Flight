import Foundation

// MARK: - Rules

/// Typical minimum connection times and transfer rules, from `Resources/Reference/connection_rules.json`.
/// push-sender reads a copy of the same file (`supabase/functions/_shared/connection_rules.json`), so the
/// verdict on the flight sheet and the "connection at risk" alert never disagree; a test fails when the two
/// copies differ. The figures are typical values for planning, not an airline's official MCT.
public struct ConnectionRules: Decodable, Sendable {
    /// Minutes needed for each kind of connection at one airport.
    public struct MCT: Decodable, Sendable, Equatable {
        public var dd: Int
        public var di: Int
        public var id: Int
        public var ii: Int

        public func minutes(_ kind: ConnectionKind) -> Int {
            switch kind {
            case .domesticToDomestic: dd
            case .domesticToInternational: di
            case .internationalToDomestic: id
            case .internationalToInternational: ii
            }
        }
    }

    /// When a connection goes through security again.
    public enum Screening: String, Decodable, Sendable {
        /// Every connection (transfer security at most hubs outside North America and Europe).
        case always
        /// When the arriving flight is international.
        case international
    }

    /// One airport's figures; `defaults` stands in for airports outside the table.
    public struct Profile: Decodable, Sendable, Equatable {
        public var iata: String?
        public var mct: MCT
        /// True when the terminals are connected behind security (a terminal change needs no new screening).
        public var airsideTerminals: Bool
        /// The train, bus or walk between two terminals.
        public var terminalTransferMinutes: Int
        /// From the last checkpoint to a typical gate.
        public var walkMinutes: Int
        public var transferScreening: Screening
    }

    public struct Verdict: Decodable, Sendable {
        /// Spare minutes over the MCT under which a connection is tight.
        public var tightMarginMinutes: Int
        /// Boarding closes this long before departure: less time on the ground than this is a missed connection.
        public var gateCloseMinutes: Int
    }

    /// Typical minutes per step, the same at every airport.
    public struct Steps: Decodable, Sendable {
        public var deplane: Int
        public var deplaneInternational: Int
        public var immigration: Int
        public var customsRecheck: Int
        public var exitControl: Int
        public var security: Int
    }

    public var version: Int
    public var defaults: Profile
    public var verdict: Verdict
    public var steps: Steps
    /// ISO country codes of the Schengen area: no passport control between them.
    public var schengen: Set<String>
    /// Countries counted as one for domestic flights (the US and its territories).
    public var countryGroups: [[String]]
    /// Every international arrival clears immigration and customs, re-checks bags and is screened again
    /// (there is no airside transit).
    public var fullEntryCountries: Set<String>
    /// No passport check on the way out.
    public var noExitControlCountries: Set<String>
    /// Profiles by ICAO code.
    public var airports: [String: Profile]

    /// The airport's profile, or the defaults when it is not in the table.
    public func profile(_ icao: String) -> Profile { airports[icao.uppercased()] ?? defaults }

    /// True when the airport has its own figures (one of the 40 busiest).
    public func knows(_ icao: String) -> Bool { airports[icao.uppercased()] != nil }

    /// True when a flight between the two countries needs no passport check: the same country, one country
    /// group, or both in the Schengen area.
    public func sameRegion(_ a: String, _ b: String) -> Bool {
        let a = a.uppercased(), b = b.uppercased()
        if a == b { return true }
        if countryGroups.contains(where: { $0.contains(a) && $0.contains(b) }) { return true }
        return schengen.contains(a) && schengen.contains(b)
    }

    public static func decode(_ data: Data) throws -> ConnectionRules {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(ConnectionRules.self, from: data)
    }

    /// The file in the app bundle. It ships with the app, so a failure is a build error.
    public static let bundled: ConnectionRules = {
        guard let url = Bundle.module.url(forResource: "connection_rules", withExtension: "json", subdirectory: "Reference")
                ?? Bundle.module.url(forResource: "connection_rules", withExtension: "json"),
              let data = try? Data(contentsOf: url) else {
            fatalError("Missing connection_rules.json")
        }
        do { return try decode(data) } catch { fatalError("Bad connection_rules.json: \(error)") }
    }()
}

// MARK: - Pairing

/// Two followed flights where the first lands at the airport the second leaves from, the second
/// scheduled to leave after the first lands and within `ConnectionPairing.window`.
public struct Connection: Sendable, Hashable, Identifiable {
    public var arriving: Flight
    public var departing: Flight

    public init(arriving: Flight, departing: Flight) {
        self.arriving = arriving; self.departing = departing
    }

    public var id: String { "\(arriving.id.uuidString)-\(departing.id.uuidString)" }
    /// ICAO code of the connection airport.
    public var airport: String { departing.originIcao }

    /// The same pair with fresher copies of its flights (an update for either one); others are ignored.
    public func updated(with f: Flight) -> Connection {
        var c = self
        if f.id == arriving.id { c.arriving = f }
        if f.id == departing.id { c.departing = f }
        return c
    }
}

public enum ConnectionPairing {
    /// Longest scheduled gap between landing and leaving that still reads as a connection.
    public static let window: TimeInterval = 24 * 3600

    /// The planned times pair the flights, so a delay never splits a connection.
    static func plannedIn(_ f: Flight) -> Date? { f.scheduledIn ?? f.estimatedIn }
    static func plannedOut(_ f: Flight) -> Date? { f.scheduledOut ?? f.estimatedOut }

    /// The scheduled gap when `b` connects from `a`; nil when it does not. A flight back to where `a` came
    /// from is a return trip, not a connection.
    static func gap(_ a: Flight, _ b: Flight) -> TimeInterval? {
        guard a.id != b.id, a.destinationIcao == b.originIcao, b.destinationIcao != a.originIcao,
              let landing = plannedIn(a), let leaving = plannedOut(b) else { return nil }
        let gap = leaving.timeIntervalSince(landing)
        return gap > 0 && gap <= window ? gap : nil
    }

    /// Every connection among `flights`. Each flight arrives into at most one connection and leaves from at
    /// most one: the shortest gaps win, so a three-leg trip gives two connections and a flight followed
    /// twice the same day pairs with the nearest one. Sorted by the connection's planned landing.
    public static func pairs(_ flights: [Flight]) -> [Connection] {
        var candidates: [(gap: TimeInterval, a: Flight, b: Flight)] = []
        for a in flights {
            for b in flights {
                if let g = gap(a, b) { candidates.append((g, a, b)) }
            }
        }
        candidates.sort { $0.gap != $1.gap ? $0.gap < $1.gap : $0.b.id.uuidString < $1.b.id.uuidString }
        var arriving = Set<Flight.ID>(), departing = Set<Flight.ID>()
        var out: [Connection] = []
        for c in candidates where !arriving.contains(c.a.id) && !departing.contains(c.b.id) {
            arriving.insert(c.a.id); departing.insert(c.b.id)
            out.append(Connection(arriving: c.a, departing: c.b))
        }
        return out.sorted { (plannedIn($0.arriving) ?? .distantFuture) < (plannedIn($1.arriving) ?? .distantFuture) }
    }

    /// The connections a flight is part of: the one it arrives into first (it is the onward leg), then the
    /// one it leaves for. Empty when it connects with nothing followed.
    public static func connections(for id: Flight.ID, in flights: [Flight]) -> [Connection] {
        let all = pairs(flights)
        return all.filter { $0.departing.id == id } + all.filter { $0.arriving.id == id }
    }
}

// MARK: - Assessment

/// Domestic or international on each side of the connection, as the connection airport sees it.
public enum ConnectionKind: String, Sendable, CaseIterable {
    case domesticToDomestic, domesticToInternational, internationalToDomestic, internationalToInternational

    public init(arrivingInternational: Bool, departingInternational: Bool) {
        switch (arrivingInternational, departingInternational) {
        case (false, false): self = .domesticToDomestic
        case (false, true): self = .domesticToInternational
        case (true, false): self = .internationalToDomestic
        case (true, true): self = .internationalToInternational
        }
    }

    public var arrivesInternational: Bool { self == .internationalToDomestic || self == .internationalToInternational }
    public var leavesInternational: Bool { self == .domesticToInternational || self == .internationalToInternational }
}

/// How the connection looks, from the most room to none. Ordered, so "worse" is `>`.
public enum ConnectionVerdict: Int, Sendable, Comparable, CaseIterable {
    case comfortable, tight, atRisk, missed

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

/// Why a connection is missed when time on the ground is not the reason.
public enum ConnectionBreak: Sendable, Equatable {
    case arrivingCanceled
    case departingCanceled
    /// The first flight is not landing at the connection airport.
    case arrivingDiverted
    /// The second flight left its gate before the first reached its own.
    case departed
}

/// A passport check on the way through.
public enum PassportCheck: Sendable, Equatable {
    /// Entering the country (or the Schengen area): immigration.
    case entry
    /// Leaving it: exit passport control.
    case exit
}

/// One thing to do between the two gates, with its typical minutes.
public struct ConnectionStep: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        case deplane
        case immigration
        /// Customs, then the bags go back on the belt for the next flight.
        case customsRecheck
        case exitControl
        /// Train, bus or walk to the other terminal; `to` is the departure terminal.
        case terminalTransfer(to: String)
        case security
        case walkToGate(gate: String?)
    }

    public var kind: Kind
    public var minutes: Int

    public init(_ kind: Kind, minutes: Int) { self.kind = kind; self.minutes = minutes }
}

/// Everything the Connection card says, worked out from the two flights' best times. Pure, so tests and
/// the card read the same figures.
public struct ConnectionAssessment: Sendable, Equatable {
    public var kind: ConnectionKind
    /// True at a Schengen airport: the card says Schengen and non-Schengen rather than domestic and international.
    public var schengenAirport: Bool
    /// Best landing of the first flight (actual, else estimate, else schedule) and best departure of the second.
    public var arrival: Date?
    public var departure: Date?
    /// Minutes between the two; nil when either time is unknown. Negative when the second leaves first.
    public var layoverMinutes: Int?
    public var mctMinutes: Int
    /// True when the airport has its own figures; false when the defaults stand in.
    public var knownAirport: Bool
    public var verdict: ConnectionVerdict
    public var broken: ConnectionBreak?
    public var arrivalTerminal: String?
    public var arrivalGate: String?
    public var departureTerminal: String?
    public var departureGate: String?
    /// True or false when both terminals are known; nil when either is not.
    public var terminalChange: Bool?
    public var passport: PassportCheck?
    /// True when going through security again is likely.
    public var security: Bool
    public var steps: [ConnectionStep]

    /// The steps' minutes added up: a typical time from the plane door to the next gate.
    public var stepMinutes: Int { steps.reduce(0) { $0 + $1.minutes } }
    /// Minutes over (positive) or under (negative) the MCT.
    public var spareMinutes: Int? { layoverMinutes.map { $0 - mctMinutes } }
}

public enum ConnectionAssistant {
    /// When the first flight is on the ground at its gate, or its best estimate of that.
    public static func bestArrival(_ f: Flight) -> Date? {
        f.actualIn ?? f.estimatedIn ?? f.actualOn.map { $0.addingTimeInterval(5 * 60) } ?? f.scheduledIn
    }

    /// When the second flight leaves its gate, or its best estimate of that.
    public static func bestDeparture(_ f: Flight) -> Date? { f.actualOut ?? f.estimatedOut ?? f.scheduledOut }

    /// "2E" and "Terminal 2E" are the same terminal; case and spaces do not count.
    static func normalizedTerminal(_ t: String?) -> String? {
        guard var s = t?.trimmingCharacters(in: .whitespaces).uppercased(), !s.isEmpty else { return nil }
        if s.hasPrefix("TERMINAL") { s = String(s.dropFirst("TERMINAL".count)).trimmingCharacters(in: .whitespaces) }
        return s.isEmpty ? nil : s
    }

    /// The verdict for a layover against the airport's MCT. Canceled and diverted flights, and a second
    /// flight that left before the first reached its gate, are missed whatever the minutes say.
    public static func verdict(layover: Int?, mct: Int, broken: ConnectionBreak?,
                               rules: ConnectionRules = .bundled) -> ConnectionVerdict {
        if broken != nil { return .missed }
        guard let layover else { return .comfortable }
        if layover < rules.verdict.gateCloseMinutes { return .missed }
        if layover < mct { return .atRisk }
        if layover < mct + rules.verdict.tightMarginMinutes { return .tight }
        return .comfortable
    }

    static func broken(_ c: Connection) -> ConnectionBreak? {
        let a = c.arriving, b = c.departing
        if a.status == .canceled { return .arrivingCanceled }
        if b.status == .canceled { return .departingCanceled }
        if a.status == .diverted { return .arrivingDiverted }
        if let left = b.actualOut {
            guard let landed = a.actualIn ?? a.actualOn, landed <= left else { return .departed }
        }
        return nil
    }

    /// The whole picture for one connection.
    /// - Parameter country: an airport's ISO country by ICAO code; nil when unknown (taken as international,
    ///   the longer connection).
    public static func assess(_ c: Connection, country: (String) -> String?,
                              rules: ConnectionRules = .bundled) -> ConnectionAssessment {
        let a = c.arriving, b = c.departing
        let hub = c.airport
        let hubCountry = country(hub)
        func international(_ other: String) -> Bool {
            guard let h = hubCountry, let o = country(other) else { return true }
            return !rules.sameRegion(h, o)
        }
        let kind = ConnectionKind(arrivingInternational: international(a.originIcao),
                                  departingInternational: international(b.destinationIcao))
        let profile = rules.profile(hub)
        let mct = profile.mct.minutes(kind)

        let arrival = bestArrival(a), departure = bestDeparture(b)
        let layover = arrival.flatMap { i in departure.map { Int(($0.timeIntervalSince(i) / 60).rounded(.down)) } }
        let broken = broken(c)

        let inTerminal = normalizedTerminal(a.terminalDestination)
        let outTerminal = normalizedTerminal(b.terminalOrigin)
        let terminalChange: Bool? = inTerminal.flatMap { i in outTerminal.map { $0 != i } }

        let fullEntry = hubCountry.map { rules.fullEntryCountries.contains($0) } ?? false
        let passport: PassportCheck?
        if kind.arrivesInternational && (fullEntry || !kind.leavesInternational) {
            passport = .entry
        } else if !kind.arrivesInternational && kind.leavesInternational
                    && !(hubCountry.map { rules.noExitControlCountries.contains($0) } ?? false) {
            passport = .exit
        } else {
            passport = nil
        }

        let security = (fullEntry && kind.arrivesInternational)
            || profile.transferScreening == .always
            || (profile.transferScreening == .international && kind.arrivesInternational)
            || (terminalChange == true && !profile.airsideTerminals)

        let s = rules.steps
        var steps = [ConnectionStep(.deplane, minutes: kind.arrivesInternational ? s.deplaneInternational : s.deplane)]
        if passport == .entry { steps.append(.init(.immigration, minutes: s.immigration)) }
        if fullEntry && kind.arrivesInternational { steps.append(.init(.customsRecheck, minutes: s.customsRecheck)) }
        if passport == .exit { steps.append(.init(.exitControl, minutes: s.exitControl)) }
        if terminalChange == true, let to = b.terminalOrigin {
            steps.append(.init(.terminalTransfer(to: to), minutes: profile.terminalTransferMinutes))
        }
        if security { steps.append(.init(.security, minutes: s.security)) }
        steps.append(.init(.walkToGate(gate: b.gateOrigin), minutes: profile.walkMinutes))

        let schengen = hubCountry.map { rules.schengen.contains($0) } ?? false
        return ConnectionAssessment(
            kind: kind, schengenAirport: schengen, arrival: arrival, departure: departure,
            layoverMinutes: layover, mctMinutes: mct, knownAirport: rules.knows(hub),
            verdict: verdict(layover: layover, mct: mct, broken: broken, rules: rules), broken: broken,
            arrivalTerminal: a.terminalDestination, arrivalGate: a.gateDestination,
            departureTerminal: b.terminalOrigin, departureGate: b.gateOrigin,
            terminalChange: terminalChange, passport: passport, security: security, steps: steps)
    }
}
