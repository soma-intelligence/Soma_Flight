import Foundation

/// A gate name as the airline gives it, read into its concourse letters and number: "B32" is concourse B,
/// gate 32; "E10A" is concourse E, gate 10; "52" has no concourse. Pure, so the rules are tested.
public struct GateName: Sendable, Equatable {
    /// One or two letters before the number, "B" or "MA"; nil for a gate that is a bare number.
    public var concourse: String?
    public var number: Int?

    public init(concourse: String?, number: Int?) { self.concourse = concourse; self.number = number }

    /// Reads "B32", "b 32", "B-32", "Gate B32", "E10A", "T5", "52" or a lone "C". Nil for anything else
    /// ("TBD", an empty string, "Hardstand 4").
    public static func parse(_ raw: String?) -> GateName? {
        guard var s = raw?.uppercased().trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        if s.hasPrefix("GATE") { s.removeFirst(4) }
        s = s.filter { !$0.isWhitespace && $0 != "-" && $0 != "." }
        guard !s.isEmpty, s.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return nil }
        let letters = String(s.prefix { $0.isLetter })
        let rest = s.dropFirst(letters.count)
        let digits = String(rest.prefix { $0.isNumber })
        let suffix = rest.dropFirst(digits.count)
        guard letters.count <= 2, digits.count <= 4, suffix.count <= 1, suffix.allSatisfy(\.isLetter) else { return nil }
        if digits.isEmpty { return letters.isEmpty || !suffix.isEmpty ? nil : GateName(concourse: letters, number: nil) }
        return GateName(concourse: letters.isEmpty ? nil : letters, number: Int(digits))
    }
}

/// How big an airport is, for the walk at airports the table does not list. From the airport list's
/// own size (OurAirports' large, medium and small airports), bundled as `airport_sizes.json`.
public enum AirportSize: String, Codable, Sendable, Equatable {
    case large, medium, small

    /// Typical minutes from security to the gate at an airport of this size.
    public var typicalWalk: Int {
        switch self {
        case .large: 10
        case .medium: 6
        case .small: 3
        }
    }
}

/// The walk from the security checkpoint to the departure gate: how many minutes, and what the figure
/// rests on, from the most precise (the gate's concourse) to the least (the airport's size).
public struct GateWalk: Sendable, Equatable {
    public enum Basis: Sendable, Equatable {
        /// The gate's concourse, "B".
        case concourse(String)
        /// The gate's number falls in a known range of gates, "200 to 299".
        case gates(ClosedRange<Int>)
        /// The flight's terminal, "4".
        case terminal(String)
        /// The airport's typical figure: no gate or terminal yet, or one the table does not know.
        case airport
        /// An airport the table does not list, by its size.
        case size(AirportSize)
    }

    public var minutes: Int
    public var basis: Basis
    /// The gate the figure is for, as the airline gives it; nil before it is known.
    public var gate: String?

    public init(minutes: Int, basis: Basis, gate: String? = nil) {
        self.minutes = minutes; self.basis = basis; self.gate = gate
    }

    /// True when the figure is for the flight's own gate or concourse rather than the airport as a whole.
    public var isForGate: Bool {
        switch basis {
        case .concourse, .gates: true
        default: false
        }
    }
}

/// Typical walking minutes from security to the gate, per terminal or concourse, for the 40 busiest US
/// airports; airports elsewhere get a default by size. See `docs/gate-walk-times.md` for how the figures
/// were reached and how to change them.
public enum GateWalkTable {
    /// One part of an airport: a concourse, a range of numbered gates or a terminal (any or all of them).
    public struct Area: Sendable, Equatable {
        /// Terminal names this area answers to, normalised ("1", "B", "TBIT"); empty for any terminal.
        public var terminals: [String]
        public var concourse: String?
        public var gates: ClosedRange<Int>?
        public var minutes: Int

        public init(terminals: [String] = [], concourse: String? = nil, gates: ClosedRange<Int>? = nil, minutes: Int) {
            self.terminals = terminals; self.concourse = concourse; self.gates = gates; self.minutes = minutes
        }
    }

    public struct Entry: Sendable, Equatable {
        /// IATA code.
        public var airport: String
        /// The airport's typical walk when the gate and terminal say nothing more.
        public var typical: Int
        public var areas: [Area]
    }

