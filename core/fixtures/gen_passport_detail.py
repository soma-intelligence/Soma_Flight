#!/usr/bin/env python3
"""Regenerates passport_detail.json. Independent of the Rust code (stdlib only, zoneinfo for local time).
Usage: python3 core/fixtures/gen_passport_detail.py   (writes passport_detail.json next to this script)
"""
import json, os
from datetime import datetime, timezone
from zoneinfo import ZoneInfo

LONG_HAUL_KM = 4000
EARTH_KM = 40_075
MOON_KM = 384_400
SUN_KM = 4_375_250
CONNECTION_S = 28_800
REGIONS = ["europe", "north_america", "central_america", "caribbean", "south_america",
           "africa", "middle_east", "asia", "oceania"]


def ts(s):
    """UTC 'YYYY-MM-DDTHH:MM' to epoch seconds."""
    return int(datetime.strptime(s, "%Y-%m-%dT%H:%M").replace(tzinfo=timezone.utc).timestamp())


def fl(utc, orig, dest, km, tz="UTC", ident="XX1", airline="AAL", ac="B738", block=None, air=None,
       oc=None, dc=None, status="completed", reg=None, seat_class=None, seat=None, reason=None):
    return {"departed_at": ts(utc), "tz": tz, "ident": ident, "origin_icao": orig,
            "destination_icao": dest, "airline": airline, "aircraft_type": ac, "distance_km": km,
            "block_minutes": block, "delay_minutes": 0, "status": status,
            "origin_country": oc, "destination_country": dc, "air_minutes": air,
            "registration": reg, "seat_class": seat_class, "seat": seat, "reason": reason}


def local(f):
    try:
        z = ZoneInfo(f["tz"])
    except Exception:
        z = timezone.utc
    return datetime.fromtimestamp(f["departed_at"], tz=z)


def half_up(total, n):
    return (2 * total + n) // (2 * n) if n else 0


def known(c):
    """Country codes compare trimmed and upper case; empty is unknown."""
    c = (c or "").strip().upper()
    return c or None


def ref(f):
    if f is None:
        return None
    return {"ident": f["ident"], "originIcao": f["origin_icao"], "destinationIcao": f["destination_icao"],
            "departedAt": f["departed_at"], "distanceKm": f["distance_km"],
            "blockMinutes": f["block_minutes"], "airline": f["airline"]}


def first_best(items, key, better):
    """First item (in departure order) whose key beats every earlier one: ties keep the earliest."""
    best = None
    for f in items:
        if best is None or better(key(f), key(best)):
            best = f
    return best


def tallies(kept, key_of):
    t = {}
    for f in kept:
        k = key_of(f)
        if k is None:
            continue
        e = t.setdefault(k, {"key": k, "flights": 0, "distanceKm": 0})
        e["flights"] += 1
        e["distanceKm"] += f["distance_km"]
    rows = list(t.values())
    by_flights = sorted(rows, key=lambda r: (-r["flights"], -r["distanceKm"], r["key"]))
    by_distance = sorted(rows, key=lambda r: (-r["distanceKm"], -r["flights"], r["key"]))
    return by_flights, by_distance


