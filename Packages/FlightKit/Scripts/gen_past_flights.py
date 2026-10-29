#!/usr/bin/env python3
"""Densifies the Passport seed (Resources/Fakes/past_flights.json) so the Passport screen has a
few years of history to group and total, like a real traveller's log.

The first eight flights are the original hand-written seed and stay as they are (tests pin them
by year). The rest is a fixed list of routes and dates, so the output is deterministic.
Distance is the great circle between the seed airports; block time is distance at 780 km/h
plus 35 minutes of taxi.

Usage: python3 Packages/FlightKit/Scripts/gen_past_flights.py Packages/FlightKit/Sources/FlightKit/Resources/Fakes
"""
import json
import math
import sys
import uuid
from pathlib import Path

ORIGINAL = 8

# date (local, noon UTC is fine for the year), ident, from, to, airline, aircraft, delay, status
EXTRA = [
    ("2026-10-02", "UA1882", "KSFO", "KDEN", "United", "B39M", 47, "completed"),
    ("2026-09-21", "AF84", "LFPG", "KSFO", "Air France", "A359", 0, "completed"),
    ("2026-08-30", "AS340", "KSFO", "KSEA", "Alaska", "B739", 9, "completed"),
    ("2026-08-02", "AS337", "KSEA", "KSFO", "Alaska", "B39M", 64, "completed"),
    ("2026-06-14", "B6915", "KJFK", "KSFO", "JetBlue", "A321", 31, "completed"),
    ("2026-06-09", "B6416", "KSFO", "KJFK", "JetBlue", "A321", 0, "completed"),
    ("2026-04-25", "UA990", "LFPG", "KSFO", "United", "B77W", 22, "completed"),
    ("2026-04-11", "UA991", "KSFO", "LFPG", "United", "B77W", 0, "completed"),
    ("2026-02-28", "WN2210", "KSFO", "KLAS", "Southwest", "B38M", 18, "completed"),
    ("2026-01-17", "DL1567", "KSFO", "KATL", "Delta", "A321", 0, "completed"),
    ("2025-11-27", "AA2178", "KAUS", "KDFW", "American", "B738", 0, "completed"),
    ("2025-11-23", "AA1031", "KSFO", "KAUS", "American", "B738", 52, "completed"),
    ("2025-10-04", "BA287", "KSFO", "EGLL", "British Airways", "B789", 14, "completed"),
    ("2025-09-26", "BA286", "EGLL", "KSFO", "British Airways", "B789", 0, "completed"),
    ("2025-09-03", "AF85", "LFPG", "KSFO", "Air France", "A359", 26, "completed"),
    ("2025-08-26", "AF83", "KSFO", "LFPG", "Air France", "A359", 0, "completed"),
    ("2025-06-08", "UA1527", "KAUS", "KSFO", "United", "B739", 0, "completed"),
    ("2025-05-30", "UA2280", "KSFO", "KAUS", "United", "A320", 95, "completed"),
    ("2025-03-02", "UA838", "RJTT", "KSFO", "United", "B789", 11, "completed"),
    ("2025-01-14", "WN1180", "KOAK", "KLAX", "Southwest", "B737", 0, "completed"),
    ("2024-12-20", "DL2394", "KATL", "KMIA", "Delta", "A321", 33, "completed"),
    ("2024-12-15", "DL434", "KSFO", "KATL", "Delta", "A321", 0, "completed"),
    ("2024-09-12", "AC738", "CYYZ", "KSFO", "Air Canada", "A321", 0, "completed"),
    ("2024-09-07", "AC739", "KSFO", "CYYZ", "Air Canada", "A321", 40, "completed"),
    ("2024-07-19", "AM651", "MMMX", "KSFO", "Aeromexico", "B38M", 0, "completed"),
    ("2024-07-12", "AM650", "KSFO", "MMMX", "Aeromexico", "B38M", 7, "completed"),
    ("2024-05-03", "B6417", "KJFK", "KBOS", "JetBlue", "A220", 0, "completed"),
    ("2024-04-28", "B6115", "KSFO", "KJFK", "JetBlue", "A321", 58, "completed"),
    ("2024-02-10", "UA1189", "KSFO", "KORD", "United", "B39M", 0, "canceled"),
    ("2023-11-18", "AF83", "KSFO", "LFPG", "Air France", "A359", 0, "completed"),
    ("2023-11-30", "AF84", "LFPG", "KSFO", "Air France", "A359", 19, "completed"),
    ("2023-08-05", "AS1032", "KSFO", "KPDX", "Alaska", "E175", 0, "completed"),
    ("2023-08-09", "AS1035", "KPDX", "KSFO", "Alaska", "E175", 12, "completed"),
    ("2023-04-22", "UA1527", "KAUS", "KSFO", "United", "B739", 0, "completed"),
]

REGISTRATION = {"A359": "F-HTYM", "B39M": "N47280", "B739": "N37522", "A321": "N370DN", "B77W": "N2135U",
                "B38M": "N8710M", "B738": "N905NN", "B789": "G-ZBKD", "A320": "N4901U", "B737": "N7718B",
                "A220": "N3044J", "E175": "N625QX"}


def great_circle_km(a, b) -> int:
    lat1, lon1, lat2, lon2 = map(math.radians, (a["lat"], a["lon"], b["lat"], b["lon"]))
    h = math.sin((lat2 - lat1) / 2) ** 2 + math.cos(lat1) * math.cos(lat2) * math.sin((lon2 - lon1) / 2) ** 2
    return round(2 * 6371 * math.asin(math.sqrt(h)))


def main() -> None:
    fakes = Path(sys.argv[1])
    airports = {a["id"]: a for a in json.loads((fakes / "airports.json").read_text())}
    path = fakes / "past_flights.json"
    # The hand-written originals are the ones without origin_tz.
    original = [f for f in json.loads(path.read_text()) if "origin_tz" not in f]
    assert len(original) == ORIGINAL, len(original)
    out = list(original)
    for i, (day, ident, o, d, airline, ac, delay, status) in enumerate(EXTRA):
        km = great_circle_km(airports[o], airports[d])
        out.append({
            "id": str(uuid.uuid5(uuid.NAMESPACE_URL, f"soma-flight-fake/past/{i}/{ident}/{day}")),
            "date": f"{day}T18:00:00.000Z",
            "ident": ident,
            "origin_icao": o,
            "destination_icao": d,
            "airline": airline,
            "aircraft_type": ac,
            "registration": REGISTRATION[ac],
            "seat": f"{12 + i % 30}{'ACDF'[i % 4]}",
            "distance_km": km,
            "block_minutes": round(km / 780 * 60) + 35,
            "delay_minutes": delay,
            "status": status,
            "origin_tz": airports[o]["tz"],
        })
    out.sort(key=lambda f: f["date"], reverse=True)
    path.write_text(json.dumps(out, indent=1, ensure_ascii=False) + "\n")
    print(f"{len(out)} past flights")


if __name__ == "__main__":
    main()
