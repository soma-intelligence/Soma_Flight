#!/usr/bin/env python3
"""Builds Sources/FlightKit/Resources/Reference/airports.tsv from the backend's airport seed.

The app looks airports up on the device (city names, local times, globe pins, search suggestions), so it
ships the same list the database seeds: supabase/migrations/20261028000002_airports_seed.sql. One line per
airport, tab separated, in ICAO order:

    ICAO  IATA  name  city  country  lat  lon  tz

An empty field is a missing value (no IATA code, no time zone); an airport with no city takes its name.
The city loses its parenthesised tail ("Paris (Roissy-en-France, Val-d'Oise)" reads "Paris"), so screens
and searches meet the city people name; coordinates keep 4 decimals (about 11 m). Rerun after the seed changes:

    python3 Packages/FlightKit/Scripts/build_airport_directory.py
"""
import pathlib
import re

ROOT = pathlib.Path(__file__).resolve().parents[3]
SRC = ROOT / "supabase/migrations/20261028000002_airports_seed.sql"
OUT = ROOT / "Packages/FlightKit/Sources/FlightKit/Resources/Reference/airports.tsv"

# One SQL value: a quoted string ('' is a quote), null, or a number.
VALUE = re.compile(r"\s*(?:'((?:[^']|'')*)'|(null)|(-?[0-9.]+(?:[eE]-?[0-9]+)?))\s*(,|\))")


def parse_row(line: str):
    """The eight values of one `(...)` row, or None for a line that is not a row."""
    line = line.strip()
    if not line.startswith("("):
        return None
    pos, values = 1, []
    while True:
        m = VALUE.match(line, pos)
        if not m:
            raise ValueError(f"cannot read row: {line[:80]}")
        text, null, number, end = m.groups()
        values.append(None if null else text.replace("''", "'") if text is not None else float(number))
        pos = m.end()
        if end == ")":
            break
    if len(values) != 8:
        raise ValueError(f"expected 8 values, got {len(values)}: {line[:80]}")
    return values


def clean(s) -> str:
    """No tabs or line breaks (the file's separators), no em dash (the repo never writes one)."""
    if s is None:
        return ""
    return re.sub(r"[\t\r\n]+", " ", s).replace(chr(0x2014), "-").strip()


def city(s) -> str:
    return re.sub(r"\s*\(.*\)\s*$", "", clean(s))


def coord(x: float) -> str:
    return f"{x:.4f}".rstrip("0").rstrip(".")


rows = []
for line in SRC.read_text(encoding="utf-8").splitlines():
    v = parse_row(line)
    if v is None:
        continue
    icao, iata, name, town, country, lat, lon, tz = v
    rows.append("\t".join([clean(icao).upper(), clean(iata).upper(), clean(name), city(town) or clean(name),
                           clean(country).upper(), coord(lat), coord(lon), clean(tz)]))

rows.sort()
OUT.write_text("\n".join(rows) + "\n", encoding="utf-8")
print(f"{len(rows)} airports -> {OUT.relative_to(ROOT)} ({OUT.stat().st_size} bytes)")
