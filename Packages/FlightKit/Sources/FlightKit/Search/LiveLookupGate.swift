import Foundation

/// Decides whether a pause in typing may cost a lookup. The backend allows 30 `flight-lookup` calls and
/// 120 `airport-board` calls per user per hour (`supabase/functions/_shared/limits.ts`), and each is a
/// paid AeroAPI request when its cache is cold, so search as you type stays well under that: the same
/// query is never asked twice within `reuse`, at most `budget` live lookups go out per `window`, and a
/// rate limit answer stops live lookups for `cooldown`. Pressing return is not gated (the user asked).
public struct LiveLookupGate: Sendable, Equatable {
    public var budget: Int
    public var window: TimeInterval
    public var reuse: TimeInterval
    public var cooldown: TimeInterval

    /// When each live lookup went out, oldest first.
    private(set) var sent: [Date] = []
    /// The last answer of each query key, and when it came.
    private(set) var answered: [String: Date] = [:]
    private(set) var pausedUntil: Date?

    /// Ten per hour leaves two thirds of the hourly `flight-lookup` allowance to return and to follows.
    public init(budget: Int = 10, window: TimeInterval = 3600, reuse: TimeInterval = 120, cooldown: TimeInterval = 600) {
        self.budget = budget; self.window = window; self.reuse = reuse; self.cooldown = cooldown
    }

    public enum Verdict: Equatable, Sendable { case send, reuse, wait }

    /// `.reuse` when the same query was answered recently (keep what is shown), `.wait` when the budget
    /// or a rate limit says no, `.send` otherwise. `cost` is how many calls the lookup makes: it is sent
    /// only when all of them fit the budget.
    public func verdict(for key: String, cost: Int = 1, now: Date) -> Verdict {
        if let at = answered[key], now.timeIntervalSince(at) < reuse { return .reuse }
        if let until = pausedUntil, now < until { return .wait }
        return sent.filter { now.timeIntervalSince($0) < window }.count + cost <= budget ? .send : .wait
    }

    /// A live lookup of `cost` calls went out.
    public mutating func didSend(now: Date, cost: Int = 1) {
        sent = sent.filter { now.timeIntervalSince($0) < window } + Array(repeating: now, count: max(0, cost))
    }

    /// A lookup, live or not, answered (found or not found) for `key`.
    public mutating func didAnswer(_ key: String, now: Date) {
        answered = answered.filter { now.timeIntervalSince($0.value) < reuse }
        answered[key] = now
    }

    /// The backend said too many requests (or the plan said no): no live lookups for a while.
    public mutating func didHitLimit(now: Date) {
        pausedUntil = now.addingTimeInterval(cooldown)
    }

    /// A stable key for a query: kind, codes and day.
    public static func key(_ q: FlightQuery, calendar: Calendar = .current) -> String {
        func day(_ d: Date) -> String {
            let c = calendar.dateComponents([.year, .month, .day], from: d)
            return "\(c.year ?? 0)-\(c.month ?? 0)-\(c.day ?? 0)"
        }
        switch q {
        case .ident(let i, let d): return "ident:\(i):\(day(d))"
        case .route(let o, let d, let date): return "route:\(o)-\(d):\(day(date))"
        case .airport(let c): return "airport:\(c)"
        }
    }
}
