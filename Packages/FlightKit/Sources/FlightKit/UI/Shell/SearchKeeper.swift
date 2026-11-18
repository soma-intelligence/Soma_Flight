import Foundation

/// Keeps the last Search for a while after it closes (I11): opening Search again within `keepFor` brings
/// back the same store, so the typed query and its results are still there. Opening a result closes the
/// sheet, and the way back finds the search as it was. A store left longer, or one whose field the user
/// cleared, is replaced by a fresh one.
@MainActor
public final class SearchKeeper {
    /// How long a closed Search stays ready to come back.
    public static let keepFor: TimeInterval = 5 * 60

    public private(set) var current: SearchStore?
    private var closedAt: Date?
    private let keepFor: TimeInterval

    public init(keepFor: TimeInterval = SearchKeeper.keepFor) { self.keepFor = keepFor }

    /// The store for a Search opening now: the last one when it closed less than `keepFor` ago and still
    /// holds a query, else `make()`'s. A store that is still open is always kept.
    public func open(now: Date = .now, make: () -> SearchStore) -> SearchStore {
        if let current, Self.reuses(current, closedAt: closedAt, now: now, keepFor: keepFor) {
            closedAt = nil
            current.clearFollowError()
            return current
        }
        let fresh = make()
        current = fresh
        closedAt = nil
        return fresh
    }

    /// Search closed at `now`; its store stays for the closing sheet and for a reopening soon after.
    public func close(now: Date = .now) {
        if closedAt == nil { closedAt = now }
    }

    /// Drops the kept store (an account change).
    public func forget() {
        current = nil
        closedAt = nil
    }

    /// True when a Search closed at `closedAt` (nil: still open) is worth bringing back at `now`.
    static func reuses(_ store: SearchStore, closedAt: Date?, now: Date, keepFor: TimeInterval) -> Bool {
        guard let closedAt else { return true }
        let typed = !store.text.trimmingCharacters(in: .whitespaces).isEmpty
        return typed && now.timeIntervalSince(closedAt) < keepFor
    }
}
