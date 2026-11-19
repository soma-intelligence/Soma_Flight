import CoreLocation
import Foundation

/// The light of the sky at a place and time, from the sun's elevation (`SolarPosition`): the plane card
/// paints its backdrop after it. Civil twilight bounds the night (sun 6 degrees under the horizon), the
/// golden hour bounds the day (6 degrees above); in between the sky is warm, dawn when the sun climbs and
/// dusk when it sinks.
public enum SkyPhase: String, Sendable, Hashable, CaseIterable {
    case night, dawn, day, dusk

    /// Sun this far under the horizon or lower: night.
    static let nightBelow = -6.0
    /// Sun this far above the horizon or higher: day.
    static let dayAbove = 6.0

    /// The phase for a sun at `elevation` degrees, climbing (`rising`) or sinking.
    public static func from(elevation: Double, rising: Bool) -> SkyPhase {
        if elevation < nightBelow { return .night }
        if elevation >= dayAbove { return .day }
        return rising ? .dawn : .dusk
    }

    /// The phase seen from `coordinate` at `time`. Rising or sinking comes from the sun ten minutes later,
    /// which holds in both hemispheres and near the poles, where the azimuth says little.
    public static func at(_ coordinate: CLLocationCoordinate2D, time: Date) -> SkyPhase {
        let now = SolarPosition.at(coordinate, time: time).elevation
        let later = SolarPosition.at(coordinate, time: time.addingTimeInterval(600)).elevation
        return from(elevation: now, rising: later > now)
    }
}
