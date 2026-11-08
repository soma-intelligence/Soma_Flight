import CoreLocation
import Foundation

/// Where the sun stands for an observer, from the NOAA solar position equations (the NOAA Global
/// Monitoring Laboratory solar calculator, after Jean Meeus, "Astronomical Algorithms"). No dependency,
/// no network. Good to about 0.01 degree between 1800 and 2100, far finer than a window seat needs.
public struct SolarPosition: Sendable, Equatable {
    /// Degrees above the horizon, without atmospheric refraction.
    public var geometricElevation: Double
    /// Degrees above the horizon as seen, with NOAA's standard refraction correction (sea level, 10 C).
    public var elevation: Double
    /// Degrees clockwise from true north, 0..<360.
    public var azimuth: Double
    /// Solar declination, degrees.
    public var declination: Double
    /// Equation of time, minutes (apparent minus mean solar time).
    public var equationOfTimeMinutes: Double

    /// The sun at `time` seen from `coordinate`.
    public static func at(_ coordinate: CLLocationCoordinate2D, time: Date) -> SolarPosition {
        let rad = Double.pi / 180, deg = 180 / Double.pi
        let jd = time.timeIntervalSince1970 / 86_400 + 2_440_587.5
        let t = (jd - 2_451_545) / 36_525

        let l0 = (280.46646 + t * (36_000.76983 + t * 0.0003032)).truncatingRemainder(dividingBy: 360)
        let m = 357.52911 + t * (35_999.05029 - 0.0001537 * t)
        let e = 0.016708634 - t * (0.000042037 + 0.0000001267 * t)
        let c = sin(m * rad) * (1.914602 - t * (0.004817 + 0.000014 * t))
            + sin(2 * m * rad) * (0.019993 - 0.000101 * t) + sin(3 * m * rad) * 0.000289
        let trueLong = l0 + c
        let omega = 125.04 - 1_934.136 * t
        let appLong = trueLong - 0.00569 - 0.00478 * sin(omega * rad)
        let eps0 = 23 + (26 + (21.448 - t * (46.815 + t * (0.00059 - t * 0.001813))) / 60) / 60
        let eps = eps0 + 0.00256 * cos(omega * rad)
        let decl = asin(sin(eps * rad) * sin(appLong * rad)) * deg

        let y = pow(tan(eps * rad / 2), 2)
        let eot = 4 * deg * (y * sin(2 * l0 * rad) - 2 * e * sin(m * rad)
                             + 4 * e * y * sin(m * rad) * cos(2 * l0 * rad)
                             - 0.5 * y * y * sin(4 * l0 * rad) - 1.25 * e * e * sin(2 * m * rad))

        // Minutes past 00:00 UTC, then true solar time at the observer's longitude.
        var dayFraction = (jd + 0.5).truncatingRemainder(dividingBy: 1)
        if dayFraction < 0 { dayFraction += 1 }
        var tst = (dayFraction * 1_440 + eot + 4 * coordinate.longitude).truncatingRemainder(dividingBy: 1_440)
        if tst < 0 { tst += 1_440 }
        let hourAngle = tst / 4 < 0 ? tst / 4 + 180 : tst / 4 - 180

        let lat = coordinate.latitude * rad, d = decl * rad, h = hourAngle * rad
        let cosZenith = min(1, max(-1, sin(lat) * sin(d) + cos(lat) * cos(d) * cos(h)))
        let elevation = 90 - acos(cosZenith) * deg
        // atan2 form of NOAA's azimuth: stays defined at the poles and at the zenith.
        var azimuth = atan2(sin(h), cos(h) * sin(lat) - tan(d) * cos(lat)) * deg + 180
        azimuth = azimuth.truncatingRemainder(dividingBy: 360)
        if azimuth < 0 { azimuth += 360 }

        return SolarPosition(geometricElevation: elevation, elevation: elevation + refraction(elevation),
                             azimuth: azimuth, declination: decl, equationOfTimeMinutes: eot)
    }

    /// NOAA's approximate atmospheric refraction, degrees, for a geometric elevation in degrees.
    static func refraction(_ e: Double) -> Double {
        if e > 85 { return 0 }
        let te = tan(e * .pi / 180)
        let arcsec: Double
        if e > 5 {
            arcsec = 58.1 / te - 0.07 / pow(te, 3) + 0.000086 / pow(te, 5)
        } else if e > -0.575 {
            arcsec = 1_735 + e * (-518.2 + e * (103.4 + e * (-12.79 + e * 0.711)))
        } else {
            arcsec = -20.772 / te
        }
        return arcsec / 3_600
    }
}

/// The sun at `time` seen from `coord`: elevation and azimuth (`SolarPosition`).
public func sun(at time: Date, coord: CLLocationCoordinate2D) -> SolarPosition {
    SolarPosition.at(coord, time: time)
}
