use flightcore::geo::{Coord, distance_km, great_circle};
use serde::Deserialize;

#[derive(Deserialize)]
struct DistCase {
    a: Coord,
    b: Coord,
    expected: f64,
    tolerance: f64,
}

#[derive(Deserialize)]
struct GcCase {
    a: Coord,
    b: Coord,
    segments: u32,
    expected_len: usize,
}

#[derive(Deserialize)]
struct Geo {
    distance_km: Vec<DistCase>,
    great_circle: Vec<GcCase>,
}

fn load() -> Geo {
    serde_json::from_str(include_str!("../../fixtures/geo.json")).unwrap()
}

#[test]
fn geo_fixture_distances() {
    for c in load().distance_km {
        let d = distance_km(c.a, c.b);
        assert!(
            (d - c.expected).abs() <= c.tolerance,
            "{d} vs {}",
            c.expected
        );
    }
}

#[test]
fn geo_fixture_great_circles() {
    for c in load().great_circle {
        let p = great_circle(c.a, c.b, c.segments);
        assert_eq!(p.len(), c.expected_len);
        assert_eq!(p[0], c.a);
        let last = *p.last().unwrap();
        assert_eq!(last.lat, c.b.lat);
        let k = (last.lon - c.b.lon) / 360.0;
        assert!((k - k.round()).abs() < 1e-9, "end lon not b mod 360");
    }
}
