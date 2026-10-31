import Foundation

/// The security (TSA) wait at a US airport, checkpoint by checkpoint, from `security-wait`. `isLive` is
/// true only when a live source measured the minutes; otherwise they are an estimate from typical traffic
/// at this hour, and every screen says so. There is no live source today (docs/data-sources.md).
public struct SecurityWait: Sendable, Hashable {
    public var airportIcao: String
    public var iata: String?
    public var isLive: Bool
    public var source: Source
    /// When the backend built the answer: the time the minutes are for.
    public var fetchedAt: Date
    /// Sorted by terminal, then name.
    public var checkpoints: [SecurityCheckpoint]

    public struct Source: Sendable, Hashable {
        public var id: String
        public var name: String
        public var url: URL?

        public init(id: String, name: String, url: URL? = nil) { self.id = id; self.name = name; self.url = url }
    }

    public init(airportIcao: String, iata: String?, isLive: Bool, source: Source, fetchedAt: Date,
                checkpoints: [SecurityCheckpoint]) {
        self.airportIcao = airportIcao; self.iata = iata; self.isLive = isLive; self.source = source
        self.fetchedAt = fetchedAt; self.checkpoints = checkpoints
    }
}

/// One checkpoint and its wait in standard and PreCheck lanes.
public struct SecurityCheckpoint: Sendable, Hashable, Identifiable {
    /// The id of the one row that stands for every checkpoint when the airport's are not known.
    public static let allId = "all"

    public var id: String
    public var name: String
    /// The airport's own name for the terminal ("1", "B", "International"); nil when unknown or shared.
    public var terminal: String?
    /// True with PreCheck lanes, false without, nil when unknown.
    public var precheck: Bool?
    public var standardMinutes: Int?
    /// nil when the checkpoint has no PreCheck lanes.
    public var precheckMinutes: Int?

    public init(id: String, name: String, terminal: String? = nil, precheck: Bool? = nil, standardMinutes: Int?,
                precheckMinutes: Int?) {
        self.id = id; self.name = name; self.terminal = terminal; self.precheck = precheck
        self.standardMinutes = standardMinutes; self.precheckMinutes = precheckMinutes
    }

    /// The row that stands for every checkpoint of the airport.
    public var isWholeAirport: Bool { id == Self.allId }
}

/// When the security row shows, which checkpoint it names, and its words. No SwiftUI here, so the tests
/// read the exact text the screens show.
public enum SecurityWaitFacts {
    /// The row shows from this long before departure until the flight leaves the gate.
    public static let window: TimeInterval = 4 * 3600

    /// The departure the row counts down to: the estimate when there is one, else the schedule.
    static func departure(_ f: Flight) -> Date? { f.estimatedOut ?? f.scheduledOut }

    /// True from `window` before departure until the flight leaves: a scheduled (or unknown) flight that has
    /// not pushed back. A canceled or diverted flight, or one already gone, never shows the row.
    public static func isInWindow(_ f: Flight, now: Date) -> Bool {
        guard f.status == .scheduled || f.status == .unknown, f.actualOut == nil, f.actualOff == nil,
              let dep = departure(f) else { return false }
        return now >= dep.addingTimeInterval(-window) && now < dep
    }

    /// Whether to ask for the wait at all when a flight sheet opens: the flight leaves within the next
    /// 12 hours and has not left. The sheet may stay open into the window, so this is wider than it.
    public static func worthLoading(_ f: Flight, now: Date) -> Bool {
        guard f.status == .scheduled || f.status == .unknown, f.actualOut == nil,
              let dep = departure(f) else { return false }
        return dep > now && dep.timeIntervalSince(now) <= 12 * 3600
    }

    /// A terminal name reduced for comparing: lower case, without "terminal", "term" or a "T" before a
    /// number, e.g. "Terminal 4", "T4" and "4" are all "4". nil for nothing.
    static func terminalKey(_ raw: String?) -> String? {
        guard var s = raw?.lowercased().trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        for word in ["terminal", "term."] where s.hasPrefix(word) {
            s = String(s.dropFirst(word.count)).trimmingCharacters(in: .whitespaces)
        }
        if s.hasPrefix("t"), s.count > 1, s.dropFirst().allSatisfy(\.isNumber) { s.removeFirst() }
        return s.isEmpty ? nil : s
    }