def detail(flights, year, countries):
    ordered = sorted(flights, key=lambda f: f["departed_at"])  # stable
    counted = [f for f in ordered if f["status"] != "canceled"]
    kept = [f for f in counted if year is None or local(f).year == year]
    n = len(kept)

    years = {}
    for f in counted:
        y = local(f).year
        years[y] = years.get(y, 0) + 1

    domestic = international = unknown = 0
    for f in kept:
        o, d = known(f["origin_country"]), known(f["destination_country"])
        if o is None or d is None:
            unknown += 1
        elif o == d:
            domestic += 1
        else:
            international += 1

    per_month = [0] * 12
    per_weekday = [0] * 7
    for f in kept:
        t = local(f)
        per_month[t.month - 1] += 1
        per_weekday[t.weekday()] += 1

    distance = sum(f["distance_km"] for f in kept)
    timed = [f for f in kept if f["block_minutes"] is not None]
    flight_minutes = sum(f["block_minutes"] for f in timed)

    visits = {}
    prev = None
    for f in kept:
        visits[f["destination_icao"]] = visits.get(f["destination_icao"], 0) + 1
        connection = False
        if prev is not None and prev["destination_icao"] == f["origin_icao"]:
            landed = prev["departed_at"] + 60 * (prev["block_minutes"] or 0)
            connection = f["departed_at"] - landed < CONNECTION_S
        if not connection:
            visits[f["origin_icao"]] = visits.get(f["origin_icao"], 0) + 1
        prev = f
    airports = [{"icao": k, "visits": v} for k, v in sorted(visits.items(), key=lambda kv: (-kv[1], kv[0]))]

    al_f, al_d = tallies(kept, lambda f: f["airline"] or None)
    rt_f, rt_d = tallies(kept, lambda f: f"{f['origin_icao']}-{f['destination_icao']}")

    per_country = {}
    for f in kept:
        for c in {known(f["origin_country"]), known(f["destination_country"])} - {None}:
            per_country[c] = per_country.get(c, 0) + 1
    country_rows = [{"iso2": k, "flights": v}
                    for k, v in sorted(per_country.items(), key=lambda kv: (-kv[1], kv[0]))]

    region_of = {}
    for c in countries:  # first listing of a code wins
        if known(c["iso2"]) and known(c["iso2"]) not in region_of:
            region_of[known(c["iso2"])] = c["region"]
    regions = []
    for r in REGIONS:
        total = list(region_of.values()).count(r)
        visited = sum(1 for c in per_country if region_of.get(c) == r)
        regions.append({"region": r, "visited": visited, "total": total})

    return {
        "flights": n,
        "domestic": domestic,
        "international": international,
        "longHaul": sum(1 for f in kept if f["distance_km"] >= LONG_HAUL_KM),
        "perYear": [{"year": y, "flights": years[y]} for y in sorted(years)],
        "perMonth": per_month,
        "perWeekday": per_weekday,
        "distanceKm": distance,
        "avgDistanceKm": half_up(distance, n),
        "earthRatio": distance / EARTH_KM,
        "moonRatio": distance / MOON_KM,
        "sunRatio": distance / SUN_KM,
        "shortestByDistance": ref(first_best(kept, lambda f: f["distance_km"], lambda a, b: a < b)),
        "longestByDistance": ref(first_best(kept, lambda f: f["distance_km"], lambda a, b: a > b)),
        "shortestByTime": ref(first_best(timed, lambda f: f["block_minutes"], lambda a, b: a < b)),
        "longestByTime": ref(first_best(timed, lambda f: f["block_minutes"], lambda a, b: a > b)),
        "flightMinutes": flight_minutes,
        "avgFlightMinutes": half_up(flight_minutes, len(timed)),
        "airMinutes": sum(f["air_minutes"] or 0 for f in kept),
        "taxiMinutes": sum(max(0, f["block_minutes"] - f["air_minutes"]) for f in kept
                           if f["block_minutes"] is not None and f["air_minutes"] is not None),
        "airports": airports,
        "airlinesByFlights": al_f,
        "airlinesByDistance": al_d,
        "routesByFlights": rt_f,
        "routesByDistance": rt_d,
        "countries": country_rows,
        "unknownCountryFlights": unknown,
        "regions": regions,
    }


COUNTRIES = [
    {"iso2": "FR", "region": "europe"}, {"iso2": "GB", "region": "europe"}, {"iso2": "DE", "region": "europe"},
    {"iso2": "US", "region": "north_america"}, {"iso2": "CA", "region": "north_america"},
    {"iso2": "CR", "region": "central_america"}, {"iso2": "JM", "region": "caribbean"},
    {"iso2": "BR", "region": "south_america"}, {"iso2": "ZA", "region": "africa"},
    {"iso2": "AE", "region": "middle_east"}, {"iso2": "JP", "region": "asia"},
    {"iso2": "AU", "region": "oceania"},
]

cases = []


def case(name, flights, year=None, countries=COUNTRIES):
    cases.append({"name": name, "year": year, "countries": countries, "flights": flights,
                  "expected": detail(flights, year, countries)})


LA = "America/Los_Angeles"
PARIS = "Europe/Paris"

case("empty", [])

case("single_flight",
     [fl("2025-03-01T10:00", "LFPG", "KSFO", 8950, tz=PARIS, ident="AF84", airline="AFR", block=665, air=640,
         oc="FR", dc="US", reg="F-GSQA", seat_class="business", seat="7A", reason="business")])

