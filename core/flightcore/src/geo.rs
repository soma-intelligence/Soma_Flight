use serde::{Deserialize, Serialize};

#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
pub struct Coord {
    pub lat: f64,
    pub lon: f64,
}

const EARTH_RADIUS_KM: f64 = 6371.0088;

/// Haversine distance on a sphere of radius 6371.0088 km.
pub fn distance_km(a: Coord, b: Coord) -> f64 {
    let (p1, p2) = (a.lat.to_radians(), b.lat.to_radians());
    let dp = p2 - p1;
    let dl = (b.lon - a.lon).to_radians();
    let h = (dp / 2.0).sin().powi(2) + p1.cos() * p2.cos() * (dl / 2.0).sin().powi(2);
    2.0 * EARTH_RADIUS_KM * h.sqrt().min(1.0).asin()
}

fn to_vec(c: Coord) -> [f64; 3] {
    let (lat, lon) = (c.lat.to_radians(), c.lon.to_radians());
    [lat.cos() * lon.cos(), lat.cos() * lon.sin(), lat.sin()]
}

fn from_vec(v: [f64; 3]) -> Coord {
    let n = (v[0] * v[0] + v[1] * v[1] + v[2] * v[2]).sqrt();
    Coord {
        lat: (v[2] / n).clamp(-1.0, 1.0).asin().to_degrees(),
        lon: v[1].atan2(v[0]).to_degrees(),
    }
}

/// Great-circle path from `a` to `b` as `segments + 1` points (slerp).
/// The first point is `a`. Longitudes are unwrapped so neighbours differ by
/// less than 180 degrees, so the last point's longitude may be `b.lon` shifted
/// by a multiple of 360 when the path crosses the antimeridian. For coincident
/// or antipodal endpoints (path undefined) it interpolates linearly in lat/lon.
pub fn great_circle(a: Coord, b: Coord, segments: u32) -> Vec<Coord> {
    let segments = segments.max(1);
    let (va, vb) = (to_vec(a), to_vec(b));
    let dot = va[0] * vb[0] + va[1] * vb[1] + va[2] * vb[2];
    let cross = [
        va[1] * vb[2] - va[2] * vb[1],
        va[2] * vb[0] - va[0] * vb[2],
        va[0] * vb[1] - va[1] * vb[0],
    ];
    let cross_norm = (cross[0] * cross[0] + cross[1] * cross[1] + cross[2] * cross[2]).sqrt();
    // atan2 stays accurate for near-identical and near-antipodal points, unlike acos
    let omega = cross_norm.atan2(dot);
    let so = omega.sin();
    let mut out = Vec::with_capacity(segments as usize + 1);
    out.push(a);
    for i in 1..=segments {
        let t = f64::from(i) / f64::from(segments);
        let mut c = if so.abs() < 1e-12 {
            // coincident (or antipodal, where the path is undefined): stay on a
            Coord {
                lat: a.lat + (b.lat - a.lat) * t,
                lon: a.lon + (b.lon - a.lon) * t,
            }
        } else {
            let (wa, wb) = (((1.0 - t) * omega).sin() / so, (t * omega).sin() / so);
            from_vec([
                wa * va[0] + wb * vb[0],
                wa * va[1] + wb * vb[1],
                wa * va[2] + wb * vb[2],
            ])
        };
        if i == segments {
            // pin the final point to b exactly (latitude); its longitude is
            // re-unwrapped below like every other point
            c = Coord {
                lat: b.lat,
                lon: b.lon,
            };
        }
        let prev = out[out.len() - 1].lon;
        // shift by multiples of 360 to land within 180 of the previous point
        c.lon += 360.0 * ((prev - c.lon) / 360.0).round();
        out.push(c);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    const CDG: Coord = Coord {
        lat: 49.0097,
        lon: 2.5479,
    };
    const SFO: Coord = Coord {
        lat: 37.6213,
        lon: -122.3790,
    };
    const HND: Coord = Coord {
        lat: 35.5494,
        lon: 139.7798,
    };

    #[test]
    fn distance_cdg_sfo() {
        let d = distance_km(CDG, SFO);
        assert!(d > 8900.0 && d < 9000.0, "{d}");
    }

    #[test]
    fn distance_same_point_zero() {
        assert_eq!(distance_km(CDG, CDG), 0.0);
    }

    #[test]
    fn great_circle_endpoints() {
        let p = great_circle(CDG, SFO, 64);
        assert_eq!(p.len(), 65);
        assert_eq!(p[0], CDG);
        assert_eq!(p[64], SFO);
        let mid = p[32];
        assert!(distance_km(CDG, mid) > 4000.0 && distance_km(mid, SFO) > 4000.0);
    }

    #[test]
    fn great_circle_antimeridian() {
        let p = great_circle(HND, SFO, 64);
        assert_eq!(p.len(), 65);
        for w in p.windows(2) {
            assert!((w[1].lon - w[0].lon).abs() < 180.0, "{:?}", w);
        }
    }
}
