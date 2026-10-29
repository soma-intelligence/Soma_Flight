// Replays every case of core/fixtures/*.json (copied into Fixtures/ by
// core/scripts/build-xcframework.sh) through the Swift binding, with the same
// semantics as core/flightcore/tests/fixtures.rs and
// supabase/functions/_shared/flightcore_test.ts.
import Foundation
import Testing
import FlightCore

// MARK: - Fixture loading

private func fixture(_ name: String) throws -> [String: Any] {
    let url = try #require(
        Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"),
        "missing fixture \(name).json"
    )
    let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
    return try #require(obj as? [String: Any])
}

private func cases(_ file: [String: Any], _ key: String = "cases") throws -> [[String: Any]] {
    try #require(file[key] as? [[String: Any]], "no \(key)")
}

private func double(_ v: Any?) -> Double? { (v as? NSNumber)?.doubleValue }
private func int64(_ v: Any?) -> Int64? { (v as? NSNumber)?.int64Value }
private func int32(_ v: Any?) -> Int32? { (v as? NSNumber)?.int32Value }
private func uint32(_ v: Any?) -> UInt32? { (v as? NSNumber)?.uint32Value }
private func string(_ v: Any?) -> String? { v as? String }

private func coord(_ v: Any?) throws -> Coord {
    let d = try #require(v as? [String: Any])
    return Coord(lat: try #require(double(d["lat"])), lon: try #require(double(d["lon"])))
}

/// JSON equality through Foundation (NSNumber compares by value, NSNull for null).
private func jsonEqual(_ a: Any, _ b: Any) -> Bool {
    (a as AnyObject).isEqual(b as AnyObject)
}

private func json(_ v: Any) -> String {
    guard let d = try? JSONSerialization.data(withJSONObject: v, options: [.sortedKeys]) else {
        return "\(v)"
    }
    return String(decoding: d, as: UTF8.self)
}

// MARK: - Geo

@Test func geoMeta() throws {
    let meta = try #require(try fixture("geo")["meta"] as? [String: Any])
    #expect(double(meta["radius_km"]) == 6371.0088)
    let inv = try #require(meta["invariants"] as? [String: Any])
    #expect(uint32(inv["segments_zero_clamps_to"]) == 1)
}

@Test func geoDistances() throws {
    let all = try cases(try fixture("geo"), "distance_km")
    #expect(!all.isEmpty)
    for c in all {
        let name = string(c["name"]) ?? "?"
        let d = distanceKm(a: try coord(c["a"]), b: try coord(c["b"]))
        let expected = try #require(double(c["expected"]))
        let tolerance = try #require(double(c["tolerance"]))
        #expect(abs(d - expected) <= tolerance, "\(name): \(d) vs \(expected)")
    }
}

@Test func geoGreatCircles() throws {
    let g = try fixture("geo")
    let inv = try #require((g["meta"] as? [String: Any])?["invariants"] as? [String: Any])
    let maxDelta = try #require(double(inv["neighbour_lon_delta_lt"]))
    let clamp = try #require(uint32(inv["segments_zero_clamps_to"]))
    let all = try cases(g, "great_circle")
    #expect(!all.isEmpty)
    for c in all {
        let n = string(c["name"]) ?? "?"
        let a = try coord(c["a"])
        let b = try coord(c["b"])
        let segments = try #require(uint32(c["segments"]))
        let p = greatCircle(a: a, b: b, segments: segments)
        #expect(p.count == (c["expected_len"] as? Int), "\(n): len \(p.count)")
        #expect(p.count == Int(max(segments, clamp)) + 1, "\(n): clamp")
        #expect(p.first == a, "\(n): first")
        let last = try #require(p.last)
        #expect(last.lat == b.lat, "\(n): last lat")
        let k = (last.lon - b.lon) / 360
        #expect(abs(k - k.rounded()) < 1e-9, "\(n): end lon not b mod 360")
        for i in p.indices.dropFirst() {
            #expect(abs(p[i].lon - p[i - 1].lon) < maxDelta, "\(n): neighbour jump at \(i)")
        }
        if let l = double(c["expected_last_lon"]) {
            #expect(abs(last.lon - l) < 1e-3, "\(n): last lon \(last.lon)")
        }
        for s in (c["samples"] as? [[String: Any]]) ?? [] {
            let i = try #require(s["index"] as? Int)
            let tol = try #require(double(s["tolerance"]))
            guard p.indices.contains(i) else {
                Issue.record("\(n): sample index \(i) out of range 0..<\(p.count)")
                continue
            }
            let q = p[i]
            #expect(abs(q.lat - (double(s["lat"]) ?? .nan)) <= tol, "\(n)[\(i)] lat \(q.lat)")
            #expect(abs(q.lon - (double(s["lon"]) ?? .nan)) <= tol, "\(n)[\(i)] lon \(q.lon)")
        }
        if (c["all_equal_a"] as? Bool) == true {
            #expect(p.allSatisfy { $0 == a }, "\(n): not all equal a")
        }
    }
}

// MARK: - Delay stats

private func flightStatus(_ s: String) -> FlightStatus {
    switch s {
    case "scheduled": .scheduled
    case "departed": .departed
    case "en_route": .enRoute
    case "landed": .landed
    case "arrived": .arrived
    case "canceled": .canceled
    case "diverted": .diverted
    default: .unknown  // serde(other) in the core crate
    }
}

private func boardFlight(_ v: [String: Any]) throws -> BoardFlight {
    BoardFlight(
        ident: try #require(string(v["ident"])),
        operator: string(v["operator"]),
        otherIcao: try #require(string(v["other_icao"])),
        status: flightStatus(try #require(string(v["status"]))),
        scheduled: int64(v["scheduled"]),
        estimated: int64(v["estimated"]),
        actual: int64(v["actual"])
    )
}

private func severityName(_ s: Severity) -> String {
    switch s {
    case .normal: "normal"
    case .moderate: "moderate"
    case .major: "major"
    }
}

/// Same shape as the core crate's serde output (camelCase keys).
private func statsJSON(_ s: DelayStats) -> [String: Any] {
    [
        "total": s.total,
        "onTime": s.onTime,
        "delayed15": s.delayed15,
        "canceled": s.canceled,
        "avgDelayMinutes": s.avgDelayMinutes,
        "perHour": s.perHour.map {
            [
                "hour": $0.hour, "onTime": $0.onTime, "late15": $0.late15,
                "late45": $0.late45, "canceled": $0.canceled, "diverted": $0.diverted,
            ] as [String: Any]
        },
        "worstRoutes": s.worstRoutes.map {
            ["icao": $0.icao, "delayed": $0.delayed, "canceled": $0.canceled] as [String: Any]
        },
        "worstAirlines": s.worstAirlines.map {
            ["operator": $0.operator, "delayed": $0.delayed, "canceled": $0.canceled] as [String: Any]
        },
        "severity": severityName(s.severity),
    ]
}

@Test func delayCases() throws {
    let f = try fixture("delay_stats")
    let rules = try #require((f["meta"] as? [String: Any])?["rules"] as? [String: Any])
    let tol = try #require(double(rules["avg_delay_tolerance"]))
    let all = try cases(f)
    #expect(!all.isEmpty)
    for c in all {
        let n = string(c["name"]) ?? "?"
        let rows = try #require(c["rows"] as? [[String: Any]]).map(boardFlight)
        var expected = try #require(c["expected"] as? [String: Any])
        let got = computeStats(rows: rows)
        #expect(!got.avgDelayMinutes.isNaN, "\(n): NaN")
        let expAvg = try #require(double(expected["avgDelayMinutes"]))
        #expect(abs(got.avgDelayMinutes - expAvg) <= tol, "\(n): avg \(got.avgDelayMinutes) vs \(expAvg)")
        var g = statsJSON(got)
        g["avgDelayMinutes"] = 0
        expected["avgDelayMinutes"] = 0
        #expect(jsonEqual(g, expected), "\(n): \(json(g)) vs \(json(expected))")
    }
}

// MARK: - Flight category

private func categoryName(_ c: FlightCategory) -> String {
    switch c {
    case .vfr: "VFR"
    case .mvfr: "MVFR"
    case .ifr: "IFR"
    case .lifr: "LIFR"
    }
}

@Test func categoryCases() throws {
    let all = try cases(try fixture("category"))
    #expect(!all.isEmpty)
    for c in all {
        let n = string(c["name"]) ?? "?"
        let got = flightCategory(
            ceilingFt: int32(c["ceiling_ft"]),
            visibilitySm: try #require(double(c["visibility_sm"]))
        )
        #expect(categoryName(got) == string(c["expected"]), "\(n): \(categoryName(got))")
    }
}

@Test func nonFiniteOrNegativeVisibilityIsLifr() {
    for v in [Double.nan, .infinity, -.infinity, -1, -0.5] {
        #expect(flightCategory(ceilingFt: nil, visibilitySm: v) == .lifr, "\(v)")
        #expect(flightCategory(ceilingFt: 5000, visibilitySm: v) == .lifr, "\(v)")
    }
    #expect(flightCategory(ceilingFt: nil, visibilitySm: 10) == .vfr)
}

// MARK: - Passport

private func pastStatus(_ s: String) throws -> PastFlightStatus {
    switch s {
    case "completed": .completed
    case "canceled": .canceled
    case "diverted": .diverted
    default: throw FixtureError.unknownStatus(s)
    }
}

private enum FixtureError: Error { case unknownStatus(String) }

private func pastFlight(_ v: [String: Any]) throws -> PastFlight {
    PastFlight(
        departedAt: try #require(int64(v["departed_at"])),
        tz: try #require(string(v["tz"])),
        ident: try #require(string(v["ident"])),
        originIcao: try #require(string(v["origin_icao"])),
        destinationIcao: try #require(string(v["destination_icao"])),
        airline: string(v["airline"]),
        aircraftType: string(v["aircraft_type"]),
        distanceKm: try #require(uint32(v["distance_km"])),
        blockMinutes: uint32(v["block_minutes"]),
        delayMinutes: try #require(uint32(v["delay_minutes"])),
        status: try pastStatus(try #require(string(v["status"])))
    )
}

/// Same shape as the core crate's serde output (routes as [origin, destination]).
private func passportJSON(_ p: PassportStats) -> [String: Any] {
    [
        "flights": p.flights,
        "longHaul": p.longHaul,
        "distanceKm": p.distanceKm,
        "flightMinutes": p.flightMinutes,
        "airports": p.airports,
        "airlines": p.airlines,
        "delayLostMinutes": p.delayLostMinutes,
        "avgDelayMinutes": p.avgDelayMinutes,
        "mostFlownAircraft": p.mostFlownAircraft.map {
            ["aircraftType": $0.aircraftType, "count": $0.count] as [String: Any]
        } ?? NSNull(),
        "routes": p.routes.map { [$0.origin, $0.destination] },
    ]
}

@Test func passportCases() throws {
    let all = try cases(try fixture("passport"))
    #expect(all.count >= 20)
    for c in all {
        let n = string(c["name"]) ?? "?"
        let flights = try #require(c["flights"] as? [[String: Any]]).map(pastFlight)
        let got = passportJSON(computePassport(flights: flights, year: int32(c["year"])))
        let expected = try #require(c["expected"] as? [String: Any])
        #expect(jsonEqual(got, expected), "\(n): \(json(got)) vs \(json(expected))")
    }
}

@Test func greatCircleSegmentsAreCapped() {
    let a = Coord(lat: 0, lon: 0)
    let b = Coord(lat: 10, lon: 10)
    #expect(greatCircle(a: a, b: b, segments: .max).count == 100_001)
    #expect(greatCircle(a: a, b: b, segments: 100_000).count == 100_001)
}

@Test func unknownTimezoneAndEmptyInput() {
    #expect(computeStats(rows: []).total == 0)
    #expect(computePassport(flights: [], year: nil).flights == 0)
    let p = computePassport(
        flights: [
            PastFlight(
                departedAt: 1_700_000_000, tz: "Not/AZone", ident: "X1",
                originIcao: "KSFO", destinationIcao: "KLAX", airline: nil,
                aircraftType: nil, distanceKm: 500, blockMinutes: nil,
                delayMinutes: 0, status: .completed
            ),
        ],
        year: 2023
    )
    #expect(p.flights == 1, "unknown tz falls back to UTC")
}
