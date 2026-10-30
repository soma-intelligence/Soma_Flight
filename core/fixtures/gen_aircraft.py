#!/usr/bin/env python3
"""Regenerates aircraft.json. Independent of the Rust code (stdlib only, zoneinfo for local time).
Seat positions are derived from a cabin drawing per family (letters, gaps for aisles), not from a
letter table, and ages from calendar arithmetic on datetime objects.
Usage: python3 core/fixtures/gen_aircraft.py   (writes aircraft.json next to this script)
"""
import json, os
from collections import Counter, defaultdict
from datetime import datetime, timezone
from zoneinfo import ZoneInfo

# Economy cabin per family, left to right, a space for each aisle.
CABINS = {
    "a320": "ABC DEF", "b737": "ABC DEF", "b737max": "ABC DEF", "b757": "ABC DEF",
    "a220": "AC DEF",
    "ejet": "AC DF", "atr": "AC DF",
    "crj": "AB CD",
    "a350": "ABC DEF HJK", "b787": "ABC DEF HJK",
    "b777": "ABC DEFG HJK", "b747": "ABC DEFG HJK", "a380": "ABC DEFG HJK",
    "a330": "AC DEFG HK",
    "b767": "AC DEF HK",
}


def place(cabin, letter):
    """Window at either end of the row, aisle next to a gap, middle otherwise."""
    i = cabin.find(letter)
    if i < 0 or letter == " ":
        return None
    if i == 0 or i == len(cabin) - 1:
        return "window"
    if cabin[i - 1] == " " or cabin[i + 1] == " ":
        return "aisle"
    return "middle"


def seat_position(seat, family):
    s = (seat or "").strip().upper()
    if not (2 <= len(s) <= 4) or not s[:-1].isdigit() or not s[:-1].isascii():
        return None
    letter = s[-1]
    if not ("A" <= letter <= "Z"):
        return None
    cabin = CABINS.get((family or "").strip().lower())
    return place(cabin, letter) if cabin else None


def ts(s):
    """UTC 'YYYY-MM-DDTHH:MM' (or 'YYYY-MM-DD') to epoch seconds."""
    fmt = "%Y-%m-%dT%H:%M" if "T" in s else "%Y-%m-%d"
    return int(datetime.strptime(s, fmt).replace(tzinfo=timezone.utc).timestamp())


def fl(utc, ac="A320", reg=None, airline="AAL", km=1000, block=None, tz="UTC", status="completed",
       seat_class=None, seat=None, reason=None, ident="XX1", seat_position=None):
    return {"departed_at": ts(utc), "tz": tz, "ident": ident, "origin_icao": "AAAA",
            "destination_icao": "BBBB", "airline": airline, "aircraft_type": ac, "distance_km": km,
            "block_minutes": block, "delay_minutes": 0, "status": status,
            "origin_country": None, "destination_country": None, "air_minutes": None,
            "registration": reg, "seat_class": seat_class, "seat": seat, "reason": reason,
            "seat_position": seat_position}


def code(v):
    """Codes compare trimmed and upper case; empty means unknown."""
    v = (v or "").strip().upper()
    return v or None


def local_year(f):
    try:
        z = ZoneInfo(f["tz"])
    except Exception:
        z = timezone.utc
    return datetime.fromtimestamp(f["departed_at"], tz=z).year


def months_between(t0, t1):
    a = datetime.fromtimestamp(t0, tz=timezone.utc)
    b = datetime.fromtimestamp(t1, tz=timezone.utc)
    m = (b.year - a.year) * 12 + (b.month - a.month)
    if (b.day, b.hour, b.minute, b.second) < (a.day, a.hour, a.minute, a.second):
        m -= 1
    return max(0, m)


