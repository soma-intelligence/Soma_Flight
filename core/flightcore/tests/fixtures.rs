use flightcore::aircraft::{
    AircraftFact, SeatPosition, TypeInfo, compute_aircraft_stats, seat_position,
};
use flightcore::delay::{BoardFlight, DelayStats, compute_stats};
use flightcore::geo::{Coord, distance_km, great_circle};
use flightcore::impact::{
    Affects, Conditions, HazardKind, ImpactLevel, describe_weather, present_weather, weather_impact,
};
use flightcore::passport::{PastFlight, compute_passport};
use flightcore::passport_detail::{CountryInfo, compute_passport_detail};
use flightcore::weather::{FlightCategory, flight_category};
use serde::Deserialize;

#[derive(Deserialize)]
struct Meta {
    radius_km: f64,
    invariants: Invariants,
}

#[derive(Deserialize)]
struct Invariants {
    neighbour_lon_delta_lt: f64,
    segments_zero_clamps_to: u32,
}

#[derive(Deserialize)]
struct DistCase {
    name: String,
    a: Coord,
    b: Coord,
    expected: f64,
    tolerance: f64,
}

#[derive(Deserialize)]
struct Sample {
    index: usize,
    lat: f64,
    lon: f64,
    tolerance: f64,
}

#[derive(Deserialize)]
struct GcCase {
    name: String,
    a: Coord,
    b: Coord,
    segments: u32,
    expected_len: usize,
    expected_last_lon: Option<f64>,
    #[serde(default)]
    samples: Vec<Sample>,
    #[serde(default)]
    all_equal_a: bool,
}

#[derive(Deserialize)]
struct Geo {
    meta: Meta,
    distance_km: Vec<DistCase>,
    great_circle: Vec<GcCase>,
}

fn load() -> Geo {
    serde_json::from_str(include_str!("../../fixtures/geo.json")).unwrap()
}

#[test]
fn geo_fixture_meta() {
    let m = load().meta;
    assert_eq!(m.radius_km, 6371.0088);
    assert_eq!(m.invariants.segments_zero_clamps_to, 1);
}

#[test]
fn geo_fixture_distances() {
    for c in load().distance_km {
        let d = distance_km(c.a, c.b);
        assert!(
            (d - c.expected).abs() <= c.tolerance,
            "{}: {d} vs {}",
            c.name,
            c.expected
        );
    }
}

#[test]
fn geo_fixture_great_circles() {
    let g = load();
    let max_delta = g.meta.invariants.neighbour_lon_delta_lt;
    let clamp = g.meta.invariants.segments_zero_clamps_to;
    for c in g.great_circle {
        let n = &c.name;
        let p = great_circle(c.a, c.b, c.segments);
        assert_eq!(p.len(), c.expected_len, "{n}: len");
        assert_eq!(p.len() as u32, c.segments.max(clamp) + 1, "{n}: clamp");
        assert_eq!(p[0], c.a, "{n}: first");
        let last = *p.last().unwrap();
        assert_eq!(last.lat, c.b.lat, "{n}: last lat");
        let k = (last.lon - c.b.lon) / 360.0;
        assert!((k - k.round()).abs() < 1e-9, "{n}: end lon not b mod 360");
        for w in p.windows(2) {
            assert!(
                (w[1].lon - w[0].lon).abs() < max_delta,
                "{n}: neighbour jump {w:?}"
            );
        }
        if let Some(l) = c.expected_last_lon {
            assert!(
                (last.lon - l).abs() < 1e-3,
                "{n}: last lon {} vs {l}",
                last.lon
            );
        }
        for s in &c.samples {
            let q = p[s.index];
            assert!(
                (q.lat - s.lat).abs() <= s.tolerance,
                "{n}[{}] lat {}",
                s.index,
                q.lat
            );
            assert!(
                (q.lon - s.lon).abs() <= s.tolerance,
                "{n}[{}] lon {}",
                s.index,
                q.lon
            );
        }
        if c.all_equal_a {
            assert!(p.iter().all(|q| *q == c.a), "{n}: not all equal a");
        }
    }
}

#[derive(Deserialize)]
struct DelayMeta {
    rules: DelayRules,
}