case("domestic_international_unknown",
     [fl("2025-01-05T10:00", "KSFO", "KJFK", 4150, tz=LA, ident="UA1", airline="UAL", block=330, oc="US", dc="US"),
      fl("2025-01-08T10:00", "KJFK", "EGLL", 5540, ident="BA112", airline="BAW", block=410, oc="US", dc="GB"),
      fl("2025-01-12T10:00", "EGLL", "LFPG", 350, ident="AF1081", airline="AFR", block=75, oc="GB", dc=None),
      fl("2025-01-15T10:00", "LFPG", "LFMN", 690, ident="AF7700", airline="AFR", block=85, oc=None, dc="FR"),
      fl("2025-01-18T10:00", "LFMN", "LFPG", 690, ident="AF7701", airline="AFR", block=85, oc="", dc="FR"),
      fl("2025-01-20T10:00", "LFPG", "LFLL", 390, ident="AF7642", airline="AFR", block=70, oc="FR", dc="FR"),
      fl("2025-01-22T10:00", "LFLL", "EDDF", 560, ident="LH1077", airline="DLH", block=80, oc="FR", dc="DE",
         status="canceled"),
      fl("2025-01-25T10:00", "LFPG", "XXXX", 900, ident="ZZ1", airline="ZZZ", block=100, oc="FR", dc="QQ")])

case("weekday_tz_boundary",
     # Sunday 2025-10-26 23:30 in Los Angeles (Monday 06:30 UTC) counts Sunday.
     [fl("2025-10-27T06:30", "KLAX", "KSFO", 540, tz=LA, block=80, oc="US", dc="US"),
      # Friday 2025-10-31 23:30 in Los Angeles (Saturday 1 November UTC) counts October and Friday.
      fl("2025-11-01T06:30", "KSFO", "KLAX", 540, tz=LA, block=80, oc="US", dc="US"),
      # Thursday 1 January 2026 00:30 in Paris (Wednesday 31 December UTC) counts January and Thursday.
      fl("2025-12-31T23:30", "LFPG", "LFMN", 690, tz=PARIS, block=85, oc="FR", dc="FR"),
      # Unknown zone falls back to UTC: Monday 2025-12-01 counts Monday and December.
      fl("2025-12-01T03:00", "AAAA", "BBBB", 100, tz="Mars/Olympus", block=30)])

case("connection_7h59_once",
     # Lands 12:00 UTC at KJFK, next departs 19:59 UTC: 7 h 59 min on the ground, KJFK counts once.
     [fl("2025-04-01T10:00", "KBOS", "KJFK", 300, block=120, oc="US", dc="US"),
      fl("2025-04-01T19:59", "KJFK", "EGLL", 5540, block=420, oc="US", dc="GB"),
      # No block time: the next gap runs from this departure (10:00 + 0), so LFPG counts once.
      fl("2025-04-05T10:00", "EGLL", "LFPG", 350, block=None, oc="GB", dc="FR"),
      fl("2025-04-05T17:59", "LFPG", "LFMN", 690, block=85, oc="FR", dc="FR")])

case("connection_8h00_twice",
     # Lands 12:00 UTC at KJFK, next departs 20:00 UTC: exactly 8 h, KJFK counts twice.
     [fl("2025-04-01T10:00", "KBOS", "KJFK", 300, block=120, oc="US", dc="US"),
      fl("2025-04-01T20:00", "KJFK", "EGLL", 5540, block=420, oc="US", dc="GB"),
      fl("2025-04-05T10:00", "EGLL", "LFPG", 350, block=None, oc="GB", dc="FR"),
      fl("2025-04-05T18:00", "LFPG", "LFMN", 690, block=85, oc="FR", dc="FR"),
      # Not the same airport as the last arrival: both ends count.
      fl("2025-04-05T20:00", "LFPG", "EGLL", 350, block=70, oc="FR", dc="GB")])

case("ratios",
     # 280,017 km in total: earth 6.987..., moon 0.728..., sun 0.064...
     [fl("2025-02-01T10:00", "AAAA", "BBBB", 100_000, block=600),
      fl("2025-02-02T10:00", "BBBB", "CCCC", 100_000, block=600),
      fl("2025-02-03T10:00", "CCCC", "AAAA", 80_017, block=500)])

