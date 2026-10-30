import Foundation

/// When the widgets must redraw. The snapshot only changes when the app writes it (and reloads the
/// timelines then), so between writes the display changes with the clock alone: the countdown steps
/// down, a flight passes its departure or arrival time, the progress moves, a landed flight drops off.
/// An entry sits at each of those moments and nowhere else.
public enum WidgetTimeline {
    /// How far ahead entries are planned; the timeline reloads at its end.
    public static let horizon: TimeInterval = 12 * 3600
    /// Entries in one timeline at most (the earliest are kept).
    public static let maxEntries = 180
    /// The progress bar and ring move in steps of this while a flight is in the air.
    public static let progressStep: TimeInterval = 5 * 60
    /// The widgets that list flights show this many.
    public static let listed = 4
    /// A countdown rounds down, so "3 HRS" turns to "2 HRS" just after the three hour mark, not on it: its
    /// entry sits this much after the mark.
    static let pastMark: TimeInterval = 1

    /// The dates to draw, `now` first, sorted, each one a moment the display can change, up to `horizon`
    /// ahead and `maxEntries` long. Only the flights a widget can show count (`listed`, in the order
    /// they are listed at `now`).
    public static func entryDates(for snapshot: WidgetSnapshot, now: Date) -> [Date] {
        let end = now.addingTimeInterval(horizon)
        var marks = Set<Date>()
        for f in snapshot.flights(at: now).prefix(listed) {
            for d in changes(of: f, from: now, to: end) { marks.insert(d) }
        }
        let later = marks.filter { $0 > now && $0 <= end }.sorted()
        return [now] + later.prefix(maxEntries - 1)
    }

    /// When WidgetKit should ask again: at the last entry when there is one after `now`, else at the
    /// horizon. Nothing followed asks never: the app reloads the timelines when the list changes.
    public static func reloadDate(for snapshot: WidgetSnapshot, entries: [Date], now: Date) -> Date? {
        guard !snapshot.flights(at: now).isEmpty else { return nil }
        if let last = entries.last, last > now { return last }
        return now.addingTimeInterval(horizon)
    }

    /// The moments in `from...to` where `f`'s widgets change.
    static func changes(of f: WidgetFlight, from start: Date, to end: Date) -> [Date] {
        var out: [Date] = []
        func add(_ d: Date?) { if let d, d > start, d <= end { out.append(d) } }
        // Departure and arrival times: "DEPARTING", the arrival taking the lead, "ARRIVING"; and the hour
        // after the arrival, when the flight drops off.
        add(f.bestOut)
        add(f.bestIn)
        add(f.droppedAt)
        switch f.status {
        case .scheduled, .unknown:
            if let out = f.bestOut { countdownMarks(to: out, from: start, to: end).forEach { add($0) } }
        case .departed, .enRoute:
            if let inn = f.bestIn {
                // "2h LEFT" by the hour, then "40m LEFT" by the minute.
                let left = inn.timeIntervalSince(start)
                for h in stride(from: 1, through: Int(left / 3600), by: 1) {
                    add(inn.addingTimeInterval(-Double(h) * 3600 + pastMark))
                }
                for m in 1..<60 { add(inn.addingTimeInterval(-Double(m) * 60 + pastMark)) }
                // The progress, every `progressStep` from now to the arrival.
                var t = start.addingTimeInterval(progressStep)
                while t < inn, t <= end { add(t); t = t.addingTimeInterval(progressStep) }
            }
        default:
            break
        }
        return out
    }

    /// Where the countdown to `out` changes figure: just past each day mark over a day out, each hour
    /// mark under a day, each minute mark under an hour (the countdown rounds down).
    static func countdownMarks(to out: Date, from start: Date, to end: Date) -> [Date] {
        let left = out.timeIntervalSince(start)
        guard left > 0 else { return [] }
        var marks: [Date] = []
        if left >= 86_400 {
            for d in 1...Int(left / 86_400) { marks.append(out.addingTimeInterval(-Double(d) * 86_400 + pastMark)) }
        }
        for h in 1...23 { marks.append(out.addingTimeInterval(-Double(h) * 3600 + pastMark)) }
        for m in 1...59 { marks.append(out.addingTimeInterval(-Double(m) * 60 + pastMark)) }
        return marks.filter { $0 > start && $0 <= end }
    }
}