def stats(flights, year, types, facts, as_of):
    kept = [f for f in flights if f["status"] != "canceled" and (year is None or local_year(f) == year)]
    kept.sort(key=lambda f: f["departed_at"])

    ref = {}
    for t in types:
        ref.setdefault(code(t["icao_type"]), t)
    ref.pop(None, None)

    flown = [f for f in kept if code(f["aircraft_type"])]
    type_keys = {code(f["aircraft_type"]) for f in flown}

    by_maker = Counter(ref[code(f["aircraft_type"])]["manufacturer"] for f in flown
                       if code(f["aircraft_type"]) in ref)
    total_known = sum(by_maker.values())
    # Half up in integers: floor(100 * v / total + 1/2).
    manufacturers = [{"key": k, "flights": v, "percent": (200 * v + total_known) // (2 * total_known)}
                     for k, v in by_maker.items()]
    manufacturers.sort(key=lambda m: (-m["flights"], m["key"]))

    rows = []
    for k in sorted(type_keys):
        mine = [f for f in flown if code(f["aircraft_type"]) == k]
        rows.append({"icaoType": k, "flights": len(mine),
                     "minutes": sum(f["block_minutes"] or 0 for f in mine),
                     "distanceKm": sum(f["distance_km"] for f in mine)})
    by_flights = sorted(rows, key=lambda r: (-r["flights"], r["icaoType"]))
    by_minutes = sorted(rows, key=lambda r: (-r["minutes"], -r["flights"], r["icaoType"]))
    by_distance = sorted(rows, key=lambda r: (-r["distanceKm"], -r["flights"], r["icaoType"]))

    fact_of = {}
    for x in facts:
        fact_of.setdefault(code(x["registration"]), x)
    fact_of.pop(None, None)

    legs = defaultdict(list)
    for f in kept:
        r = code(f["registration"])
        if r:
            legs[r].append(f)

    def latest(fs, key):
        vals = [k for k in (key(f) for f in fs) if k]
        return vals[-1] if vals else None

    tails = []
    for r, fs in legs.items():
        x = fact_of.get(r)
        tails.append({"registration": r, "flights": len(fs),
                      "icaoType": latest(fs, lambda f: code(f["aircraft_type"])),
                      "airline": latest(fs, lambda f: f["airline"] or None),
                      "name": x["name"] if x else None})
    tails.sort(key=lambda t: (-t["flights"], t["registration"]))

    classes = Counter(f["seat_class"] for f in kept if f["seat_class"])
    positions = Counter()
    for f in kept:
        # The position the traveller picked wins; else it comes from the seat and the cabin layout.
        t = ref.get(code(f["aircraft_type"]))
        p = f.get("seat_position") or (seat_position(f["seat"], t["family"]) if t else None)
        if p:
            positions[p] += 1
    seats = Counter(code(f["seat"]) for f in kept if code(f["seat"]))
    fav = sorted(seats.items(), key=lambda kv: (-kv[1], kv[0]))
    reasons = Counter(f["reason"] for f in kept if f["reason"])

    aged = []
    for t in tails:
        x = fact_of.get(t["registration"])
        if x and x["delivered_at"] is not None:
            aged.append({"registration": t["registration"], "icaoType": t["icaoType"],
                         "deliveredAt": x["delivered_at"],
                         "ageMonths": months_between(x["delivered_at"], as_of)})

    decade_count = Counter(datetime.fromtimestamp(a["deliveredAt"], tz=timezone.utc).year // 10 * 10
                           for a in aged)
    decades = []
    if decade_count:
        for d in range(min(decade_count), max(decade_count) + 10, 10):
            decades.append({"decade": d, "aircraft": decade_count.get(d, 0)})

    ages = sorted(a["ageMonths"] for a in aged)
    median = ages[(len(ages) - 1) // 2] if ages else None
    newest = min(aged, key=lambda a: (-a["deliveredAt"], a["registration"])) if aged else None
    oldest = min(aged, key=lambda a: (a["deliveredAt"], a["registration"])) if aged else None

    return {
        "totalTypes": len(type_keys),
        "manufacturers": manufacturers,
        "typesByFlights": by_flights,
        "typesByMinutes": by_minutes,
        "typesByDistance": by_distance,
        "mostFlown": by_flights[0] if by_flights else None,
        "tails": tails,
        "seatClasses": {"economy": classes["economy"], "premiumEconomy": classes["premium_economy"],
                        "business": classes["business"], "first": classes["first"],
                        "private": classes["private"]},
        "seatPositions": {"window": positions["window"], "middle": positions["middle"],
                          "aisle": positions["aisle"], "pilot": positions["pilot"],
                          "captain": positions["captain"], "jumpseat": positions["jumpseat"]},
        "favouriteSeat": {"seat": fav[0][0], "flights": fav[0][1]} if fav else None,
        "reasons": {"personal": reasons["personal"], "business": reasons["business"],
                    "crew": reasons["crew"]},
        "decades": decades,
        "medianAgeMonths": median,
        "newest": newest,
        "oldest": oldest,
    }


TYPES = [
    {"icao_type": "A320", "family": "a320", "manufacturer": "Airbus"},
    {"icao_type": "A21N", "family": "a320", "manufacturer": "Airbus"},
    {"icao_type": "BCS3", "family": "a220", "manufacturer": "Airbus"},
    {"icao_type": "A333", "family": "a330", "manufacturer": "Airbus"},
    {"icao_type": "A359", "family": "a350", "manufacturer": "Airbus"},
    {"icao_type": "A388", "family": "a380", "manufacturer": "Airbus"},
    {"icao_type": "B738", "family": "b737", "manufacturer": "Boeing"},
    {"icao_type": "B38M", "family": "b737max", "manufacturer": "Boeing"},
    {"icao_type": "B744", "family": "b747", "manufacturer": "Boeing"},
    {"icao_type": "B752", "family": "b757", "manufacturer": "Boeing"},
    {"icao_type": "B763", "family": "b767", "manufacturer": "Boeing"},
    {"icao_type": "B77W", "family": "b777", "manufacturer": "Boeing"},
    {"icao_type": "B789", "family": "b787", "manufacturer": "Boeing"},
    {"icao_type": "E175", "family": "ejet", "manufacturer": "Embraer"},
    {"icao_type": "CRJ9", "family": "crj", "manufacturer": "Bombardier"},
    {"icao_type": "AT76", "family": "atr", "manufacturer": "ATR"},
    {"icao_type": "B712", "family": "other", "manufacturer": "Boeing"},
]

AS_OF = ts("2026-10-29T12:00")

cases = []


def case(name, flights, year=None, types=TYPES, facts=(), as_of=AS_OF):
    facts = list(facts)
    cases.append({"name": name, "year": year, "as_of": as_of, "types": types, "facts": facts,
                  "flights": flights, "expected": stats(flights, year, types, facts, as_of)})


def fact(reg, delivered=None, name=None):
    return {"registration": reg, "delivered_at": ts(delivered) if delivered else None, "name": name}


case("empty", [])

case("single_flight",
     [fl("2025-03-01T10:00", ac="A359", reg="F-HTYA", airline="AFR", km=8950, block=665,
         seat_class="business", seat="7A", reason="business")],
     facts=[fact("F-HTYA", "2019-03-15", "Toulouse")])

case("single_aircraft",
     # Three flights on one tail: the median of one aircraft is its age (2019-03-15 to 2026-10-29 is 91 months).
     [fl("2024-01-10T10:00", ac="B38M", reg="N8701Q", airline="SWA", block=120, seat="14C"),
      fl("2024-05-10T10:00", ac="B38M", reg="N8701Q", airline="SWA", block=110, seat="14C"),
      fl("2025-02-10T10:00", ac="B38M", reg="n8701q ", airline="SWA", block=100, seat="22F")],
     facts=[fact("N8701Q", "2019-03-15", None)])

every = []
day = 1
for i, t in enumerate(TYPES):
    for letter in "ABCDEFGHJK":
        every.append(fl(f"2025-{1 + i % 12:02d}-{1 + day % 28:02d}T{day % 24:02d}:00", ac=t["icao_type"],
                        seat=f"{10 + day % 40}{letter}"))
        day += 1
case("seat_positions_every_layout", every)

case("unknown_family_seat",
     # Known type with family "other", a type absent from the reference, a letter outside every cabin,
     # a malformed seat and no seat at all: none of them has a position, but every seat still counts
     # towards the favourite.
     [fl("2025-01-01T10:00", ac="B712", seat="12A"),
      fl("2025-01-02T10:00", ac="C25B", seat="1A"),
      fl("2025-01-03T10:00", ac="A320", seat="12K"),
      fl("2025-01-04T10:00", ac="A320", seat="aisle"),
      fl("2025-01-05T10:00", ac="A320", seat=None),
      fl("2025-01-06T10:00", ac="A320", seat=" 12a "),
      fl("2025-01-07T10:00", ac="CRJ9", seat="3E")])

case("decades_with_gap",
     # Deliveries in the 1980s, 1990s and 2020s: the 2000s and 2010s show as empty decades.
     [fl("2024-01-01T10:00", ac="B744", reg="G-CIVA", airline="BAW"),
      fl("2024-02-01T10:00", ac="B744", reg="G-CIVB", airline="BAW"),
      fl("2024-03-01T10:00", ac="B763", reg="N171DN", airline="DAL"),
      fl("2024-04-01T10:00", ac="A21N", reg="D-AIEA", airline="DLH"),
      fl("2024-05-01T10:00", ac="A21N", reg="D-AIEB", airline="DLH"),
      fl("2024-06-01T10:00", ac="A21N", reg="D-AIEA", airline="DLH"),
      fl("2024-07-01T10:00", ac="A320", reg="F-GKXA", airline="AFR")],
     facts=[fact("G-CIVA", "1989-12-31T23:59"),  # 1980s, by the last minute of the decade
            fact("G-CIVB", "1993-06-01"),
            fact("N171DN", "1990-01-01"),
            fact("D-AIEA", "2021-10-29T12:00", "Saarbrucken"),  # exactly 60 months before as_of
            fact("D-AIEB", "2021-10-29T12:01"),  # one minute short: 59 months
            fact("F-GKXA", None, "Ventoux"),  # no delivery date: no age, still named
            fact("D-AIEA", "1970-01-01", "Duplicate fact, first wins")])

case("manufacturer_percent_rounding",
     # 8 flights on known types: Airbus 3 (37.5 % -> 38), Boeing 3 (38), Embraer 1 (12.5 % -> 13),
     # ATR 1 (13). The unknown C25B counts as a type but in no manufacturer.
     [fl("2025-01-01T10:00", ac="A320"), fl("2025-01-02T10:00", ac="A333"),
      fl("2025-01-03T10:00", ac="A320"), fl("2025-01-04T10:00", ac="B738"),
      fl("2025-01-05T10:00", ac="B738"), fl("2025-01-06T10:00", ac="B789"),
      fl("2025-01-07T10:00", ac="E175"), fl("2025-01-08T10:00", ac="AT76"),
      fl("2025-01-09T10:00", ac="C25B"),
      fl("2025-01-10T10:00", ac="B712", status="canceled")])

case("type_tally_ties",
     # Same flights: by minutes and by distance break ties on flights, then on the type code.
     [fl("2025-02-01T10:00", ac="B738", km=500, block=60),
      fl("2025-02-02T10:00", ac="A320", km=500, block=60),
      fl("2025-02-03T10:00", ac="A320", km=1000, block=None),
      fl("2025-02-04T10:00", ac="E175", km=1500, block=120),
      fl("2025-02-05T10:00", ac="CRJ9", km=500, block=60),
      fl("2025-02-06T10:00", ac=" b738 ", km=1000, block=60),
      fl("2025-02-07T10:00", ac="", km=9000, block=600),
      fl("2025-02-08T10:00", ac=None, km=9000, block=600)])

case("tails_and_classes",
     [fl("2025-03-01T10:00", ac="A359", reg="F-HTYA", airline="AFR", seat_class="economy", reason="personal",
         seat="31A"),
      fl("2025-03-05T10:00", ac="A359", reg="F-HTYA", airline=None, seat_class="premium_economy",
         reason="business", seat="31A"),
      fl("2025-03-09T10:00", ac=None, reg="F-HTYA", airline="AFR", seat_class="business", seat="2A"),
      fl("2025-03-12T10:00", ac="B77W", reg="F-GSQA", airline="AFR", seat_class="first", reason="personal",
         seat="1A"),
      fl("2025-03-15T10:00", ac="B77W", reg="F-GSQA", airline="AFR", seat_class="economy", reason="personal",
         seat="40K"),
      fl("2025-03-18T10:00", ac="A320", reg="", airline="AFR", seat_class="economy", seat="12C"),
      fl("2025-03-20T10:00", ac="A320", reg="F-GKXA", airline="AFR", status="canceled", seat="31A")],
     facts=[fact("F-HTYA", "2019-09-15", "Toulouse"), fact("F-GSQA", "2002-04-02", None),
            fact("F-GZZZ", "2024-01-01", "Never flown")])

case("ages_newest_oldest_ties",
     # Six aircraft (even count): median is the lower middle (128, not 200). Two share the newest delivery,
     # the registration breaks the tie. One is delivered after as_of: age 0.
     [fl("2025-04-01T10:00", ac="A320", reg="C-FAAA"),
      fl("2025-04-02T10:00", ac="A320", reg="C-FBBB"),
      fl("2025-04-03T10:00", ac="A320", reg="C-FCCC"),
      fl("2025-04-04T10:00", ac="A320", reg="C-FDDD"),
      fl("2025-04-05T10:00", ac="A320", reg="C-FEEE"),
      fl("2025-04-06T10:00", ac="A320", reg="C-FFFF")],
     facts=[fact("C-FAAA", "2010-01-31"), fact("C-FBBB", "2026-12-01"), fact("C-FCCC", "2026-12-01"),
            fact("C-FDDD", "2016-02-29"), fact("C-FEEE", "2000-05-20"), fact("C-FFFF", "1999-01-01")])

case("no_facts",
     [fl("2025-05-01T10:00", ac="A320", reg="N401UA", airline="UAL"),
      fl("2025-05-02T10:00", ac="B789", reg="N26902", airline="UAL")])

case("year_filter",
     [fl("2023-07-01T10:00", ac="A320", reg="N401UA", seat_class="economy", seat="12A", reason="personal"),
      fl("2024-03-01T10:00", ac="B789", reg="N26902", seat_class="business", seat="4A", reason="business"),
      fl("2024-09-01T10:00", ac="B789", reg="N26902", seat_class="business", seat="4A", reason="business"),
      # 2025-01-01 07:30 UTC is still 2024 in Los Angeles.
      fl("2025-01-01T07:30", ac="A320", reg="N402UA", tz="America/Los_Angeles", seat="20F"),
      fl("2025-06-01T10:00", ac="B38M", reg="N8701Q", seat="14C"),
      fl("2024-10-01T10:00", ac="A388", reg="A6-EDA", status="canceled")],
     year=2024,
     facts=[fact("N401UA", "1994-02-01"), fact("N26902", "2013-08-30"), fact("N402UA", "1994-03-01"),
            fact("N8701Q", "2017-11-01"), fact("A6-EDA", "2008-07-28")])

case("picked_positions_private_crew",
     # A picked position wins over the seat's layout (14A on an A320 is a window, counted as aisle here);
     # cockpit positions count without a seat; an unknown type still counts a picked position.
     [fl("2025-09-01T10:00", ac="A320", seat="14A", seat_position="aisle", seat_class="private",
         reason="crew"),
      fl("2025-09-02T10:00", ac="B738", seat_position="pilot", reason="crew"),
      fl("2025-09-03T10:00", ac="B738", seat_position="captain", reason="crew"),
      fl("2025-09-04T10:00", ac="ZZZZ", seat_position="jumpseat", seat_class="private", reason="personal"),
      fl("2025-09-05T10:00", ac="A320", seat="14A", seat_class="economy", reason="business")])

case("sparse",
     # No registrations, no seats, no classes, no reasons, types unknown to the reference.
     [fl("2025-08-01T10:00", ac="ZZZZ", airline=None),
      fl("2025-08-03T10:00", ac=None, airline=None)],
     types=[])

seat_table = []
for fam in sorted(CABINS) + ["other", "", "A320"]:
    for letter in "ABCDEFGHIJKL":
        s = f"23{letter}"
        seat_table.append({"seat": s, "family": fam, "expected": seat_position(s, fam)})
for s, fam in [(" 7a ", "a320"), ("7", "a320"), ("A", "a320"), ("1234A", "a320"), ("123A", "a320"),
               ("12AB", "a320"), ("", "a320"), ("12 A", "a320"), ("-1A", "a320"), ("12A", " B777 ")]:
    seat_table.append({"seat": s, "family": fam, "expected": seat_position(s, fam)})

meta = {
    "generator": "core/fixtures/gen_aircraft.py",
    "rules": {
        "excluded_status": "canceled",
        "year_filter": "local departure year in the flight tz; unknown tz falls back to UTC; year null = all time",
        "codes": "aircraft_type, registration, seat and the reference icao_type compare trimmed and upper case; empty is unknown; family compares trimmed and lower case",
        "reference_duplicates": "first entry wins (types by icao_type, facts by registration)",
        "total_types": "distinct known aircraft_type over kept flights, including types absent from the reference",
        "manufacturers": "flights per manufacturer of reference types; flights on unknown types count nowhere; percent = 100 * flights / flights on reference types, rounded half up; sorted flights desc then key asc",
        "type_minutes": "sum of block_minutes, null counts as 0",
        "types_by_flights_order": "flights desc, icao_type asc",
        "types_by_minutes_order": "minutes desc, flights desc, icao_type asc",
        "types_by_distance_order": "distance_km desc, flights desc, icao_type asc",
        "most_flown": "first of types_by_flights, null when none",
        "tails": "one row per known registration; icao_type and airline from the latest kept flight on that tail that has one; name from the fact; sorted flights desc then registration asc",
        "seat_position": "seat trimmed, upper case, 1 to 3 digits then one letter; economy cabin of the family; other families, letters or shapes give null",
        "seat_positions": "kept flights with a picked seat_position (counted as picked), else whose type is in the reference and whose seat has a position",
        "favourite_seat": "most flown seat (trimmed, upper case, any shape), ties seat asc; null when none",
        "aged_aircraft": "distinct registrations over kept flights with a fact that has delivered_at",
        "age_months": "whole calendar months from delivered_at to as_of in UTC (a month counts once day and time of day are reached), 0 when delivered after as_of",
        "decades": "UTC delivery year floored to 10, ascending, every decade from the first to the last, empty ones with 0",
        "median_age_months": "sorted ages, element (n - 1) / 2 (lower middle for an even count); null when no aged aircraft",
        "newest_oldest": "latest and earliest delivered_at, ties registration asc; null when no aged aircraft",
    },
}
here = os.path.dirname(os.path.abspath(__file__))
with open(os.path.join(here, "aircraft.json"), "w") as f:
    json.dump({"meta": meta, "seat_position": seat_table, "cases": cases}, f, indent=2); f.write("\n")