case("taxi_and_air",
     [fl("2025-05-01T10:00", "AAAA", "BBBB", 1000, block=150, air=125),
      fl("2025-05-02T10:00", "BBBB", "CCCC", 1000, block=90, air=100),   # air above block: taxi 0
      fl("2025-05-03T10:00", "CCCC", "DDDD", 1000, block=None, air=60),  # air only: in air, no taxi
      fl("2025-05-04T10:00", "DDDD", "AAAA", 1000, block=75, air=None),  # block only: no taxi
      fl("2025-05-05T10:00", "AAAA", "EEEE", 1000, block=60, air=40, status="canceled")])

case("tally_ties",
     [fl("2025-06-01T10:00", "KSFO", "KLAX", 540, airline="UAL", block=80),
      fl("2025-06-02T10:00", "KLAX", "KSFO", 540, airline="DAL", block=80),
      fl("2025-06-03T10:00", "KSFO", "KLAX", 540, airline="AAL", block=80),
      fl("2025-06-04T10:00", "KLAX", "KSFO", 540, airline="UAL", block=90),
      fl("2025-06-05T10:00", "KSFO", "KSEA", 1090, airline="DAL", block=120),
      fl("2025-06-06T10:00", "KSEA", "KSFO", 1090, airline="AAL", block=120),
      fl("2025-06-07T10:00", "KSFO", "KLAX", 540, airline="BAW", block=80),
      fl("2025-06-08T10:00", "KLAX", "KSFO", 540, airline=None, block=80),
      fl("2025-06-09T10:00", "KSFO", "KSEA", 1090, airline="", block=120)])

case("year_filter_with_per_year_all_time",
     [fl("2022-07-01T10:00", "AAAA", "BBBB", 500, block=60, status="canceled"),
      fl("2023-07-01T10:00", "AAAA", "BBBB", 500, block=60),
      fl("2023-08-01T10:00", "BBBB", "AAAA", 500, block=60),
      fl("2024-03-01T10:00", "AAAA", "CCCC", 9000, block=660, oc="US", dc="JP"),
      fl("2024-03-20T10:00", "CCCC", "AAAA", 9000, block=600, oc="JP", dc="US"),
      fl("2024-09-01T10:00", "AAAA", "DDDD", 300, block=55, oc="US", dc="US"),
      # Pacific new year's eve: 2025-01-01 07:30 UTC is 2024 in Los Angeles.
      fl("2025-01-01T07:30", "KSFO", "KLAX", 540, tz=LA, block=80, oc="US", dc="US"),
      fl("2025-06-01T10:00", "KLAX", "KSFO", 540, tz=LA, block=80, oc="US", dc="US")], year=2024)

case("one_flight_in_year",
     [fl("2023-07-01T10:00", "AAAA", "BBBB", 500, block=60),
      fl("2024-05-01T10:00", "LFPG", "EGLL", 350, tz=PARIS, block=75, air=55, oc="FR", dc="GB"),
      fl("2025-07-01T10:00", "BBBB", "AAAA", 500, block=60)], year=2024)

case("year_with_no_flights",
     [fl("2023-07-01T10:00", "AAAA", "BBBB", 500, block=60)], year=2021)

case("ties_go_to_earliest",
     # Given out of order: sorting by departure makes the 1 March flights the earliest.
     [fl("2025-03-05T10:00", "CCCC", "DDDD", 800, ident="T3", block=100),
      fl("2025-03-01T10:00", "AAAA", "BBBB", 800, ident="T1", block=100),
      fl("2025-03-03T10:00", "BBBB", "CCCC", 200, ident="T2", block=40),
      fl("2025-03-04T10:00", "DDDD", "EEEE", 200, ident="T4", block=40),
      fl("2025-03-02T10:00", "EEEE", "FFFF", 500, ident="T5", block=None)])

case("connection_chain_overnight",
     # Four legs, each under 8 h on the ground, the last two after local midnight in Los Angeles:
     # KSEA, KSFO and KLAX are connections, so only the first origin and every destination count.
     [fl("2025-09-01T03:00", "CYVR", "KSEA", 200, tz="America/Vancouver", block=60, oc="CA", dc="US"),
      # Lands 04:00 UTC, departs 06:30 UTC (23:30 local on 31 August).
      fl("2025-09-01T06:30", "KSEA", "KSFO", 1090, tz=LA, block=120, oc="US", dc="US"),
      # Lands 08:30 UTC, departs 09:15 UTC (02:15 local on 1 September).
      fl("2025-09-01T09:15", "KSFO", "KLAX", 540, tz=LA, block=80, oc="US", dc="US"),
      # Lands 10:35 UTC, departs 18:34 UTC: 7 h 59 min.
      fl("2025-09-01T18:34", "KLAX", "MMMX", 2500, tz=LA, block=240, oc="US", dc="MX"),
      # Back the next day well over 8 h later: MMMX counts as a visit on both ends.
      fl("2025-09-03T18:00", "MMMX", "KLAX", 2500, tz="America/Mexico_City", block=240, oc="MX", dc="US")])

