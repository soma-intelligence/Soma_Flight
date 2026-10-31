import Foundation
import Observation

/// The watch app's state: the last snapshot the iPhone sent, kept in the watch's App Group so the app and
/// its complications work offline. The phone is the only source in v1; the watch never calls the network.
@MainActor @Observable
public final class WatchFlightsModel {
    /// The last snapshot received; nil until the phone has sent one.
    public private(set) var snapshot: WatchSnapshot?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let reloadComplications: @MainActor () -> Void

    /// - Parameters:
    ///   - defaults: the watch's App Group (`SharedSettings.defaults`); tests pass their own.
    ///   - reloadComplications: redraws the complications after a new snapshot (WidgetKit's
    ///     `reloadAllTimelines` in the app).
    public init(defaults: UserDefaults = SharedSettings.defaults, reloadComplications: @escaping @MainActor () -> Void = {}) {
        self.defaults = defaults; self.reloadComplications = reloadComplications
        snapshot = WatchSnapshotStore.load(from: defaults)
    }

    /// The phone has sent at least one snapshot, so an empty list means nothing is followed (rather
    /// than the phone not having synced yet).
    public var hasSynced: Bool { snapshot != nil }

    /// Takes a snapshot from the phone: keeps it and redraws the complications when what they show
    /// changed. False when it changed nothing.
    @discardableResult
    public func receive(_ new: WatchSnapshot) -> Bool {
        if let snapshot, snapshot.sameContent(as: new) {
            // Same flights: keep the newer write time for "Updated", without a complication reload.
            self.snapshot = new
            WatchSnapshotStore.save(new, to: defaults)
            return false
        }
        snapshot = new
        WatchSnapshotStore.save(new, to: defaults)
        reloadComplications()
        return true
    }

    /// My Flights at `date`, in the widgets' order: in the air first, then by departure; landed flights
    /// leave an hour after their arrival.
    public func rows(at date: Date) -> [FlightWidgetDisplay] {
        guard let snapshot else { return [] }
        return snapshot.flights.flights(at: date).map { FlightWidgetDisplay($0, at: date, twelveHour: snapshot.twelveHour) }
    }

    /// The flight screen of `id` at `date`; nil when the snapshot no longer has it.
    public func detail(for id: UUID, at date: Date) -> WatchFlightDetail? {
        guard let snapshot, let flight = snapshot.flights.flights.first(where: { $0.id == id }) else { return nil }
        return WatchFlightDetail(FlightWidgetDisplay(flight, at: date, twelveHour: snapshot.twelveHour),
                                 extras: snapshot.extras(for: id))
    }

    /// "Updated just now", "Updated 12 min ago", "Updated 3 hr ago", "Updated Oct 29": when the phone
    /// wrote the snapshot. Nil before the first one.
    public func updatedText(at date: Date) -> String? {
        guard let written = snapshot?.flights.generatedAt else { return nil }
        let minutes = Int(date.timeIntervalSince(written) / 60)
        if minutes < 1 { return "Updated just now" }
        if minutes < 60 { return "Updated \(minutes) min ago" }
        if minutes < 24 * 60 { return "Updated \(minutes / 60) hr ago" }
        let style = Date.FormatStyle(locale: Locale(identifier: "en_US_POSIX")).month(.abbreviated).day()
        return "Updated \(written.formatted(style))"
    }
}

/// How much the complications matter in the Smart Stack around a flight. The next flight rises from
/// four hours before its departure, peaks from an hour before it until half an hour after the arrival,
/// and sits in between while in the air; otherwise the complication is not relevant.
public enum WatchRelevance {
    /// Smart Stack score at `date` for the snapshot's next flight, 0...1.
    public static func score(for snapshot: WidgetSnapshot, at date: Date) -> Float {
        guard let next = snapshot.flights(at: date).first else { return 0 }
        switch next.status {
        case .canceled: return 0
        case .landed, .arrived, .diverted:
            guard let landed = next.bestIn ?? next.scheduledIn else { return 0 }
            return date <= landed.addingTimeInterval(30 * 60) ? 0.8 : 0
        case .departed, .enRoute:
            // Near the end the traveller looks for the belt and the gate again.
            if let end = next.bestIn, end.timeIntervalSince(date) <= 30 * 60 { return 1 }
            return 0.6
        case .scheduled, .unknown:
            guard let out = next.bestOut ?? next.scheduledOut else { return 0 }
            let before = out.timeIntervalSince(date)
            if before > 4 * 3600 { return 0 }
            if before > 3600 { return 0.5 }
            // From an hour out, and past the departure time while still at the gate.
            return 1
        }
    }
}