    /// The walk for a flight leaving `airport` (IATA or ICAO) from `terminal` and `gate`, either of them
    /// possibly unknown. `size` is the airport's size when the table does not list it; nil counts as medium.
    public static func walk(airport iata: String?, icao: String?, terminal: String?, gate: String?,
                            size: AirportSize?) -> GateWalk {
        let gateName = GateName.parse(gate)
        let shownGate = gate.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        guard let entry = entry(iata: iata, icao: icao) else {
            let s = size ?? .medium
            return GateWalk(minutes: s.typicalWalk, basis: .size(s), gate: shownGate)
        }
        let t = normaliseTerminal(terminal)
        let inTerminal: (Area) -> Bool = { a in t == nil || a.terminals.isEmpty || a.terminals.contains(t!) }
        // 1. The gate's concourse; across terminals the longest walk, so nobody leaves late.
        if let c = gateName?.concourse {
            let hits = entry.areas.filter { $0.concourse == c && inTerminal($0) }
            if let m = hits.map(\.minutes).max() { return GateWalk(minutes: m, basis: .concourse(c), gate: shownGate) }
        }
        // 2. The gate's number in a range of gates.
        if let n = gateName?.number {
            if let a = entry.areas.first(where: { ($0.gates?.contains(n) ?? false) && inTerminal($0) }), let r = a.gates {
                return GateWalk(minutes: a.minutes, basis: .gates(r), gate: shownGate)
            }
        }
        // 3. The terminal: its own figure, else the longest walk of its concourses.
        if let t {
            let hits = entry.areas.filter { $0.terminals.contains(t) }
            let own = hits.first { $0.concourse == nil && $0.gates == nil }
            if let m = own?.minutes ?? hits.map(\.minutes).max() {
                return GateWalk(minutes: m, basis: .terminal(t), gate: shownGate)
            }
        }
        return GateWalk(minutes: entry.typical, basis: .airport, gate: shownGate)
    }

    /// "Terminal 1", "T1", "1" and "t1" are all "1"; "TBIT" stays "TBIT"; "Terminal B" is "B".
    public static func normaliseTerminal(_ raw: String?) -> String? {
        guard var s = raw?.uppercased().trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        if s.hasPrefix("TERMINAL") { s = String(s.dropFirst(8)).trimmingCharacters(in: .whitespaces) }
        if s.count > 1, s.first == "T", s.dropFirst().allSatisfy(\.isNumber) { s.removeFirst() }
        return s.isEmpty ? nil : s
    }

    static func entry(iata: String?, icao: String?) -> Entry? {
        if let iata, let e = byIata[iata.uppercased()] { return e }
        // US airports: the ICAO code is the IATA code after a K.
        if let icao = icao?.uppercased(), icao.count == 4, icao.hasPrefix("K") { return byIata[String(icao.dropFirst())] }
        return nil
    }

    private static let byIata: [String: Entry] = Dictionary(uniqueKeysWithValues: entries.map { ($0.airport, $0) })

    private static func e(_ iata: String, _ typical: Int, _ areas: [Area]) -> Entry {
        Entry(airport: iata, typical: typical, areas: areas)
    }
    private static func c(_ letter: String, _ m: Int, terminal: [String] = []) -> Area {
        Area(terminals: terminal, concourse: letter, minutes: m)
    }
    private static func t(_ names: [String], _ m: Int) -> Area { Area(terminals: names, minutes: m) }
    private static func g(_ r: ClosedRange<Int>, _ m: Int, terminal: [String] = []) -> Area {
        Area(terminals: terminal, gates: r, minutes: m)
    }

