import Foundation

/// The complications' timeline: the widgets' entry dates (`WidgetTimeline`) over the watch's snapshot,
/// each with its Smart Stack score (`WatchRelevance`). Pure, so the tests cover what the extension plans.
public enum WatchComplicationTimeline {
    public struct Entry: Sendable, Hashable {
        public var date: Date
        /// Smart Stack score, 0...1.
        public var score: Float
        /// How long the score holds: until the next entry (the last one holds an hour).
        public var duration: TimeInterval
    }

    /// The entries to draw from `now`, and when WidgetKit should ask again (nil: never, the watch app
    /// reloads the complications when the phone sends a new snapshot). Besides the widgets' moments,
    /// the relevance steps (four hours and one hour before departure, half an hour after arrival) get
    /// an entry of their own.
    public static func plan(for snapshot: WatchSnapshot?, now: Date) -> (entries: [Entry], reload: Date?) {
        guard let snapshot else { return ([Entry(date: now, score: 0, duration: 0)], nil) }
        let flights = snapshot.flights
        var dates = Set(WidgetTimeline.entryDates(for: flights, now: now))
        let end = now.addingTimeInterval(WidgetTimeline.horizon)
        for f in flights.flights(at: now).prefix(1) {
            let marks: [Date?] = [
                f.bestOut?.addingTimeInterval(-4 * 3600), f.bestOut?.addingTimeInterval(-3600),
                f.bestIn?.addingTimeInterval(-30 * 60), f.bestIn?.addingTimeInterval(30 * 60),
            ]
            for case let d? in marks where d > now && d <= end { dates.insert(d) }
        }
        let sorted = dates.sorted().prefix(WidgetTimeline.maxEntries)
        let entries = sorted.enumerated().map { i, date in
            let next = i + 1 < sorted.count ? sorted[sorted.startIndex + i + 1] : date.addingTimeInterval(3600)
            return Entry(date: date, score: WatchRelevance.score(for: flights, at: date),
                         duration: next.timeIntervalSince(date))
        }
        let reload = WidgetTimeline.reloadDate(for: flights, entries: entries.map(\.date), now: now)
        return (entries, reload)
    }
}
