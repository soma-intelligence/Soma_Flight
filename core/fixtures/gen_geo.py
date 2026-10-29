#!/usr/bin/env python3
"""Regenerates geo.json. Independent of the Rust code: distances use the
haversine formula, path samples use the Aviation Formulary intermediate-point
formula (a different construction from the vector slerp in flightcore).
Usage: python3 core/fixtures/gen_geo.py > core/fixtures/geo.json
"""
import json, math

R = 6371.0088
CDG = (49.0097, 2.5479)
SFO = (37.6213, -122.3790)
HND = (35.5494, 139.7798)
JFK = (40.6413, -73.7781)
LHR = (51.4700, -0.4543)

def c(p): return {"lat": p[0], "lon": p[1]}

def central_angle(a, b):
    p1, p2 = math.radians(a[0]), math.radians(b[0])
    dl = math.radians(b[1] - a[1])
    h = math.sin((p2 - p1) / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * math.asin(math.sqrt(h))

def dist(a, b): return R * central_angle(a, b)

def intermediate(a, b, f):
    d = central_angle(a, b)
    p1, l1, p2, l2 = map(math.radians, (a[0], a[1], b[0], b[1]))
    A = math.sin((1 - f) * d) / math.sin(d)
    B = math.sin(f * d) / math.sin(d)
    x = A * math.cos(p1) * math.cos(l1) + B * math.cos(p2) * math.cos(l2)
    y = A * math.cos(p1) * math.sin(l1) + B * math.cos(p2) * math.sin(l2)
    z = A * math.sin(p1) + B * math.sin(p2)
    return math.degrees(math.atan2(z, math.hypot(x, y))), math.degrees(math.atan2(y, x))

def unwrap(lon, ref):
    return lon + 360 * round((ref - lon) / 360)

def samples(a, b, segments, idxs, tol):
    out, prev = [], a[1]
    # unwrap along the whole path so the reference is the previous point
    pts = []
    for i in range(segments + 1):
        lat, lon = intermediate(a, b, i / segments) if 0 < i < segments else ((a if i == 0 else b))
        lon = unwrap(lon, prev); prev = lon
        pts.append((lat, lon))
    for i in idxs:
        out.append({"index": i, "lat": round(pts[i][0], 4), "lon": round(pts[i][1], 4), "tolerance": tol})
    return out, pts[-1][1]

def dcase(name, a, b, tol):
    return {"name": name, "a": c(a), "b": c(b), "expected": round(dist(a, b), 4), "tolerance": tol}

cdg_s, _ = samples(CDG, SFO, 64, [16, 32, 48], 0.01)
hnd_s, hnd_last = samples(HND, SFO, 64, [16, 32, 48], 0.01)

doc = {
    "meta": {
        "radius_km": R,
        "generator": "core/fixtures/gen_geo.py",
        "invariants": {
            "great_circle_len": "segments + 1 points, with segments 0 clamped to 1",
            "first_point": "equals a exactly",
            "last_point": "equals b modulo 360 in longitude (latitude exact); longitudes are unwrapped, so the last longitude may be outside -180..180",
            "neighbour_lon_delta_lt": 180.0,
            "segments_zero_clamps_to": 1,
        },
    },
    "distance_km": [
        dcase("cdg_sfo", CDG, SFO, 0.01),
        dcase("jfk_lhr", JFK, LHR, 0.01),
        dcase("hnd_sfo", HND, SFO, 0.01),
        dcase("quarter_equator", (0, 0), (0, 90), 0.001),
        dcase("pole_to_pole", (90, 0), (-90, 0), 0.001),
        dcase("same_point", CDG, CDG, 1e-9),
    ],
    "great_circle": [
        {"name": "cdg_sfo", "a": c(CDG), "b": c(SFO), "segments": 64, "expected_len": 65, "samples": cdg_s},
        {"name": "hnd_sfo_antimeridian", "a": c(HND), "b": c(SFO), "segments": 64, "expected_len": 65,
         "expected_last_lon": round(hnd_last, 4), "samples": hnd_s},
        {"name": "jfk_lhr_single_segment", "a": c(JFK), "b": c(LHR), "segments": 1, "expected_len": 2},
        {"name": "identical_points", "a": c(CDG), "b": c(CDG), "segments": 4, "expected_len": 5, "all_equal_a": True},
        {"name": "segments_zero", "a": c(CDG), "b": c(SFO), "segments": 0, "expected_len": 2},
    ],
}
print(json.dumps(doc, indent=2))