    /// The 40 busiest US airports by 2023 passenger boardings (FAA CY2023 enplanements), with the typical
    /// minutes from the main checkpoint to the middle of each concourse, train rides included. Estimates
    /// from the airports' published terminal maps at about 70 m a minute with a bag; see the doc.
    public static let entries: [Entry] = [
        e("ATL", 14, [c("T", 8), c("A", 10), c("B", 12), c("C", 14), c("D", 15), c("E", 17), c("F", 19)]),
        e("DFW", 7, [c("A", 7), c("B", 6), c("C", 7), c("D", 7), c("E", 6)]),
        e("DEN", 11, [c("A", 9), c("B", 11), c("C", 13)]),
        e("ORD", 8, [c("B", 6), c("C", 10), c("E", 6), c("F", 8), c("G", 8), c("H", 7), c("K", 9), c("L", 8),
                     c("M", 7), t(["1"], 8), t(["2"], 7), t(["3"], 8), t(["5"], 7)]),
        e("LAX", 7, [t(["1"], 6), t(["2"], 6), t(["3"], 7), t(["B", "TBIT"], 8), t(["4"], 6), t(["5"], 6),
                     t(["6"], 6), t(["7"], 6), t(["8"], 6), g(200...299, 13)]),
        e("JFK", 8, [t(["1"], 7), c("A", 6, terminal: ["4"]), c("B", 10, terminal: ["4"]), t(["4"], 10),
                     t(["5"], 7), t(["7"], 5), c("B", 7, terminal: ["8"]), c("C", 8, terminal: ["8"]), t(["8"], 8)]),
        e("LAS", 10, [c("A", 8), c("B", 9), c("C", 10), c("D", 13), c("E", 8), t(["1"], 10), t(["3"], 9)]),
        e("MCO", 8, [g(1...29, 8), g(30...59, 8), g(70...99, 8), g(100...129, 8), c("C", 7), t(["C"], 7)]),
        e("MIA", 9, [c("D", 12), c("E", 8), c("F", 8), c("G", 7), c("H", 7), c("J", 8)]),
        e("CLT", 7, [c("A", 8), c("B", 6), c("C", 6), c("D", 7), c("E", 10)]),
        e("SEA", 7, [c("A", 6), c("B", 6), c("C", 7), c("D", 8), c("N", 9), c("S", 9)]),
        e("PHX", 6, [c("A", 6), c("B", 7), c("C", 6), c("D", 7), c("E", 5), c("F", 6), t(["3"], 6), t(["4"], 7)]),
        e("EWR", 7, [c("A", 6), c("B", 6), c("C", 8), t(["A"], 6), t(["B"], 6), t(["C"], 8)]),
        e("SFO", 7, [c("A", 7), c("B", 7), c("C", 6), c("D", 6), c("E", 6), c("F", 7), c("G", 7)]),
        e("IAH", 7, [c("A", 8), c("B", 8), c("C", 6), c("D", 7), c("E", 7)]),
        e("BOS", 7, [c("A", 9), c("B", 6), c("C", 6), c("E", 6), t(["A"], 9), t(["B"], 6), t(["C"], 6), t(["E"], 6)]),
        e("FLL", 6, [c("A", 6), c("B", 6), c("C", 6), c("D", 5), c("E", 6), c("F", 6), c("G", 6), c("H", 6)]),
        e("MSP", 7, [c("A", 7), c("B", 8), c("C", 9), c("D", 6), c("E", 6), c("F", 8), c("G", 7), c("H", 4),
                     t(["2"], 4)]),
        e("LGA", 7, [t(["A"], 3), t(["B"], 7), t(["C"], 7)]),
        e("DTW", 9, [c("A", 10), c("B", 8), c("C", 8), c("D", 5), t(["MCNAMARA", "M"], 10), t(["EVANS", "N"], 5)]),
        e("PHL", 6, [c("A", 8), c("B", 5), c("C", 5), c("D", 5), c("E", 6), c("F", 8)]),
        e("SLC", 12, [c("A", 9), c("B", 15)]),
        e("BWI", 6, [c("A", 6), c("B", 6), c("C", 6), c("D", 8), c("E", 6)]),
        e("DCA", 6, [g(1...9, 4), g(10...45, 6), g(46...59, 10), c("E", 10)]),
        e("SAN", 6, [t(["1"], 6), t(["2"], 7)]),
        e("IAD", 12, [c("A", 12), c("B", 10), c("C", 12), c("D", 12), c("Z", 8)]),
        e("TPA", 6, [c("A", 6), c("C", 6), c("E", 6), c("F", 6)]),
        e("BNA", 7, [c("A", 6), c("B", 6), c("C", 7), c("D", 8)]),
        e("AUS", 7, []),
        e("MDW", 7, [c("A", 7), c("B", 7), c("C", 7)]),
        e("HNL", 8, [c("A", 5), c("B", 6), c("C", 7), c("D", 8), c("E", 10), c("G", 10)]),
        e("DAL", 6, []),
        e("PDX", 6, [c("A", 5), c("B", 5), c("C", 7), c("D", 7), c("E", 8)]),
        e("STL", 7, [c("A", 6), c("C", 8), c("E", 6), t(["1"], 7), t(["2"], 6)]),
        e("RDU", 6, [c("A", 5), c("C", 6), c("D", 7), t(["1"], 5), t(["2"], 7)]),
        e("HOU", 5, []),
        e("SMF", 6, [c("A", 4), c("B", 7), t(["A"], 4), t(["B"], 7)]),
        e("MSY", 6, [c("A", 5), c("B", 6)]),
        e("SJC", 6, [g(1...16, 5), g(17...30, 6), t(["A"], 5), t(["B"], 6)]),
        e("SNA", 5, [g(1...6, 4), g(7...14, 5), g(15...20, 6)]),
    ]
}

/// The bundled sizes of the airports the table does not list (`Resources/Reference/airport_sizes.json`,
/// built by `Scripts/build_airport_sizes.py` from `supabase/seed/airports.csv`): large and small ICAO codes,
/// every other airport medium.
public struct AirportSizes: Sendable {
    private let large: Set<String>
    private let small: Set<String>

    public init(large: Set<String>, small: Set<String>) { self.large = large; self.small = small }

    /// The list in the package's resources; empty (everything medium) when it cannot be read.
    public static let bundled: AirportSizes = {
        struct File: Decodable { var large: [String]; var small: [String] }
        guard let url = Bundle.module.url(forResource: "airport_sizes", withExtension: "json", subdirectory: "Reference")
                ?? Bundle.module.url(forResource: "airport_sizes", withExtension: "json"),
              let data = try? Data(contentsOf: url), let f = try? JSONDecoder().decode(File.self, from: data)
        else { return AirportSizes(large: [], small: []) }
        return AirportSizes(large: Set(f.large), small: Set(f.small))
    }()

    public func size(_ icao: String) -> AirportSize {
        let k = icao.uppercased()
        if large.contains(k) { return .large }
        if small.contains(k) { return .small }
        return .medium
    }
}
