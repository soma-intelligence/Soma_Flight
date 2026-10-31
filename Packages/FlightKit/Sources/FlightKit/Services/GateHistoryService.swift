import Foundation

/// The departure gates a flight number used lately, for the flight sheet's gate prediction. Live builds use
/// `SupabaseGateHistoryService` (the `gate_history` function over gates the backend already stores: free,
/// no provider behind it); screenshot runs (`-useFakes`) use `FakeGateHistoryService`.
public protocol GateHistoryService: Sendable {
    /// The flight number's gates at `origin` (ICAO) on the days before `day` (`YYYY-MM-DD`, local at the
    /// origin), and `operator`'s gates there over the last two weeks.
    func gateHistory(ident: String, origin: String, operator: String?, day: String) async throws(APIError) -> GateHistory
}

/// No history, and no network call: the default for stores built without a service.
public struct UnavailableGateHistoryService: GateHistoryService {
    public init() {}
    public func gateHistory(ident: String, origin: String, operator: String?, day: String) async throws(APIError) -> GateHistory {
        GateHistory()
    }
}

/// Believable gate history for screenshot runs and tests. A flight number that has a departure gate on the
/// seed's boards used it on six of the last seven days and the gate two along on the other; any other gets
/// one from an FNV-1a hash of the flight number, so a flight always shows the same guess. The airline's
/// gates are the same concourse, busiest first.
public actor FakeGateHistoryService: GateHistoryService {
    public var nextError: APIError?
    private let boardGates: [String: (gate: String, terminal: String?)]

    public init() {
        var gates: [String: (gate: String, terminal: String?)] = [:]
        for board in FakeSeed.boards(shift: 0) where board.kind == .departures {
            for f in board.flights {
                guard let g = f.gateOrigin else { continue }
                gates["\(f.ident)|\(f.originIcao)"] = (g, f.terminalOrigin)
            }
        }
        boardGates = gates
    }

    public func setNextError(_ error: APIError?) { nextError = error }

    public func gateHistory(ident: String, origin: String, operator: String?, day: String) async throws(APIError) -> GateHistory {
        if let e = nextError { nextError = nil; throw e }
        let seeded = boardGates["\(ident)|\(origin)"]
        let h = FakeInsightsService.fnv1a("\(ident)|\(origin)")
        let letters = ["A", "B", "C", "D", "E"]
        let gate = seeded?.gate ?? "\(letters[Int(h % 5)])\(1 + Int((h >> 8) % 40))"
        let terminal = seeded?.terminal
        let (prefix, number) = Self.split(gate)
        let other = number.map { "\(prefix)\($0 + 2)" } ?? gate
        let days = Self.daysBefore(day, count: 7).enumerated().map { i, d in
            GateHistory.Day(day: d, gate: i == Int((h >> 16) % 7) ? other : gate, terminal: terminal)
        }
        let airline = number.map { n in
            [GateHistory.Count(gate: gate, terminal: terminal, flights: 9),
             GateHistory.Count(gate: "\(prefix)\(n + 2)", terminal: terminal, flights: 5),
             GateHistory.Count(gate: "\(prefix)\(n + 4)", terminal: terminal, flights: 3)]
        } ?? []
        return GateHistory(days: days, airline: `operator` == nil ? [] : airline)
    }

    /// "B22" is ("B", 22); "Gate" is ("Gate", nil).
    static func split(_ gate: String) -> (String, Int?) {
        let letters = String(gate.prefix { $0.isLetter })
        return (letters, Int(gate.dropFirst(letters.count)))
    }

    /// The `count` days before `day` ("YYYY-MM-DD"), newest first.
    static func daysBefore(_ day: String, count: Int) -> [String] {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .gmt
        let f = DateFormatter()
        f.calendar = cal; f.timeZone = .gmt; f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        guard let start = f.date(from: day) else { return [] }
        return (1...count).compactMap { cal.date(byAdding: .day, value: -$0, to: start).map(f.string) }
    }
}
