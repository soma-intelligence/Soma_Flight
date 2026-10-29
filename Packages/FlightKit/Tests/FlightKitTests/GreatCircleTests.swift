import CoreLocation
import Testing
@testable import FlightKit

@Suite struct GreatCircleTests {
    let cdg = CLLocationCoordinate2D(latitude: 49.0097, longitude: 2.5479)
    let sfo = CLLocationCoordinate2D(latitude: 37.6213, longitude: -122.379)
    let hnd = CLLocationCoordinate2D(latitude: 35.5494, longitude: 139.7798)

    @Test func distanceCdgSfo() {
        let d = distanceKm(cdg, sfo)
        #expect(d > 8900 && d < 9000)
    }

    @Test func greatCircleEndpoints() {
        let pts = greatCircle(from: cdg, to: sfo, segments: 64)
        #expect(pts.count == 65)
        #expect(abs(pts[0].latitude - cdg.latitude) < 1e-9)
        #expect(abs(pts[0].longitude - cdg.longitude) < 1e-9)
        #expect(abs(pts[64].latitude - sfo.latitude) < 1e-9)
        #expect(abs(pts[64].longitude - sfo.longitude) < 1e-9)
    }

    @Test func greatCircleCrossesAntimeridian() {
        // Raw core output: unwrapped longitudes, neighbours always closer than 180 degrees.
        let pts = greatCircle(from: hnd, to: sfo, segments: 64)
        #expect(pts.count == 65)
        for (a, b) in zip(pts, pts.dropFirst()) {
            #expect(abs(b.longitude - a.longitude) < 180)
        }
        // Map form: normalised to [-180, 180] and split at the antimeridian, so no segment jumps.
        let segments = mapSegments(pts)
        #expect(segments.count == 2)
        for seg in segments {
            for p in seg { #expect(p.longitude >= -180 && p.longitude <= 180) }
            for (a, b) in zip(seg, seg.dropFirst()) { #expect(abs(b.longitude - a.longitude) < 10) }
        }
        #expect(abs(abs(segments[0].last!.longitude) - 180) < 1e-9)
        #expect(abs(abs(segments[1].first!.longitude) - 180) < 1e-9)
        #expect(abs(segments[0].last!.latitude - segments[1].first!.latitude) < 1e-9)
        #expect(abs(segments[1].last!.longitude - sfo.longitude) < 1e-9)
    }

    @Test func mapSegmentsKeepsNonCrossingRouteWhole() {
        #expect(mapSegments(greatCircle(from: cdg, to: sfo)).count == 1)
    }
}
