import Foundation
#if canImport(WidgetKit)
import WidgetKit
#endif

public extension WidgetSnapshot {
    /// The snapshot of My Flights at `now`: in the air first, then by scheduled departure (the order of
    /// My Flights), the first `maxFlights`, with the airports' cities and time zones from `lookup`.
    static func from(_ flights: [Flight], lookup: (String) -> Airport?, now: Date = .now) -> Self {
        func airborne(_ f: Flight) -> Bool { f.status == .departed || f.status == .enRoute }
        let ordered = flights.sorted { a, b in
            if airborne(a) != airborne(b) { return airborne(a) }
            let x = a.scheduledOut ?? .distantFuture, y = b.scheduledOut ?? .distantFuture
            return x == y ? a.id.uuidString < b.id.uuidString : x < y
        }
        return Self(generatedAt: now, flights: ordered.prefix(maxFlights).map { WidgetFlight.from($0, lookup: lookup, now: now) })
    }
}

public extension WidgetFlight {
    /// `flight` as the widgets draw it. Best times are actual, else estimated, else scheduled, as on the
    /// flight sheet; the delays are the sheet's offsets, rounded to the minute.
    static func from(_ flight: Flight, lookup: (String) -> Airport?, now: Date = .now) -> Self {
        func end(_ icao: String, _ iata: String?) -> WidgetAirport {
            let airport = lookup(icao)
            return WidgetAirport(code: iata ?? airport?.iata ?? icao, city: airport?.city, timeZone: airport?.tz)
        }
        let bestOut = flight.actualOut ?? flight.estimatedOut ?? flight.scheduledOut
        let bestIn = flight.actualIn ?? flight.estimatedIn ?? flight.scheduledIn
        return WidgetFlight(
            id: flight.id, ident: flight.ident, airlineIcao: flight.operator ?? Self.icaoDesignator(flight.ident),
            origin: end(flight.originIcao, flight.originIata),
            destination: end(flight.destinationIcao, flight.destinationIata),
            scheduledOut: flight.scheduledOut, scheduledIn: flight.scheduledIn, bestOut: bestOut, bestIn: bestIn,
            status: flight.status, gateOrigin: flight.gateOrigin, gateDestination: flight.gateDestination,
            terminalOrigin: flight.terminalOrigin, terminalDestination: flight.terminalDestination,
            // The flight sheet's offsets: nil while only the schedule is known.
            departureDelayMinutes: DetailFacts.offsetMinutes(scheduled: flight.scheduledOut,
                                                             estimated: flight.estimatedOut, actual: flight.actualOut),
            arrivalDelayMinutes: DetailFacts.offsetMinutes(scheduled: flight.scheduledIn, estimated: flight.estimatedIn,
                                                           actual: flight.actualIn ?? flight.actualOn),
            progress: FlightActivityAttributes.ContentState.progress(of: flight, at: now))
    }

    /// The three-letter designator that starts an ICAO flight number ("AFR84"); nil for an IATA one ("AF84").
    static func icaoDesignator(_ ident: String) -> String? {
        let letters = ident.prefix { $0.isLetter }
        return letters.count == 3 ? String(letters) : nil
    }
}

/// Writes the widget snapshot to the App Group whenever My Flights changes and asks WidgetKit to redraw.
/// A write that would change nothing the widgets show is skipped, reload included: My Flights reports
/// every pushed update, and background reloads come out of a daily budget.
@MainActor
public final class WidgetSnapshotWriter {
    private let defaults: UserDefaults
    private let lookup: (String) -> Airport?
    private let reload: @MainActor () -> Void
    private let now: () -> Date

    /// - Parameters:
    ///   - defaults: the App Group's (`SharedSettings.defaults`); tests pass their own.
    ///   - reload: redraws the widgets; WidgetKit's `reloadAllTimelines` by default.
    public init(defaults: UserDefaults = SharedSettings.defaults, lookup: @escaping (String) -> Airport?,
                reload: (@MainActor () -> Void)? = nil, now: @escaping () -> Date = { .now }) {
        self.defaults = defaults; self.lookup = lookup; self.now = now
        self.reload = reload ?? Self.reloadWidgets
    }

    /// Saves the snapshot of `flights` and reloads the widgets when it differs from the saved one.
    public func write(_ flights: [Flight]) {
        save(.from(flights, lookup: lookup, now: now()))
    }

    /// Nothing to show: nobody signed in.
    public func clear() {
        save(.empty(at: now()))
    }

    private func save(_ snapshot: WidgetSnapshot) {
        let data = defaults.data(forKey: WidgetSnapshotStore.key)
        if let saved = data.flatMap(WidgetSnapshot.decode), saved.sameContent(as: snapshot) { return }
        // Nothing saved and nothing to save: the widgets already show the empty state.
        if data == nil, snapshot.flights.isEmpty { return }
        guard WidgetSnapshotStore.save(snapshot, to: defaults) else { return }
        reload()
    }

    private static func reloadWidgets() {
        #if canImport(WidgetKit) && os(iOS)
        WidgetCenter.shared.reloadAllTimelines()
        // The Control Center's Next Flight control reads the same snapshot.
        ControlCenter.shared.reloadAllControls()
        #endif
    }
}