#[derive(Deserialize)]
struct DelayRules {
    avg_delay_tolerance: f64,
}

#[derive(Deserialize)]
struct DelayCase {
    name: String,
    rows: Vec<BoardFlight>,
    expected: DelayStats,
}

#[derive(Deserialize)]
struct DelayFile {
    meta: DelayMeta,
    cases: Vec<DelayCase>,
}

#[test]
fn delay_fixture_cases() {
    let f: DelayFile =
        serde_json::from_str(include_str!("../../fixtures/delay_stats.json")).unwrap();
    assert!(!f.cases.is_empty());
    for c in f.cases {
        let got = compute_stats(&c.rows);
        assert!(!got.avg_delay_minutes.is_nan(), "{}: NaN", c.name);
        assert!(
            (got.avg_delay_minutes - c.expected.avg_delay_minutes).abs()
                <= f.meta.rules.avg_delay_tolerance,
            "{}: avg {} vs {}",
            c.name,
            got.avg_delay_minutes,
            c.expected.avg_delay_minutes
        );
        let mut got_n = got.clone();
        let mut exp_n = c.expected.clone();
        got_n.avg_delay_minutes = 0.0;
        exp_n.avg_delay_minutes = 0.0;
        assert_eq!(got_n, exp_n, "{}", c.name);
    }
}

#[test]
fn delay_fixture_serialized_shape() {
    let f: serde_json::Value =
        serde_json::from_str(include_str!("../../fixtures/delay_stats.json")).unwrap();
    let rows: Vec<BoardFlight> = serde_json::from_value(f["cases"][0]["rows"].clone()).unwrap();
    let got = serde_json::to_value(compute_stats(&rows)).unwrap();
    let exp = &f["cases"][0]["expected"];
    assert_eq!(got["severity"], exp["severity"]);
    assert_eq!(got["perHour"], exp["perHour"]);
    assert_eq!(got["worstRoutes"], exp["worstRoutes"]);
    assert!(got.get("avgDelayMinutes").is_some());
}

#[derive(Deserialize)]
struct CatCase {
    name: String,
    ceiling_ft: Option<i32>,
    visibility_sm: f64,
    expected: FlightCategory,
}

#[derive(Deserialize)]
struct CatFile {
    cases: Vec<CatCase>,
}

#[test]
fn category_fixture_cases() {
    let f: CatFile = serde_json::from_str(include_str!("../../fixtures/category.json")).unwrap();
    assert!(!f.cases.is_empty());
    for c in f.cases {
        assert_eq!(
            flight_category(c.ceiling_ft, c.visibility_sm),
            c.expected,
            "{}",
            c.name
        );
    }
}

#[derive(Deserialize)]
struct PassportCase {
    name: String,
    year: Option<i32>,
    flights: Vec<PastFlight>,
    expected: serde_json::Value,
}

#[derive(Deserialize)]
struct PassportFile {
    cases: Vec<PassportCase>,
}

#[test]
fn passport_fixture_cases() {
    let f: PassportFile =
        serde_json::from_str(include_str!("../../fixtures/passport.json")).unwrap();
    assert!(f.cases.len() >= 20);
    for c in f.cases {
        let got = serde_json::to_value(compute_passport(&c.flights, c.year)).unwrap();
        assert_eq!(got, c.expected, "{}", c.name);
    }
}

#[derive(Deserialize)]
struct DetailCase {
    name: String,
    year: Option<i32>,
    countries: Vec<CountryInfo>,
    flights: Vec<PastFlight>,
    expected: serde_json::Value,
}

#[derive(Deserialize)]
struct DetailFile {
    meta: serde_json::Value,
    cases: Vec<DetailCase>,
}