    /// Whether the flight's terminal and a checkpoint's are the same: equal names, or a one-letter code for
    /// a terminal named in words ("I" and "International").
    static func sameTerminal(_ a: String?, _ b: String?) -> Bool {
        guard let x = terminalKey(a), let y = terminalKey(b) else { return false }
        if x == y { return true }
        let (short, long) = x.count <= y.count ? (x, y) : (y, x)
        return short.count == 1 && short.first!.isLetter && long.allSatisfy(\.isLetter) && long.first == short.first
    }

    /// The checkpoints the passenger can use: the ones of `terminal` when any matches, else all of them.
    public static func candidates(_ w: SecurityWait, terminal: String?) -> (checkpoints: [SecurityCheckpoint], matched: Bool) {
        let mine = w.checkpoints.filter { sameTerminal($0.terminal, terminal) }
        return mine.isEmpty ? (w.checkpoints, false) : (mine, true)
    }

    /// The shortest standard wait and the shortest PreCheck wait among the passenger's checkpoints
    /// (`candidates`); the first in list order on a tie. nil when no checkpoint has the figure.
    public static func shortest(_ w: SecurityWait, terminal: String?)
        -> (standard: SecurityCheckpoint?, precheck: SecurityCheckpoint?) {
        let pool = candidates(w, terminal: terminal).checkpoints
        func least(_ minutes: (SecurityCheckpoint) -> Int?) -> SecurityCheckpoint? {
            pool.filter { minutes($0) != nil }.min { minutes($0)! < minutes($1)! }
        }
        return (least(\.standardMinutes), least(\.precheckMinutes))
    }

    /// "15m", or "About 15m" for an estimate (`capital`) and "about 15m" inside a sentence.
    static func amount(_ minutes: Int, live: Bool, capital: Bool = true) -> String {
        live ? Format.minutes(minutes) : "\(capital ? "About" : "about") \(Format.minutes(minutes))"
    }

    /// "Live at 07:30" or "Estimate for 07:30": what the figure is and when it is for.
    public static func stamp(_ w: SecurityWait, timeZone: TimeZone, clock: TimeStyle = .h24) -> String {
        "\(w.isLive ? "Live at" : "Estimate for") \(Format.clock(w.fetchedAt, timeZone, clock))"
    }

    /// The PreCheck part: "PreCheck 5m", "PreCheck about 5m", with "where offered" when the checkpoint
    /// may have no PreCheck lanes.
    static func precheckText(_ c: SecurityCheckpoint, live: Bool) -> String? {
        guard let m = c.precheckMinutes else { return nil }
        let base = "PreCheck \(amount(m, live: live, capital: false))"
        return c.precheck == nil ? "\(base) where offered" : base
    }

    /// The Good to Know row: title "About 15m at security" (or "15m at security" when live), and
    /// "Terminal 3 F · PreCheck about 5m · Estimate for 07:30". nil when no checkpoint has a figure.
    public static func row(_ w: SecurityWait, terminal: String?, timeZone: TimeZone,
                           clock: TimeStyle = .h24) -> (title: String, text: String)? {
        let pick = shortest(w, terminal: terminal)
        guard let standard = pick.standard, let minutes = standard.standardMinutes else { return nil }
        var parts: [String] = []
        if !standard.isWholeAirport { parts.append(standard.name) }
        if let p = pick.precheck, let text = precheckText(p, live: w.isLive) {
            parts.append(p.id == standard.id || p.isWholeAirport ? text : "\(text) at \(p.name)")
        }
        parts.append(stamp(w, timeZone: timeZone, clock: clock))
        return ("\(amount(minutes, live: w.isLive)) at security", parts.joined(separator: " · "))
    }

    /// One checkpoint's line in the lists: "About 15m · PreCheck about 5m", "20m", or "No figure".
    public static func checkpointText(_ c: SecurityCheckpoint, live: Bool) -> String {
        guard let m = c.standardMinutes else { return "No figure" }
        return ([amount(m, live: live)] + [precheckText(c, live: live)].compactMap { $0 }).joined(separator: " · ")
    }

    /// The checkpoint's terminal as a caption: "Terminal 3", "International"; nil when unknown.
    public static func terminalCaption(_ c: SecurityCheckpoint) -> String? {
        guard let t = c.terminal?.trimmingCharacters(in: .whitespaces), !t.isEmpty else { return nil }
        return t.count <= 3 ? "Terminal \(t)" : t
    }

    /// The footnote under every list: where the figures come from and, for an estimate, that it is one.
    public static func footnote(_ w: SecurityWait) -> String {
        w.isLive
            ? "Live from \(w.source.name)."
            : "\(w.source.name). An estimate from typical traffic at this hour, not a live measurement. Allow extra time."
    }
}
