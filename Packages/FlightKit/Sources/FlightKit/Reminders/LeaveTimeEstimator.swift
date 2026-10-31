import Foundation
import Observation
import SwiftUI

/// The "I have TSA PreCheck" switch in Settings, kept in the app's defaults.
public enum LeaveTimeSettings {
    public static let precheckKey = "leave.precheck"

    public static func precheck(_ defaults: UserDefaults = .standard) -> Bool { defaults.bool(forKey: precheckKey) }
}

/// Why a flight's leave time is the fixed rule rather than computed, for the breakdown's last line.
public enum LeaveTimeGap: Sendable, Equatable {
    /// Location is not allowed (yet, or at all).
    case location(LocationAccess)
    /// The flight leaves more than `LeaveTimeEstimator.window` from now: where the traveller is now says
    /// little about the drive on the day.
    case notYet
    /// The aircraft type is not known, so neither is the boarding call.
    case aircraft
    /// The departure airport has no security figure (outside the US, or the call failed).
    case security
    /// MapKit had no route or no network.
    case route
    /// The departure airport is not in the app's list.
    case airport
}

/// Measures, in the foreground and only while the flight sheet is open, what the computed leave time
/// needs (the drive and the security queue) and keeps the last measure per flight, so the leave
/// reminder uses it later without asking for the location again. Everything else comes from the flight.
@MainActor @Observable
public final class LeaveTimeEstimator {
    /// A measure is taken only within this time before departure.
    public static let window: TimeInterval = 12 * 3600
    /// A newer measure is not taken within this time of the last one.
    public static let remeasureAfter: TimeInterval = 10 * 60
    static let defaultsKey = "leave.measures"

    public private(set) var measures: [Flight.ID: LeaveTimeMeasure] = [:]
    /// Why the last attempt for a flight gave no computed time.
    public private(set) var gaps: [Flight.ID: LeaveTimeGap] = [:]
    /// Called after a new measure is kept; the home re-runs the reminders with it.
    @ObservationIgnored public var onChange: (@MainActor () -> Void)?

    @ObservationIgnored private let travel: any TravelTimeProvider
    @ObservationIgnored private let security: any SecurityWaitService
    @ObservationIgnored public let lookup: @Sendable (String) -> Airport?
    @ObservationIgnored private let reference: ReferenceData
    @ObservationIgnored private let precheck: @MainActor () -> Bool
    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private let now: @Sendable () -> Date

    /// - Parameters:
    ///   - precheck: the traveller's PreCheck switch, read at each use.
    ///   - defaults: where the measures are kept between launches; nil keeps them in memory.
    public init(travel: any TravelTimeProvider, security: any SecurityWaitService,
                lookup: @escaping @Sendable (String) -> Airport?, reference: ReferenceData,
                precheck: @escaping @MainActor () -> Bool = { LeaveTimeSettings.precheck() },
                defaults: UserDefaults? = .standard, now: @escaping @Sendable () -> Date = { .now }) {
        self.travel = travel; self.security = security; self.lookup = lookup; self.reference = reference
        self.precheck = precheck; self.defaults = defaults; self.now = now
        if let data = defaults?.data(forKey: Self.defaultsKey),
           let kept = try? JSONDecoder().decode([Flight.ID: LeaveTimeMeasure].self, from: data) {
            // Measures older than a day belong to flights long gone.
            measures = kept.filter { now().timeIntervalSince($0.value.measuredAt) < 24 * 3600 }
        }
    }

    /// The estimator a launch runs on: MapKit and the backend's security waits, or a fixed drive with the
    /// fakes (`-useFakes`).
    public static func forLaunch(env: AppEnvironment,
                                 arguments: [String] = ProcessInfo.processInfo.arguments) -> LeaveTimeEstimator {
        let fakes = AppEnvironment.usesFakes(arguments)
        return LeaveTimeEstimator(travel: fakes ? FakeTravelTime() : MapKitTravelTime(), security: env.security,
                                  lookup: env.lookup, reference: env.reference, defaults: fakes ? nil : .standard)
    }

    public var locationAccess: LocationAccess { travel.access }

    /// The flight's leave time from what is known now; nil for a flight that has left or has no schedule.
    public func leaveTime(for flight: Flight) -> LeaveTime? {
        LeaveTimePlanner.plan(for: flight, origin: lookup(flight.originIcao), destination: lookup(flight.destinationIcao),
                              aircraft: flight.aircraftType.flatMap { reference.type($0) },
                              measure: measures[flight.id], precheck: precheck())
    }

    /// The departure airport's clock, for the times on screen.
    public func timeZone(for flight: Flight) -> TimeZone { lookup(flight.originIcao)?.timeZone ?? .current }

    /// Measures the drive and the queue for `flight` when it leaves within `window` and location is
    /// allowed; never asks for the location (`requestLocation` does, on the traveller's tap). Records why
    /// when it cannot. A measure younger than `remeasureAfter` is kept as it is.
    public func measure(_ flight: Flight) async {
        guard let scheduled = flight.scheduledOut, flight.actualOut == nil else { return }
        let at = now()
        if let last = measures[flight.id], at.timeIntervalSince(last.measuredAt) < Self.remeasureAfter {
            gaps[flight.id] = nil
            return
        }
        guard let origin = lookup(flight.originIcao) else { return gap(flight, .airport) }
        guard travel.access == .allowed else { return gap(flight, .location(travel.access)) }
        guard scheduled.timeIntervalSince(at) <= Self.window else { return gap(flight, .notYet) }
        guard flight.aircraftType.flatMap({ reference.type($0) }) != nil else { return gap(flight, .aircraft) }
        let drive: TimeInterval
        do { drive = try await travel.drivingTime(to: origin) } catch { return gap(flight, .route) }
        guard let wait = try? await security.securityWait(airport: flight.originIcao),
              SecurityWaitFacts.shortest(wait, terminal: flight.terminalOrigin).standard != nil
        else { return gap(flight, .security) }
        measures[flight.id] = LeaveTimeMeasure(drive: drive, wait: wait, terminal: flight.terminalOrigin, measuredAt: at)
        gaps[flight.id] = nil
        save()
        onChange?()
    }

    /// Asks for "when in use" location (the breakdown's button), then measures `flight` when allowed.
    public func requestLocation(for flight: Flight) async {
        if await travel.requestAccess() == .allowed { await measure(flight) } else { gap(flight, .location(travel.access)) }
    }

    private func gap(_ flight: Flight, _ why: LeaveTimeGap) { gaps[flight.id] = why }

    private func save() {
        guard let defaults, let data = try? JSONEncoder().encode(measures) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}

// MARK: - Environment

extension EnvironmentValues {
    /// The leave time estimator the flight sheet's "Leave by" row reads; nil hides the row.
    @Entry public var leaveTimes: LeaveTimeEstimator? = nil
}
