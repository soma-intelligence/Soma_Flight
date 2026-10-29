#!/usr/bin/env python3
"""Natural Earth 1:110m land (public domain) to the Passport map's land outline.

Reads ne_110m_land.geojson (https://www.naturalearthdata.com, mirror
https://github.com/nvkelso/natural-earth-vector/blob/master/geojson/ne_110m_land.geojson), simplifies every
ring with Douglas-Peucker at 0.15 degrees, rounds to 2 decimals and writes
{"source": ..., "rings": [[lon, lat, lon, lat, ...], ...]} (flat pairs, outer rings and holes alike; the app
fills them even-odd). Rings left with fewer than 4 points are dropped.

Usage: python3 -I Scripts/world/build_land.py ne_110m_land.geojson \
    Packages/FlightKit/Sources/FlightKit/Resources/Reference/world_land.json
Only reads JSON: no code from the input is run.
"""
import json
import sys

TOLERANCE = 0.15
DIGITS = 2


def perpendicular(p, a, b):
    (x, y), (x1, y1), (x2, y2) = p, a, b
    dx, dy = x2 - x1, y2 - y1
    if dx == 0 and dy == 0:
        return ((x - x1) ** 2 + (y - y1) ** 2) ** 0.5
    return abs(dy * x - dx * y + x2 * y1 - y2 * x1) / (dx * dx + dy * dy) ** 0.5


def simplify(points, tol):
    """Iterative Douglas-Peucker keeping both ends."""
    if len(points) < 3:
        return points
    keep = [False] * len(points)
    keep[0] = keep[-1] = True
    stack = [(0, len(points) - 1)]
    while stack:
        i, j = stack.pop()
        best, index = 0.0, None
        for k in range(i + 1, j):
            d = perpendicular(points[k], points[i], points[j])
            if d > best:
                best, index = d, k
        if index is not None and best > tol:
            keep[index] = True
            stack += [(i, index), (index, j)]
    return [p for p, k in zip(points, keep) if k]


def rings(geometry):
    if geometry["type"] == "Polygon":
        yield from geometry["coordinates"]
    elif geometry["type"] == "MultiPolygon":
        for polygon in geometry["coordinates"]:
            yield from polygon


def main(src, dst):
    with open(src, encoding="utf-8") as f:
        data = json.load(f)
    out = []
    for feature in data["features"]:
        for ring in rings(feature["geometry"]):
            pts = simplify([(float(x), float(y)) for x, y, *_ in ring], TOLERANCE)
            flat = []
            last = None
            for x, y in pts:
                q = (round(x, DIGITS), round(y, DIGITS))
                if q != last:
                    flat += [q[0], q[1]]
                    last = q
            if len(flat) >= 8:
                out.append(flat)
    doc = {"source": "Natural Earth 1:110m land, public domain, simplified 0.15 deg", "rings": out}
    with open(dst, "w", encoding="utf-8") as f:
        json.dump(doc, f, separators=(",", ":"))
    print(f"{len(out)} rings, {sum(len(r) // 2 for r in out)} points")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit("usage: build_land.py <ne_110m_land.geojson> <world_land.json>")
    main(sys.argv[1], sys.argv[2])