case("iso2_case_and_duplicate_reference",
     # "fr", " FR " and "FR" are one country; the reference lists FR twice (the second time in the
     # wrong region) and "us" in lower case: totals and visits count each code once, in its first region.
     [fl("2025-10-01T10:00", "LFPG", "LFMN", 690, block=85, oc="fr", dc=" FR "),
      fl("2025-10-02T10:00", "LFMN", "KJFK", 6400, block=540, oc="FR", dc="us"),
      fl("2025-10-03T10:00", "KJFK", "KBOS", 300, block=70, oc="US", dc="  ")],
     countries=[{"iso2": "FR", "region": "europe"}, {"iso2": "fr", "region": "asia"},
                {"iso2": "us", "region": "north_america"}, {"iso2": "GB", "region": "europe"},
                {"iso2": "", "region": "oceania"}])

case("sparse",
     [fl("2025-08-01T10:00", "AAAA", "BBBB", 700, airline=None, ac=None, block=None),
      fl("2025-08-03T10:00", "BBBB", "AAAA", 700, airline=None, ac=None, block=None)],
     countries=[])

meta = {
    "generator": "core/fixtures/gen_passport_detail.py",
    "rules": {
        "excluded_status": "canceled",
        "year_filter": "local departure year in the flight tz; unknown tz falls back to UTC; year null = all time",
        "per_year": "flights per local departure year over all time (ignores year), ascending, years with flights only",
        "per_month": "12 counts, January first, local departure time in the flight tz",
        "per_weekday": "7 counts, Monday first, local departure time in the flight tz",
        "long_haul_distance_km_gte": LONG_HAUL_KM,
        "country_known": "a non-empty origin_country or destination_country",
        "domestic": "both countries known and equal",
        "international": "both countries known and different",
        "unknown_country_flights": "flights with at least one unknown country; domestic + international + unknown = flights",
        "earth_km": EARTH_KM,
        "moon_km": MOON_KM,
        "sun_km": SUN_KM,
        "ratios": "distance_km / constant, IEEE double",
        "averages": "rounded half up to integer, 0 when nothing to average",
        "avg_distance_km": "distance_km / flights",
        "flight_minutes": "sum of block_minutes, null counts as 0",
        "avg_flight_minutes": "flight_minutes / flights that have block_minutes",
        "air_minutes": "sum of air_minutes, null counts as 0",
        "taxi_minutes": "sum of max(0, block_minutes - air_minutes) over flights with both",
        "shortest_longest": "ties go to the earliest departed_at (input order on equal instants); by time ignores flights without block_minutes; null when none",
        "airport_visits": "flights sorted by departed_at; destination one visit; origin one visit unless the previous flight landed there (departed_at + 60 * block_minutes, null block counts 0) under 28800 s before this departure; sorted visits desc then icao asc",
        "connection_seconds_lt": CONNECTION_S,
        "airline_key": "airline as given; null or empty skipped",
        "route_key": "ORIG-DEST ICAO, direction kept",
        "tally_by_flights_order": "flights desc, distance_km desc, key asc",
        "tally_by_distance_order": "distance_km desc, flights desc, key asc",
        "country_codes": "origin_country, destination_country and reference iso2 compare trimmed and upper case; empty is unknown",
        "countries": "each known country once per flight (upper case); sorted flights desc then iso2 asc",
        "regions": "all nine in declaration order; the reference is deduplicated by iso2 (first listing wins, empty codes dropped); total = reference countries in the region; visited = distinct visited countries in the region (countries absent from the reference count nowhere)",
    },
}
here = os.path.dirname(os.path.abspath(__file__))
with open(os.path.join(here, "passport_detail.json"), "w") as f:
    json.dump({"meta": meta, "cases": cases}, f, indent=2); f.write("\n")
