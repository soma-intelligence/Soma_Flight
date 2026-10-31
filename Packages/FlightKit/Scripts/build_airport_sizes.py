#!/usr/bin/env python3
"""Builds Sources/FlightKit/Resources/Reference/airport_sizes.json from supabase/seed/airports.csv.

The gate walk (GateWalk.swift) falls back on an airport's size when its table does not list the airport.
OurAirports types each airport large, medium or small; the file keeps the large and small ICAO codes and
every other airport counts as medium.

    python3 Packages/FlightKit/Scripts/build_airport_sizes.py
"""
import csv
import json
import pathlib

ROOT = pathlib.Path(__file__).resolve().parents[3]
SRC = ROOT / "supabase/seed/airports.csv"
OUT = ROOT / "Packages/FlightKit/Sources/FlightKit/Resources/Reference/airport_sizes.json"

large, small = [], []
with SRC.open(newline="") as f:
    for row in csv.DictReader(f):
        icao = (row.get("icao_code") or row.get("ident") or "").strip().upper()
        if len(icao) != 4:
            continue
        if row["type"] == "large_airport":
            large.append(icao)
        elif row["type"] in ("small_airport", "heliport", "seaplane_base"):
            small.append(icao)

OUT.write_text(json.dumps({"large": sorted(set(large)), "small": sorted(set(small))}, separators=(",", ":")) + "\n")
print(f"{len(set(large))} large, {len(set(small))} small -> {OUT.relative_to(ROOT)}")
