#!/usr/bin/env python3
"""Regenerates passport.json. Independent of the Rust code (uses zoneinfo for the year filter).
Usage: python3 core/fixtures/gen_passport.py   (writes passport.json next to this script)
"""
import json, os
from datetime import datetime, timezone
from zoneinfo import ZoneInfo

LONG_HAUL_KM = 4000

def ts(s):
    """UTC 'YYYY-MM-DDTHH:MM' to epoch seconds."""
    return int(datetime.strptime(s, "%Y-%m-%dT%H:%M").replace(tzinfo=timezone.utc).timestamp())

def fl(utc, orig, dest, km, tz="UTC", ident="XX1", airline="AA", ac="B738",
       block=None, delay=0, status="completed"):
    return {"departed_at": ts(utc), "tz": tz, "ident": ident, "origin_icao": orig,
            "destination_icao": dest, "airline": airline, "aircraft_type": ac,
            "distance_km": km, "block_minutes": block, "delay_minutes": delay, "status": status}

def local_year(f):
    try:
        z = ZoneInfo(f["tz"])
    except Exception:
        z = timezone.utc
    return datetime.fromtimestamp(f["departed_at"], tz=z).year

def stats(flights, year):
    ordered = sorted(flights, key=lambda f: f["departed_at"])  # stable
    kept = [f for f in ordered if f["status"] != "canceled" and (year is None or local_year(f) == year)]
    n = len(kept)
    delay = sum(f["delay_minutes"] for f in kept)
    airports = {f["origin_icao"] for f in kept} | {f["destination_icao"] for f in kept}
    airlines = {f["airline"] for f in kept if f["airline"]}
    counts = {}
    for f in kept:
        if f["aircraft_type"]:
            counts[f["aircraft_type"]] = counts.get(f["aircraft_type"], 0) + 1
    best = None
    for t in sorted(counts):
        if best is None or counts[t] > counts[best]:
            best = t
    routes, seen = [], set()
    for f in kept:
        r = (f["origin_icao"], f["destination_icao"])
        if r not in seen:
            seen.add(r); routes.append(list(r))
    return {
        "flights": n,
        "longHaul": sum(1 for f in kept if f["distance_km"] >= LONG_HAUL_KM),
        "distanceKm": sum(f["distance_km"] for f in kept),
        "flightMinutes": sum(f["block_minutes"] or 0 for f in kept),
        "airports": len(airports),
        "airlines": len(airlines),
        "delayLostMinutes": delay,
        "avgDelayMinutes": (2 * delay + n) // (2 * n) if n else 0,
        "mostFlownAircraft": None if best is None else {"aircraftType": best, "count": counts[best]},
        "routes": routes,
    }

cases = []
def case(name, flights, year=None):
    cases.append({"name": name, "year": year, "flights": flights, "expected": stats(flights, year)})

LA = "America/Los_Angeles"
base = [
    fl("2025-03-01T10:00", "LFPG", "KSFO", 8950, ident="AF83", airline="AF", ac="B77W", block=640, delay=20),
    fl("2025-06-10T08:00", "KSFO", "KJFK", 4150, ident="UA1", airline="UA", ac="B739", block=330, delay=10),
    fl("2025-07-04T12:00", "KJFK", "KBOS", 300, ident="B61", airline="B6", ac="B739", block=75, delay=0),
    fl("2025-08-01T12:00", "KBOS", "KJFK", 300, ident="B62", airline="B6", ac="A320", block=70, delay=40, status="canceled"),
]
case("basic_one_canceled", base)
case("year_filter_2025", base, 2025)
case("year_filter_empty_year", base, 2024)
case("pacific_new_year_eve_counts_in_2025",
     [fl("2026-01-01T07:30", "KSFO", "KLAX", 540, tz=LA, block=80)], 2025)
case("pacific_new_year_eve_not_in_2026",
     [fl("2026-01-01T07:30", "KSFO", "KLAX", 540, tz=LA, block=80)], 2026)
case("auckland_new_year_counts_in_2026_not_utc_2025",
     [fl("2025-12-31T12:00", "NZAA", "NZWN", 490, tz="Pacific/Auckland", block=65)], 2026)
case("unknown_tz_falls_back_to_utc_2026",
     [fl("2026-01-01T07:30", "KSFO", "KLAX", 540, tz="Mars/Olympus", block=80)], 2026)
case("unknown_tz_falls_back_to_utc_not_2025",
     [fl("2026-01-01T07:30", "KSFO", "KLAX", 540, tz="Mars/Olympus", block=80)], 2025)
case("empty", [])
case("empty_with_year", [], 2025)
case("only_canceled", [fl("2025-03-01T10:00", "LFPG", "KSFO", 8950, status="canceled", delay=90)])
case("diverted_counts_like_completed",
     [fl("2025-03-01T10:00", "LFPG", "KSFO", 8950, block=700, delay=5, status="diverted"),
      fl("2025-03-02T10:00", "KSFO", "LFPG", 8950, block=600, status="completed")])
