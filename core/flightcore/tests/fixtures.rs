use flightcore::geo::{Coord, distance_km, great_circle};
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