#[test]
fn passport_detail_fixture_cases() {
    let f: DetailFile =
        serde_json::from_str(include_str!("../../fixtures/passport_detail.json")).unwrap();
    let rules = &f.meta["rules"];
    assert_eq!(rules["earth_km"], 40_075);
    assert_eq!(rules["moon_km"], 384_400);
    assert_eq!(rules["sun_km"], 4_375_250);
    assert_eq!(rules["connection_seconds_lt"], 28_800);
    let names: Vec<&str> = f.cases.iter().map(|c| c.name.as_str()).collect();
    for required in ["empty", "single_flight", "sparse"] {
        assert!(names.contains(&required), "missing case {required}");
    }
    for c in &f.cases {
        let got = serde_json::to_value(compute_passport_detail(&c.flights, c.year, &c.countries))
            .unwrap();
        assert_eq!(got, c.expected, "{}", c.name);
    }
}

#[derive(Deserialize)]
struct SeatCase {
    seat: String,
    family: String,
    expected: Option<SeatPosition>,
}

#[derive(Deserialize)]
struct AircraftCase {
    name: String,
    year: Option<i32>,
    as_of: i64,
    types: Vec<TypeInfo>,
    facts: Vec<AircraftFact>,
    flights: Vec<PastFlight>,
    expected: serde_json::Value,
}

#[derive(Deserialize)]
struct AircraftFile {
    seat_position: Vec<SeatCase>,
    cases: Vec<AircraftCase>,
}

fn load_aircraft() -> AircraftFile {
    serde_json::from_str(include_str!("../../fixtures/aircraft.json")).unwrap()
}

#[test]
fn aircraft_fixture_seat_positions() {
    let f = load_aircraft();
    assert!(f.seat_position.len() > 100);
    for c in f.seat_position {
        assert_eq!(
            seat_position(&c.seat, &c.family),
            c.expected,
            "{:?} {:?}",
            c.seat,
            c.family
        );
    }
}

#[test]
fn aircraft_fixture_cases() {
    let f = load_aircraft();
    let names: Vec<&str> = f.cases.iter().map(|c| c.name.as_str()).collect();
    for required in [
        "empty",
        "single_flight",
        "sparse",
        "single_aircraft",
        "seat_positions_every_layout",
        "unknown_family_seat",
        "decades_with_gap",
        "manufacturer_percent_rounding",
        "no_facts",
        "year_filter",
        "picked_positions_private_crew",
    ] {
        assert!(names.contains(&required), "missing case {required}");
    }
    for c in &f.cases {
        let got = serde_json::to_value(compute_aircraft_stats(
            &c.flights, c.year, &c.types, &c.facts, c.as_of,
        ))
        .unwrap();
        assert_eq!(got, c.expected, "{}", c.name);
    }
}

// Weather impact

#[derive(Deserialize)]
struct ImpactCase {
    name: String,
    conditions: Conditions,
    level: ImpactLevel,
    slows: bool,
    affects: Option<Affects>,
    hazards: Vec<HazardKind>,
    reason: String,
}

#[derive(Deserialize)]
struct DescribeCase {
    wx: String,
    text: String,
}

#[derive(Deserialize)]
struct ReportCase {
    report: String,
    wx: String,
}

#[derive(Deserialize)]
struct ImpactFile {
    impact: Vec<ImpactCase>,
    describe: Vec<DescribeCase>,
    present_weather: Vec<ReportCase>,
}

fn impact_file() -> ImpactFile {
    serde_json::from_str(include_str!("../../fixtures/weather_impact.json")).unwrap()
}

#[test]
fn weather_impact_fixture_cases() {
    let f = impact_file();
    assert!(!f.impact.is_empty());
    for c in f.impact {
        let i = weather_impact(&c.conditions);
        assert_eq!(i.level, c.level, "{}", c.name);
        assert_eq!(i.slows, c.slows, "{}", c.name);
        assert_eq!(i.affects, c.affects, "{}", c.name);
        let kinds: Vec<HazardKind> = i.hazards.iter().map(|h| h.kind).collect();
        assert_eq!(kinds, c.hazards, "{}", c.name);
        assert_eq!(i.reason, c.reason, "{}", c.name);
    }
}

#[test]
fn describe_weather_fixture_cases() {
    for c in impact_file().describe {
        assert_eq!(describe_weather(&c.wx), c.text, "{}", c.wx);
    }
}

#[test]
fn present_weather_fixture_cases() {
    for c in impact_file().present_weather {
        assert_eq!(present_weather(&c.report), c.wx, "{}", c.report);
    }
}
