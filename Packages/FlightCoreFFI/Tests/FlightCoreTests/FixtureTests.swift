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

// MARK: - Weather impact

private func levelName(_ l: ImpactLevel) -> String {
    switch l {
    case .clear: "none"
    case .minor: "minor"
    case .moderate: "moderate"
    case .severe: "severe"
    }
}

private func affectsName(_ a: Affects?) -> String? {
    switch a {
    case .arrivals: "arrivals"
    case .departures: "departures"
    case .both: "both"
    case nil: nil
    }
}

private func hazardName(_ k: HazardKind) -> String {
    switch k {
    case .thunderstorm: "thunderstorm"
    case .freezingPrecip: "freezingPrecip"
    case .snow: "snow"
    case .lowCeiling: "lowCeiling"
    case .fog: "fog"
    case .lowVisibility: "lowVisibility"
    case .wind: "wind"
    case .heavyRain: "heavyRain"
    }
}

@Test func weatherImpactCases() throws {
    let file = try fixture("weather_impact")
    let all = try cases(file, "impact")
    #expect(!all.isEmpty)
    for c in all {
        let n = string(c["name"]) ?? "?"
        let input = try #require(c["conditions"] as? [String: Any])
        let got = weatherImpact(conditions: WeatherConditions(
            ceilingFt: int32(input["ceilingFt"]), visibilitySm: double(input["visibilitySm"]),
            windKt: int32(input["windKt"]), gustKt: int32(input["gustKt"]), wx: string(input["wx"]) ?? ""))
        #expect(levelName(got.level) == string(c["level"]), "\(n)")
        #expect(got.slows == (c["slows"] as? Bool), "\(n)")
        #expect(affectsName(got.affects) == string(c["affects"]), "\(n)")
        #expect(got.hazards.map { hazardName($0.kind) } == (c["hazards"] as? [String]), "\(n)")
        #expect(got.reason == string(c["reason"]), "\(n): \(got.reason)")
    }
    for c in try cases(file, "describe") {
        let wx = string(c["wx"]) ?? ""
        #expect(describeWeather(wx: wx) == string(c["text"]), "\(wx)")
    }
    for c in try cases(file, "present_weather") {
        let report = string(c["report"]) ?? ""
        #expect(presentWeather(report: report) == string(c["wx"]), "\(report)")
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

private enum FixtureError: Error {
    case unknownStatus(String)
    case unknownSeatClass(String)
    case unknownReason(String)
    case unknownPosition(String)
    case unknownRegion(String)
}

private func seatClass(_ v: Any?) throws -> SeatClass? {
    guard let s = string(v) else { return nil }
    switch s {
    case "economy": return .economy
    case "premium_economy": return .premiumEconomy
    case "business": return .business
    case "first": return .first
    case "private": return .private
    default: throw FixtureError.unknownSeatClass(s)
    }
}

private func tripReason(_ v: Any?) throws -> TripReason? {
    guard let s = string(v) else { return nil }
    switch s {
    case "personal": return .personal
    case "business": return .business
    case "crew": return .crew
    default: throw FixtureError.unknownReason(s)
    }
}

private func seatPositionValue(_ v: Any?) throws -> SeatPosition? {
    guard let s = string(v) else { return nil }
    switch s {
    case "window": return .window
    case "middle": return .middle
    case "aisle": return .aisle
    case "pilot": return .pilot
    case "captain": return .captain
    case "jumpseat": return .jumpseat
    default: throw FixtureError.unknownPosition(s)
    }
}

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
        status: try pastStatus(try #require(string(v["status"]))),
        originCountry: string(v["origin_country"]),
        destinationCountry: string(v["destination_country"]),
        airMinutes: uint32(v["air_minutes"]),
        registration: string(v["registration"]),
        seatClass: try seatClass(v["seat_class"]),
        seat: string(v["seat"]),
        reason: try tripReason(v["reason"]),
        seatPosition: try seatPositionValue(v["seat_position"])
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
        "delayedFlights": p.delayedFlights,
        "avgDelayedMinutes": p.avgDelayedMinutes,
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

// MARK: - Passport detail

private let regionNames: [(Region, String)] = [
    (.europe, "europe"), (.northAmerica, "north_america"), (.centralAmerica, "central_america"),
    (.caribbean, "caribbean"), (.southAmerica, "south_america"), (.africa, "africa"),
    (.middleEast, "middle_east"), (.asia, "asia"), (.oceania, "oceania"),
]

private func region(_ s: String) throws -> Region {
    guard let r = regionNames.first(where: { $0.1 == s })?.0 else { throw FixtureError.unknownRegion(s) }
    return r
}

private func regionName(_ r: Region) -> String {
    regionNames.first { $0.0 == r }?.1 ?? "?"
}

private func countryInfo(_ v: [String: Any]) throws -> CountryInfo {
    CountryInfo(iso2: try #require(string(v["iso2"])), region: try region(try #require(string(v["region"]))))
}

private func refJSON(_ r: FlightRef?) -> Any {
    guard let r else { return NSNull() }
    return [
        "ident": r.ident, "originIcao": r.originIcao, "destinationIcao": r.destinationIcao,
        "departedAt": r.departedAt, "distanceKm": r.distanceKm,
        "blockMinutes": r.blockMinutes.map { $0 as Any } ?? NSNull(),
        "airline": r.airline.map { $0 as Any } ?? NSNull(),
    ] as [String: Any]
}

private func talliesJSON(_ t: [Tally]) -> [[String: Any]] {
    t.map { ["key": $0.key, "flights": $0.flights, "distanceKm": $0.distanceKm] }
}

/// Same shape as the core crate's serde output (camelCase keys, snake_case regions).
private func detailJSON(_ d: PassportDetail) -> [String: Any] {
    [
        "flights": d.flights, "domestic": d.domestic, "international": d.international, "longHaul": d.longHaul,
        "perYear": d.perYear.map { ["year": $0.year, "flights": $0.flights] as [String: Any] },
        "perMonth": d.perMonth, "perWeekday": d.perWeekday,
        "distanceKm": d.distanceKm, "avgDistanceKm": d.avgDistanceKm,
        "earthRatio": d.earthRatio, "moonRatio": d.moonRatio, "sunRatio": d.sunRatio,
        "shortestByDistance": refJSON(d.shortestByDistance), "longestByDistance": refJSON(d.longestByDistance),
        "shortestByTime": refJSON(d.shortestByTime), "longestByTime": refJSON(d.longestByTime),
        "flightMinutes": d.flightMinutes, "avgFlightMinutes": d.avgFlightMinutes,
        "airMinutes": d.airMinutes, "taxiMinutes": d.taxiMinutes,
        "airports": d.airports.map { ["icao": $0.icao, "visits": $0.visits] as [String: Any] },
        "airlinesByFlights": talliesJSON(d.airlinesByFlights),
        "airlinesByDistance": talliesJSON(d.airlinesByDistance),
        "routesByFlights": talliesJSON(d.routesByFlights),
        "routesByDistance": talliesJSON(d.routesByDistance),
        "countries": d.countries.map { ["iso2": $0.iso2, "flights": $0.flights] as [String: Any] },
        "unknownCountryFlights": d.unknownCountryFlights,
        "regions": d.regions.map {
            ["region": regionName($0.region), "visited": $0.visited, "total": $0.total] as [String: Any]
        },
    ]
}

@Test func passportDetailCases() throws {
    let f = try fixture("passport_detail")
    let rules = try #require((f["meta"] as? [String: Any])?["rules"] as? [String: Any])
    #expect(int64(rules["earth_km"]) == 40_075)
    #expect(int64(rules["moon_km"]) == 384_400)
    #expect(int64(rules["sun_km"]) == 4_375_250)
    #expect(int64(rules["connection_seconds_lt"]) == 28_800)
    let all = try cases(f)
    let names = all.compactMap { string($0["name"]) }
    for required in ["empty", "single_flight", "sparse"] {
        #expect(names.contains(required), "missing case \(required)")
    }
    for c in all {
        let n = string(c["name"]) ?? "?"
        let flights = try #require(c["flights"] as? [[String: Any]]).map(pastFlight)
        let countries = try #require(c["countries"] as? [[String: Any]]).map(countryInfo)
        var got = detailJSON(computePassportDetail(flights: flights, year: int32(c["year"]), countries: countries))
        var expected = try #require(c["expected"] as? [String: Any])
        // Foundation's JSON reader can land a long double one ulp away (Rust and Deno compare exactly),
        // so the three ratios are compared within a relative 1e-12, the rest exactly.
        for key in ["earthRatio", "moonRatio", "sunRatio"] {
            let g = try #require(double(got[key]))
            let e = try #require(double(expected[key]))
            #expect(abs(g - e) <= 1e-12 * max(1, abs(e)), "\(n): \(key) \(g) vs \(e)")
            got[key] = 0
            expected[key] = 0
        }
        #expect(jsonEqual(got, expected), "\(n): \(json(got)) vs \(json(expected))")
    }
}

// MARK: - Aircraft

private func orNull(_ v: Any?) -> Any { v ?? NSNull() }

private func typeInfo(_ v: [String: Any]) throws -> TypeInfo {
    TypeInfo(icaoType: try #require(string(v["icao_type"])), family: try #require(string(v["family"])),
             manufacturer: try #require(string(v["manufacturer"])))
}

private func aircraftFact(_ v: [String: Any]) throws -> AircraftFact {
    AircraftFact(registration: try #require(string(v["registration"])), deliveredAt: int64(v["delivered_at"]),
                 name: string(v["name"]))
}

private func positionName(_ p: SeatPosition?) -> Any {
    switch p {
    case .window: "window"
    case .middle: "middle"
    case .aisle: "aisle"
    case .pilot: "pilot"
    case .captain: "captain"
    case .jumpseat: "jumpseat"
    case nil: NSNull()
    }
}

private func typeTallyJSON(_ t: TypeTally) -> [String: Any] {
    ["icaoType": t.icaoType, "flights": t.flights, "minutes": t.minutes, "distanceKm": t.distanceKm]
}

private func agedJSON(_ a: AgedAircraft?) -> Any {
    guard let a else { return NSNull() }
    return [
        "registration": a.registration, "icaoType": orNull(a.icaoType),
        "deliveredAt": a.deliveredAt, "ageMonths": a.ageMonths,
    ] as [String: Any]
}

/// Same shape as the core crate's serde output (camelCase keys).
private func aircraftJSON(_ s: AircraftStats) -> [String: Any] {
    [
        "totalTypes": s.totalTypes,
        "manufacturers": s.manufacturers.map {
            ["key": $0.key, "flights": $0.flights, "percent": $0.percent] as [String: Any]
        },
        "typesByFlights": s.typesByFlights.map(typeTallyJSON),
        "typesByMinutes": s.typesByMinutes.map(typeTallyJSON),
        "typesByDistance": s.typesByDistance.map(typeTallyJSON),
        "mostFlown": s.mostFlown.map(typeTallyJSON) ?? NSNull(),
        "tails": s.tails.map {
            [
                "registration": $0.registration, "flights": $0.flights, "icaoType": orNull($0.icaoType),
                "airline": orNull($0.airline), "name": orNull($0.name),
            ] as [String: Any]
        },
        "seatClasses": [
            "economy": s.seatClasses.economy, "premiumEconomy": s.seatClasses.premiumEconomy,
            "business": s.seatClasses.business, "first": s.seatClasses.first,
            "private": s.seatClasses.private,
        ],
        "seatPositions": [
            "window": s.seatPositions.window, "middle": s.seatPositions.middle, "aisle": s.seatPositions.aisle,
            "pilot": s.seatPositions.pilot, "captain": s.seatPositions.captain, "jumpseat": s.seatPositions.jumpseat,
        ],
        "favouriteSeat": s.favouriteSeat.map { ["seat": $0.seat, "flights": $0.flights] as [String: Any] }
            ?? NSNull(),
        "reasons": ["personal": s.reasons.personal, "business": s.reasons.business, "crew": s.reasons.crew],
        "decades": s.decades.map { ["decade": $0.decade, "aircraft": $0.aircraft] as [String: Any] },
        "medianAgeMonths": orNull(s.medianAgeMonths),
        "newest": agedJSON(s.newest),
        "oldest": agedJSON(s.oldest),
    ]
}

@Test func aircraftSeatPositions() throws {
    let all = try cases(try fixture("aircraft"), "seat_position")
    #expect(all.count > 100)
    for c in all {
        let seat = try #require(string(c["seat"]))
        let family = try #require(string(c["family"]))
        let got = positionName(seatPosition(seat: seat, family: family))
        #expect(jsonEqual(got, c["expected"] ?? NSNull()), "\(seat) \(family): \(got)")
    }
}

@Test func aircraftCases() throws {
    let all = try cases(try fixture("aircraft"))
    let names = all.compactMap { string($0["name"]) }
    for required in [
        "empty", "single_flight", "sparse", "single_aircraft", "seat_positions_every_layout",
        "unknown_family_seat", "decades_with_gap", "manufacturer_percent_rounding", "no_facts", "year_filter",
        "picked_positions_private_crew",
    ] {
        #expect(names.contains(required), "missing case \(required)")
    }
    for c in all {
        let n = string(c["name"]) ?? "?"
        let flights = try #require(c["flights"] as? [[String: Any]]).map(pastFlight)
        let types = try #require(c["types"] as? [[String: Any]]).map(typeInfo)
        let facts = try #require(c["facts"] as? [[String: Any]]).map(aircraftFact)
        let got = aircraftJSON(computeAircraftStats(
            flights: flights, year: int32(c["year"]), types: types, facts: facts,
            asOf: try #require(int64(c["as_of"]))))
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