case("long_haul_threshold",
     [fl("2025-01-01T10:00", "AAAA", "BBBB", 3999), fl("2025-01-02T10:00", "AAAA", "CCCC", 4000),
      fl("2025-01-03T10:00", "AAAA", "DDDD", 4001)])
case("route_direction_matters_first_seen_order",
     [fl("2025-05-03T10:00", "KSFO", "LFPG", 8950), fl("2025-05-01T10:00", "LFPG", "KSFO", 8950),
      fl("2025-05-02T10:00", "LFPG", "KSFO", 8950), fl("2025-05-04T10:00", "KSFO", "LFPG", 8950)])
case("routes_sorted_by_departure_not_input_order",
     [fl("2025-09-03T10:00", "CCCC", "DDDD", 100), fl("2025-09-01T10:00", "AAAA", "BBBB", 100),
      fl("2025-09-02T10:00", "BBBB", "CCCC", 100)])
case("most_flown_tie_alphabetical",
     [fl("2025-01-01T10:00", "AAAA", "BBBB", 100, ac="B738"), fl("2025-01-02T10:00", "AAAA", "BBBB", 100, ac="A320"),
      fl("2025-01-03T10:00", "AAAA", "BBBB", 100, ac="B738"), fl("2025-01-04T10:00", "AAAA", "BBBB", 100, ac="A320")])
case("most_flown_ignores_missing_types_and_canceled",
     [fl("2025-01-01T10:00", "AAAA", "BBBB", 100, ac=None), fl("2025-01-02T10:00", "AAAA", "BBBB", 100, ac="E190"),
      fl("2025-01-03T10:00", "AAAA", "BBBB", 100, ac="A320", status="canceled"),
      fl("2025-01-04T10:00", "AAAA", "BBBB", 100, ac="A320", status="canceled")])
case("no_aircraft_types", [fl("2025-01-01T10:00", "AAAA", "BBBB", 100, ac=None)])
case("airlines_unique_non_empty",
     [fl("2025-01-01T10:00", "AAAA", "BBBB", 100, airline="AF"), fl("2025-01-02T10:00", "AAAA", "BBBB", 100, airline="AF"),
      fl("2025-01-03T10:00", "AAAA", "BBBB", 100, airline=None), fl("2025-01-04T10:00", "AAAA", "BBBB", 100, airline=""),
      fl("2025-01-05T10:00", "AAAA", "BBBB", 100, airline="UA")])
case("missing_block_minutes_count_as_zero",
     [fl("2025-01-01T10:00", "AAAA", "BBBB", 100, block=None), fl("2025-01-02T10:00", "AAAA", "BBBB", 100, block=90)])
case("avg_delay_rounds_half_up_x_5_over_2",
     [fl("2025-01-01T10:00", "AAAA", "BBBB", 100, delay=2), fl("2025-01-02T10:00", "AAAA", "BBBB", 100, delay=3)])
case("avg_delay_rounds_down_below_half",
     [fl("2025-01-01T10:00", "AAAA", "BBBB", 100, delay=1), fl("2025-01-02T10:00", "AAAA", "BBBB", 100, delay=1),
      fl("2025-01-03T10:00", "AAAA", "BBBB", 100, delay=2)])
case("canceled_delay_excluded_from_totals",
     [fl("2025-01-01T10:00", "AAAA", "BBBB", 100, delay=10),
      fl("2025-01-02T10:00", "AAAA", "BBBB", 100, delay=500, status="canceled")])
case("airports_unique_across_origin_and_destination",
     [fl("2025-01-01T10:00", "AAAA", "BBBB", 100), fl("2025-01-02T10:00", "BBBB", "CCCC", 100),
      fl("2025-01-03T10:00", "CCCC", "AAAA", 100)])

meta = {
    "generator": "core/fixtures/gen_passport.py",
    "rules": {
        "long_haul_distance_km_gte": LONG_HAUL_KM,
        "excluded_status": "canceled",
        "counted_status": ["completed", "diverted"],
        "year_filter": "local departure year in the flight tz; unknown tz falls back to UTC; year null = all time",
        "flight_minutes": "sum of block_minutes, null counts as 0",
        "delay_lost_minutes": "sum of delay_minutes over counted flights",
        "avg_delay_minutes": "delay_lost_minutes / flights rounded half up to integer, 0 when no flights",
        "airports": "unique ICAO across origin and destination",
        "airlines": "unique non-empty airline values",
        "most_flown_aircraft": "highest count of aircraft_type, ties alphabetical ascending, null when no types",
        "routes": "unique (origin, destination) in first-seen order after sorting by departed_at ascending; direction matters",
    },
}
here = os.path.dirname(os.path.abspath(__file__))
with open(os.path.join(here, "passport.json"), "w") as f:
    json.dump({"meta": meta, "cases": cases}, f, indent=2); f.write("\n")
