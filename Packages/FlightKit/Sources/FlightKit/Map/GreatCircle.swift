import CoreLocation
import FlightCore

// Geo math lives in the Rust core; these wrappers only convert coordinate types.

/// Points along the great circle from `from` to `to`, `segments + 1` of them, endpoints included.
/// Longitudes come back unwrapped from the core (they may leave [-180, 180] but neighbours never
/// differ by 180 degrees or more). Use `mapSegments` before handing them to MapKit.
public func greatCircle(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D, segments: Int = 64) -> [CLLocationCoordinate2D] {
    let n = UInt32(clamping: max(1, segments))
    return FlightCore.greatCircle(a: Coord(from), b: Coord(to), segments: n).map(CLLocationCoordinate2D.init)
}

/// Great-circle distance in kilometres.
public func distanceKm(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
    FlightCore.distanceKm(a: Coord(a), b: Coord(b))
}

/// Normalises longitudes to [-180, 180] and splits the line where it crosses the antimeridian,
/// adding the interpolated crossing point to both sides. Each returned run is safe for `MapPolyline`.
public func mapSegments(_ points: [CLLocationCoordinate2D]) -> [[CLLocationCoordinate2D]] {
    guard let first = points.first else { return [] }
    var runs: [[CLLocationCoordinate2D]] = []
    var current = [CLLocationCoordinate2D(latitude: first.latitude, longitude: normalizedLongitude(first.longitude))]
    for (a, b) in zip(points, points.dropFirst()) {
        let la = normalizedLongitude(a.longitude)
        let lb = normalizedLongitude(b.longitude)
        if abs(lb - la) > 180 {
            // Crossing: walk from la towards lb the short way and find where it hits +/-180.
            let edge: Double = la > 0 ? 180 : -180
            let lbUnwrapped = la > 0 ? lb + 360 : lb - 360
            let t = (edge - la) / (lbUnwrapped - la)
            let lat = a.latitude + (b.latitude - a.latitude) * t
            current.append(CLLocationCoordinate2D(latitude: lat, longitude: edge))
            runs.append(current)
            current = [CLLocationCoordinate2D(latitude: lat, longitude: -edge)]
        }
        current.append(CLLocationCoordinate2D(latitude: b.latitude, longitude: lb))
    }
    runs.append(current)
    return runs
}

func normalizedLongitude(_ lon: Double) -> Double {
    var l = lon.truncatingRemainder(dividingBy: 360)
    if l > 180 { l -= 360 }
    if l < -180 { l += 360 }
    return l
}

private extension Coord {
    init(_ c: CLLocationCoordinate2D) { self.init(lat: c.latitude, lon: c.longitude) }
}

private extension CLLocationCoordinate2D {
    init(_ c: Coord) { self.init(latitude: c.lat, longitude: c.lon) }
}
