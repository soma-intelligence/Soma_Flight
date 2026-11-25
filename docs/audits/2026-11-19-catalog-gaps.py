#!/usr/bin/env python3
"""Read-only audit of the Soma Flight reference catalogs and the assets paired with them.

Usage (from the repo root):
    python3 docs/audits/2026-11-19-catalog-gaps.py            # summary + every finding, plain text
    python3 docs/audits/2026-11-19-catalog-gaps.py --json     # the same as JSON

Reads only. Needs Python 3.10+, Pillow and numpy (for the blank-art checks).
Sources checked:
  - Packages/FlightKit/Sources/FlightKit/Resources/Reference/*.json, airports.tsv
  - Resources/SideViews (index.json + webp), Resources/Tails, Resources/Logos (commons-logos.json + webp),
    Resources/Licenses/airline-logos.json, Resources/Flags.xcassets, Resources/Illustrations.xcassets
  - Services/BundledSideViews.swift (sibling + familyType maps), Services/AirlineParents.swift,
    Models/AircraftType.swift (family enum)
  - supabase/seed/*.csv, supabase/migrations (reference seed + business jets), supabase/scripts/build_reference_seed.ts
  - core/flightcore/src/aircraft.rs (family strings)
  - aircraft-art/ai, aircraft-art/silhouette, aircraft-art/brand/kit, aircraft-art/unknown_types.tsv (git ignored, local only)
"""
import csv
import json
import os
import re
import sys
from collections import Counter, defaultdict
from zoneinfo import available_timezones

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "../.."))
FK = os.path.join(ROOT, "Packages/FlightKit/Sources/FlightKit")
RES = os.path.join(FK, "Resources")
REF = os.path.join(RES, "Reference")
ART = os.path.join(ROOT, "aircraft-art")
SB = os.path.join(ROOT, "supabase")

findings = []  # (catalog, severity, check, items)
counts = {}


def add(catalog, severity, check, items):
    items = sorted(set(items)) if not isinstance(items, list) else items
    if items:
        findings.append({"catalog": catalog, "severity": severity, "check": check, "count": len(items), "items": items})


def load(name):
    with open(os.path.join(REF, name)) as f:
        return json.load(f)


def read(path):
    with open(path) as f:
        return f.read()


# ---------------------------------------------------------------------------------------------------------
# Load the catalogs
types = load("aircraft_types.json")
airlines = load("airlines.json")
countries = load("countries.json")
contacts = load("airline_contacts.json")["airlines"]
destinations = load("destinations.json")["countries"]
livery_seed = load("livery_seed.json")
sizes = load("airport_sizes.json")
rules = load("connection_rules.json")

airports = []
for line in read(os.path.join(REF, "airports.tsv")).splitlines():
    if not line.strip():
        continue
    f = line.split("\t")
    f += [""] * (8 - len(f))
    airports.append(dict(icao=f[0], iata=f[1], name=f[2], city=f[3], country=f[4], lat=f[5], lon=f[6], tz=f[7], ncols=len(line.split("\t"))))

type_codes = [t["icaoType"] for t in types]
type_set = set(type_codes)
airline_codes = [a["icao"] for a in airlines]
airline_set = set(airline_codes)
country_set = {c["iso2"] for c in countries}
airport_set = {a["icao"] for a in airports}

side_index = json.load(open(os.path.join(RES, "SideViews/index.json")))
side_pairs = side_index["pairs"]
side_files = {f[:-5] for f in os.listdir(os.path.join(RES, "SideViews")) if f.endswith(".webp")}
tail_files = {f[5:-5] for f in os.listdir(os.path.join(RES, "Tails")) if f.startswith("tail-") and f.endswith(".webp")}
logo_index = json.load(open(os.path.join(RES, "Logos/commons-logos.json")))
logo_dir = os.listdir(os.path.join(RES, "Logos"))
wordmark_files = {f[len("commons-wordmark-"):-5] for f in logo_dir if f.startswith("commons-wordmark-")}
symbol_files = {f[len("commons-symbol-"):-5] for f in logo_dir if f.startswith("commons-symbol-")}
lic = json.load(open(os.path.join(RES, "Licenses/airline-logos.json")))
flag_sets = {d[len("flag-"):-len(".imageset")] for d in os.listdir(os.path.join(RES, "Flags.xcassets")) if d.endswith(".imageset")}

counts["aircraft_types"] = len(types)
counts["airlines"] = len(airlines)
counts["airports"] = len(airports)
counts["countries"] = len(countries)
counts["side_view_pairs_index"] = len(side_pairs)
counts["side_view_webp"] = len(side_files)
counts["tails"] = len(tail_files)
counts["logo_wordmarks_index"] = len(logo_index["wordmarks"])
counts["logo_symbols_index"] = len(logo_index["symbols"])
counts["logo_licence_entries"] = len(lic)
counts["flags"] = len(flag_sets)

# ---------------------------------------------------------------------------------------------------------
# Aircraft types
C = "aircraft types"
swift_families = re.search(r"case (a220[^\n]*)", read(os.path.join(FK, "Models/AircraftType.swift"))).group(1)
swift_families = {s.strip() for s in swift_families.split(",")}
add(C, "data", "duplicate icaoType", [k for k, n in Counter(type_codes).items() if n > 1])
for field in ("family", "manufacturer", "name"):
    add(C, "data", f"empty {field}", [t["icaoType"] for t in types if not str(t.get(field, "")).strip()])
add(C, "data", "family not in the Swift AircraftFamily enum", [f"{t['icaoType']}={t['family']}" for t in types if t["family"] not in swift_families])
add(C, "low", "family 'other' (generic fallback drawing family)", [t["icaoType"] for t in types if t["family"] == "other"])
add(C, "data", "icaoType not 2-4 upper case letters or digits", [c for c in type_codes if not re.fullmatch(r"[A-Z0-9]{2,4}", c)])
fam_by_type = {t["icaoType"]: t["family"] for t in types}
counts["aircraft_types_by_family"] = dict(sorted(Counter(fam_by_type.values()).items()))
# name does not mention manufacturer (often a sign of a wrong manufacturer field)
add(C, "low", "name does not start with the manufacturer", [f"{t['icaoType']}: {t['manufacturer']} / {t['name']}" for t in types
                                                          if t["manufacturer"] and not t["name"].lower().startswith(t["manufacturer"].lower().split()[0])])

# side view coverage per type
pairs_by_type = defaultdict(set)
pairs_by_airline = defaultdict(set)
for p in side_pairs:
    a, t = p.split("-", 1)
    pairs_by_type[t].add(a)
    pairs_by_airline[a].add(t)
plain = {t for t, a in pairs_by_type.items() if "ZZZ" in a}
add(C, "visible", "type with no side view at all (any airline or plain): app falls back to a sibling or the family's common type",
    [f"{t} ({fam_by_type[t]})" for t in type_codes if t not in pairs_by_type])
add(C, "visible", "type with no plain ZZZ side view in the bundle (unknown or unbundled airline gets a sibling type)",
    [t for t in type_codes if t not in plain])
add(C, "data", "side view type not in aircraft_types.json (orphan pairs)", [p for p in side_pairs if p.split("-", 1)[1] not in type_set])

src_bsv = read(os.path.join(FK, "Services/BundledSideViews.swift"))
sib = dict(re.findall(r'"([A-Z0-9]{2,4})": "([A-Z0-9]{2,4})"', src_bsv.split("static let sibling")[1].split("= [", 1)[1].split("]")[0]))
fam_type = dict(re.findall(r'\.(\w+): "([A-Z0-9]{2,4})"', src_bsv.split("static let familyType")[1].split("= [", 1)[1].split("]")[0]))
add(C, "data", "BundledSideViews.sibling key not in aircraft_types.json", [k for k in sib if k not in type_set])
add(C, "visible", "BundledSideViews.sibling target with no plain ZZZ view", [f"{k}->{v}" for k, v in sib.items() if v not in plain])
add(C, "data", "AircraftFamily case missing from BundledSideViews.familyType", [f for f in swift_families if f not in fam_type])
add(C, "visible", "BundledSideViews.familyType target with no plain ZZZ view", [f"{k}->{v}" for k, v in fam_type.items() if v not in plain])

# Supabase and Rust drift
seed_types = list(csv.DictReader(open(os.path.join(SB, "seed/aircraft_types.csv"))))
mig_jets = read(os.path.join(SB, "migrations/20261109000001_business_jets.sql"))
for extra in ("20261119000002_more_aircraft_types.sql",):
    if os.path.exists(os.path.join(SB, "migrations", extra)):
        mig_jets += read(os.path.join(SB, "migrations", extra))
jet_rows = re.findall(r"\('([A-Z0-9]{2,4})', '(\w+)', '([^']*)', '([^']*)'\)", mig_jets)
db_types = {r["icao_type"]: r for r in seed_types}
for c, fam, man, name in jet_rows:
    db_types[c] = {"icao_type": c, "family": fam, "manufacturer": man, "name": name}
for m in re.finditer(r"update aircraft_types set family = '(\w+)' where icao_type = '([A-Z0-9]+)'", mig_jets):
    if m.group(2) in db_types:
        db_types[m.group(2)]["family"] = m.group(1)
counts["aircraft_types_supabase"] = len(db_types)
add(C, "data", "in aircraft_types.json, not in Supabase (seed csv + migrations)", [c for c in type_codes if c not in db_types])
add(C, "data", "in Supabase, not in aircraft_types.json", [c for c in db_types if c not in type_set])
add(C, "data", "field differs between aircraft_types.json and Supabase", [
    f"{t['icaoType']}.{k}: app={t[k2]!r} db={db_types[t['icaoType']][k]!r}"
    for t in types if t["icaoType"] in db_types
    for k, k2 in (("family", "family"), ("manufacturer", "manufacturer"), ("name", "name"))
    if (db_types[t["icaoType"]].get(k) or "") != (t.get(k2) or "")])
ts_src = read(os.path.join(SB, "scripts/build_reference_seed.ts"))
ts_fams = set(re.findall(r'"(\w+)"', ts_src.split("export const FAMILIES")[1].split("]")[0]))
add(C, "data", "family in Swift enum, missing from build_reference_seed.ts FAMILIES (rebuild would reject or drop it)", [f for f in swift_families if f not in ts_fams])
rust = read(os.path.join(ROOT, "core/flightcore/src/aircraft.rs"))
rust_fams = set(re.findall(r'"(a220|a320|a330|a350|a380|b737max|b737|b747|b757|b767|b777|b787|ejet|crj|atr|bizjet|other|[a-z]+jet)"', rust))
counts["rust_family_strings_seen"] = sorted(rust_fams)

# aircraft-art pipeline (local, git ignored)
if os.path.isdir(ART):
    ai = {f[:-4] for f in os.listdir(os.path.join(ART, "ai")) if re.fullmatch(r"[A-Z0-9]{3}-[A-Z0-9]{2,4}\.png", f)}
    counts["aircraft_art_ai_pairs"] = len(ai)
    add(C, "visible", "aircraft-art render (ai/<pair>.png) not in the bundle (rerun bundle_side_views.py)", [p for p in ai if p not in side_files])
    add(C, "data", "bundled side view with no source render in aircraft-art/ai (cannot be rebuilt)", [p for p in side_files if p not in ai])
    sil = {f[:-4] for f in os.listdir(os.path.join(ART, "silhouette")) if f.endswith(".png")}
    counts["aircraft_art_silhouettes"] = len(sil)
    add(C, "low", "type with no grey silhouette in aircraft-art/silhouette (silhouettes are not bundled at all yet)", [t for t in type_codes if t not in sil])
    add(C, "data", "silhouette for a type not in aircraft_types.json", [t for t in sil if t not in type_set])
    unknown = [l.split("\t") for l in read(os.path.join(ART, "unknown_types.tsv")).splitlines() if l.strip()]
    add(C, "data", "type flown by seed fleets (aircraft-art/unknown_types.tsv) not in aircraft_types.json",
        [f"{u[0]} (x{u[1]})" for u in unknown if u[0] not in type_set])
    ai_types = {p.split("-", 1)[1] for p in ai}
    add(C, "data", "aircraft-art render type not in aircraft_types.json", [t for t in ai_types if t not in type_set])

# ---------------------------------------------------------------------------------------------------------
# Airlines
C = "airlines"
add(C, "data", "duplicate ICAO", [k for k, n in Counter(airline_codes).items() if n > 1])
iatas = [a["iata"] for a in airlines if a["iata"]]
dup_iata = {k for k, n in Counter(iatas).items() if n > 1}
add(C, "visible", "IATA shared by several airlines (flight number 'XX123' resolves to the first in file order)",
    [f"{i}: " + ", ".join(f"{a['icao']} {a['name']}" for a in airlines if a["iata"] == i) for i in dup_iata])
add(C, "data", "ICAO not 3 upper case letters", [c for c in airline_codes if not re.fullmatch(r"[A-Z]{3}", c)])
add(C, "data", "IATA not 2 upper case letters or digits", [f"{a['icao']}={a['iata']!r}" for a in airlines if a["iata"] and not re.fullmatch(r"[A-Z0-9]{2}", a["iata"])])
add(C, "low", "no IATA code (flight numbers in IATA form will not find it)", [a["icao"] for a in airlines if not a["iata"]])
add(C, "data", "empty name", [a["icao"] for a in airlines if not a["name"].strip()])
add(C, "low", "empty country", [a["icao"] for a in airlines if not a["country"]])
add(C, "data", "country not in countries.json", [f"{a['icao']}={a['country']}" for a in airlines if a["country"] and a["country"] not in country_set])
add(C, "data", "alliance not star_alliance / oneworld / skyteam", [f"{a['icao']}={a['alliance']}" for a in airlines if a["alliance"] and a["alliance"] not in ("star_alliance", "oneworld", "skyteam")])
add(C, "low", "empty callsign", [a["icao"] for a in airlines if not a["callsign"]])
add(C, "low", "empty website", [a["icao"] for a in airlines if not a["website"]])
add(C, "visible", "colorPrimary is the grey default #5E6673 (derived livery and tints are grey)", [a["icao"] for a in airlines if a["colorPrimary"].upper() == "#5E6673"])
add(C, "data", "colorPrimary empty or not #RRGGBB", [f"{a['icao']}={a['colorPrimary']!r}" for a in airlines if not re.fullmatch(r"#[0-9A-Fa-f]{6}", a["colorPrimary"] or "")])
add(C, "data", "colorSecondary not #RRGGBB", [f"{a['icao']}={a['colorSecondary']!r}" for a in airlines if a["colorSecondary"] and not re.fullmatch(r"#[0-9A-Fa-f]{6}", a["colorSecondary"])])
names = Counter(a["name"].strip().lower() for a in airlines)
add(C, "low", "same name on several ICAO codes", [f"{n}: " + ", ".join(a["icao"] for a in airlines if a["name"].strip().lower() == n) for n, k in names.items() if k > 1])

# assets per airline
logo_any = set(logo_index["wordmarks"]) | set(logo_index["symbols"])
parents = dict(re.findall(r'"([A-Z0-9]{3})": "([A-Z0-9]{3})"', read(os.path.join(FK, "Services/AirlineParents.swift"))))


def chain(c):
    out = [c]
    while c in parents and parents[c] not in out:
        c = parents[c]
        out.append(c)
    return out


add(C, "visible", "airline with no bundled logo (wordmark or symbol): monogram shown unless the backend serves one", [a for a in airline_codes if a not in logo_any])
add(C, "visible", "airline with no bundled side view, itself or via AirlineParents (gets the plain ZZZ view)",
    [a for a in airline_codes if not any(c in pairs_by_airline for c in chain(a))])
add(C, "visible", "airline with no tail fin (Resources/Tails)", [a for a in airline_codes if a not in tail_files])
add(C, "low", "airline with a side view but no tail fin", [a for a in pairs_by_airline if a != "ZZZ" and a not in tail_files])
add(C, "low", "airline with a side view but no logo", [a for a in pairs_by_airline if a != "ZZZ" and a not in logo_any])
add(C, "data", "side view airline not in airlines.json (orphan pairs)", [p for p in side_pairs if p.split("-")[0] not in airline_set and p.split("-")[0] != "ZZZ"])
add(C, "data", "tail fin for an ICAO not in airlines.json (orphan)", [t for t in tail_files if t not in airline_set])
add(C, "data", "logo for an ICAO not in airlines.json (orphan)", [c for c in logo_any if c not in airline_set])
add(C, "data", "AirlineParents code not in airlines.json", [f"{k}->{v}" for k, v in parents.items() if k not in airline_set or v not in airline_set])
add(C, "data", "AirlineParents parent has no side view of its own", [f"{k}->{v}" for k, v in parents.items() if v not in pairs_by_airline])

# side views: index vs files
add(C, "data", "side view in index.json with no webp", [p for p in side_pairs if p not in side_files])
add(C, "data", "side view webp not in index.json (never shown)", [p for p in side_files if p not in set(side_pairs)])
add(C, "data", "duplicate side view pair in index.json", [k for k, n in Counter(side_pairs).items() if n > 1])

# logos: index vs files vs licences
add(C, "data", "wordmark in commons-logos.json with no webp", [c for c in logo_index["wordmarks"] if c not in wordmark_files])
add(C, "data", "symbol in commons-logos.json with no webp", [c for c in logo_index["symbols"] if c not in symbol_files])
add(C, "data", "logo webp not in commons-logos.json (never shown)",
    [f"wordmark {c}" for c in wordmark_files if c not in logo_index["wordmarks"]] + [f"symbol {c}" for c in symbol_files if c not in logo_index["symbols"]])
lic_by = {}
for e in lic:
    lic_by.setdefault(e["icao"], []).append(e)
add(C, "data", "duplicate licence entry per ICAO in airline-logos.json", [k for k, v in lic_by.items() if len(v) > 1])
lic_word = {e["icao"] for e in lic if e.get("kind") == "wordmark"}
lic_sym = {e["icao"] for e in lic if e.get("symbol") or e.get("kind") == "symbol"}
add(C, "legal", "shipped wordmark with no licence entry (Acknowledgements misses it)", [c for c in logo_index["wordmarks"] if c not in lic_word])
add(C, "legal", "shipped symbol with no symbol licence entry", [c for c in logo_index["symbols"] if c not in lic_sym])
add(C, "data", "licence entry for a logo that is not shipped", [c for c in lic_by if c not in logo_any])
bad = []
for e in lic:
    for k in ("license", "source", "attribution", "author"):
        if not str(e.get(k) or "").strip():
            bad.append(f"{e['icao']} wordmark: {k}")
    s = e.get("symbol")
    if s:
        for k in ("license", "source", "attribution"):
            if not str(s.get(k) or "").strip():
                bad.append(f"{e['icao']} symbol: {k}")
    lc = (e.get("license") or "").lower()
    if lc and "public domain" not in lc and not e.get("license_url"):
        bad.append(f"{e['icao']}: licence {e['license']!r} without license_url")
add(C, "legal", "licence entry with an empty field", bad)
counts["logo_licences_by_license"] = dict(Counter(e.get("license") for e in lic).most_common())

# Fakes logos ship in the bundle (Resources is processed whole)
fake_logos = os.listdir(os.path.join(RES, "Fakes/Logos"))
add(C, "legal", "Fakes/Logos PNGs ship in the Release bundle (Package.swift processes all of Resources); no licence entry",
    [f for f in fake_logos if f.endswith(".png")])

# contacts, livery seed
add(C, "data", "airline_contacts ICAO not in airlines.json", [c["icao"] for c in contacts if c["icao"] not in airline_set])
amap = {a["icao"]: a for a in airlines}
add(C, "data", "airline_contacts IATA or name differs from airlines.json", [
    f"{c['icao']}: iata {c.get('iata')!r} vs {amap[c['icao']]['iata']!r}" for c in contacts
    if c["icao"] in amap and (c.get("iata") or "") != (amap[c["icao"]]["iata"] or "")] + [
    f"{c['icao']}: name {c.get('name')!r} vs {amap[c['icao']]['name']!r}" for c in contacts
    if c["icao"] in amap and c.get("name") and c["name"] != amap[c["icao"]]["name"]])
add(C, "low", "airline_contacts entry with no phone", [c["icao"] for c in contacts if not c.get("phone")])
add(C, "data", "livery_seed airline not in airlines.json", [l["airline"] for l in livery_seed if l["airline"] not in airline_set])
counts["airline_contacts"] = len(contacts)
counts["livery_seed"] = len(livery_seed)

# Supabase drift (seed csv + later migrations that add airlines)
seed_air = {r["icao"]: r for r in csv.DictReader(open(os.path.join(SB, "seed/airlines.csv")))}
counts["airlines_supabase_seed_csv"] = len(seed_air)
add(C, "data", "in airlines.json, not in supabase/seed/airlines.csv", [c for c in airline_codes if c not in seed_air])
add(C, "data", "in supabase/seed/airlines.csv, not in airlines.json", [c for c in seed_air if c not in airline_set])
diff = []
for a in airlines:
    r = seed_air.get(a["icao"])
    if not r:
        continue
    for k, k2 in (("iata", "iata"), ("name", "name"), ("country", "country"), ("alliance", "alliance"), ("callsign", "callsign"),
                  ("color_primary", "colorPrimary")):
        if (r.get(k) or "") != (a.get(k2) or ""):
            diff.append(f"{a['icao']}.{k}: app={a.get(k2)!r} csv={r.get(k)!r}")
add(C, "data", "field differs between airlines.json and supabase/seed/airlines.csv", diff)
mig_icaos = set()
for m in ("20261030000003_reference_seed.sql", "20261104000010_more_airlines.sql", "20261108000001_all_airlines.sql"):
    p = os.path.join(SB, "migrations", m)
    if os.path.exists(p):
        txt = read(p)
        if "insert into airlines" in txt:
            body = txt.split("insert into airlines", 1)[1].split("insert into", 1)[0]
            mig_icaos |= set(re.findall(r"^\('([A-Z0-9]{3})',", body, re.M))
counts["airlines_supabase_migrations"] = len(mig_icaos)
add(C, "data", "in airlines.json, not inserted by any Supabase migration", [c for c in airline_codes if c not in mig_icaos])
add(C, "data", "inserted by a Supabase migration, not in airlines.json", [c for c in mig_icaos if c not in airline_set])

# ---------------------------------------------------------------------------------------------------------
# Airports
C = "airports"
icaos = [a["icao"] for a in airports]
add(C, "data", "duplicate ICAO", [k for k, n in Counter(icaos).items() if n > 1])
ai_ = [a["iata"] for a in airports if a["iata"]]
add(C, "visible", "IATA shared by several airports (search by IATA picks one)",
    [f"{i}: " + ", ".join(a["icao"] for a in airports if a["iata"] == i) for i, n in Counter(ai_).items() if n > 1])
add(C, "data", "row without 8 tab separated columns (9 with a former code)", [f"{a['icao']} ({a['ncols']})" for a in airports if a["ncols"] not in (8, 9)])
add(C, "low", "no IATA code", [a["icao"] for a in airports if not a["iata"]])
for field in ("name", "city", "country", "tz"):
    add(C, "visible" if field in ("name", "tz") else "low", f"empty {field}", [a["icao"] for a in airports if not a[field].strip()])
tzs = available_timezones()
add(C, "visible", "time zone not a valid IANA zone (local times wrong)", [f"{a['icao']}={a['tz']}" for a in airports if a["tz"] and a["tz"] not in tzs])
add(C, "data", "country not in countries.json (flag-xx disc shown)", [f"{a['icao']}={a['country']}" for a in airports if a["country"] and a["country"] not in country_set])
badc = []
for a in airports:
    try:
        la, lo = float(a["lat"]), float(a["lon"])
        if not (-90 <= la <= 90 and -180 <= lo <= 180) or (la == 0 and lo == 0):
            badc.append(a["icao"])
    except ValueError:
        badc.append(a["icao"])
add(C, "visible", "missing or invalid coordinates", badc)
size_codes = [c for v in sizes.values() if isinstance(v, list) for c in v]
add(C, "data", "airport_sizes.json code not in airports.tsv", [c for c in size_codes if c not in airport_set])
rule_airports = rules.get("airports", {})
rule_codes = list(rule_airports.keys()) if isinstance(rule_airports, dict) else [r.get("icao") or r.get("code") for r in rule_airports]
add(C, "data", "connection_rules.json airport not in airports.tsv", [c for c in rule_codes if c and c not in airport_set and c not in {a["iata"] for a in airports}])
seed_ap = list(csv.DictReader(open(os.path.join(SB, "seed/airports.csv"))))
seed_ap_codes = {(r.get("icao_code") or r.get("gps_code") or r.get("ident")) for r in seed_ap}
counts["airports_supabase_seed_csv"] = len(seed_ap)
by_ident = {r["ident"]: r for r in seed_ap}
add(C, "visible", "airports.tsv keyed by the OurAirports ident, but the real ICAO code differs (a flight to that ICAO finds no airport; airport_sizes uses the ICAO)",
    [f"{c} -> {by_ident[c]['icao_code']} {by_ident[c]['name']}" for c in icaos if c in by_ident and by_ident[c]["icao_code"] and by_ident[c]["icao_code"] != c])
add(C, "data", "in airports.tsv, not in supabase/seed/airports.csv", [c for c in icaos if c not in seed_ap_codes and c not in {r["ident"] for r in seed_ap}])

# ---------------------------------------------------------------------------------------------------------
# Countries and flags
C = "countries"
iso = [c["iso2"] for c in countries]
add(C, "data", "duplicate iso2", [k for k, n in Counter(iso).items() if n > 1])
add(C, "data", "empty name", [c["iso2"] for c in countries if not c["name"].strip()])
regions = set(re.findall(r'"(\w+)"', ts_src.split("export const REGIONS")[1].split("]")[0]))
add(C, "data", "region not in build_reference_seed.ts REGIONS", [f"{c['iso2']}={c['region']}" for c in countries if c["region"] not in regions])
add(C, "visible", "country with no flag imageset (CountryFlag would ask for a missing asset)", [c for c in iso if c.lower() not in flag_sets])
add(C, "data", "flag imageset with no country in countries.json (unused; xx is the neutral disc)", [f for f in flag_sets if f.upper() not in country_set and f != "xx"])
empty_flags = []
for f in flag_sets:
    d = os.path.join(RES, "Flags.xcassets", f"flag-{f}.imageset")
    meta = json.load(open(os.path.join(d, "Contents.json")))
    files = [i.get("filename") for i in meta.get("images", []) if i.get("filename")]
    if not files or any(not os.path.exists(os.path.join(d, x)) for x in files):
        empty_flags.append(f)
add(C, "visible", "flag imageset with a missing image file", empty_flags)
seed_cr = {r["iso2"]: r for r in csv.DictReader(open(os.path.join(SB, "seed/country_regions.csv")))}
add(C, "data", "in countries.json, not in supabase/seed/country_regions.csv", [c for c in iso if c not in seed_cr])
add(C, "data", "in country_regions.csv, not in countries.json", [c for c in seed_cr if c not in country_set])
add(C, "data", "name or region differs between countries.json and country_regions.csv",
    [f"{c['iso2']}: {c['name']}/{c['region']} vs {seed_cr[c['iso2']]['name']}/{seed_cr[c['iso2']]['region']}"
     for c in countries if c["iso2"] in seed_cr and (c["name"] != seed_cr[c["iso2"]]["name"] or c["region"] != seed_cr[c["iso2"]]["region"])])
add(C, "data", "destinations.json country not in countries.json", [d["iso2"] for d in destinations if d["iso2"] not in country_set])
used = {a["country"] for a in airports if a["country"]}
dest = {d["iso2"] for d in destinations}
add(C, "low", "country with airports but no destinations.json facts (plugs, currency card empty)", [c for c in used if c in country_set and c not in dest])
counts["destinations"] = len(destinations)
add(C, "low", "country with airports but no airport_sizes entry for any of them", [])

# ---------------------------------------------------------------------------------------------------------
# Blank and placeholder art (pixel checks)
try:
    import numpy as np
    from PIL import Image

    def stats(path):
        im = Image.open(path).convert("RGBA")
        a = np.asarray(im)
        alpha = a[..., 3]
        opaque = alpha > 10
        cov = float(opaque.mean())
        if opaque.sum() == 0:
            return cov, 0.0, 0.0, im.size
        rgb = a[..., :3][opaque].astype(float)
        sat = float((rgb.max(1) - rgb.min(1)).mean())
        std = float(rgb.std())
        return cov, sat, std, im.size

    blank, grey, tiny = [], [], []
    for p in sorted(side_files):
        cov, sat, std, size = stats(os.path.join(RES, "SideViews", p + ".webp"))
        if cov < 0.05:
            blank.append(f"{p} (coverage {cov:.3f})")
        elif not p.startswith("ZZZ-") and sat < 6:
            grey.append(f"{p} (mean saturation {sat:.1f})")
        if size[0] < 600:
            tiny.append(f"{p} {size[0]}x{size[1]}")
    add("aircraft types", "visible", "side view almost empty (under 5% opaque pixels)", blank)
    add("airlines", "low", "airline side view with almost no colour (white or black livery, or a placeholder: check by eye)", grey)
    add("aircraft types", "low", "side view under 600 px wide", tiny)
    tb, tg = [], []
    for t in sorted(tail_files):
        cov, sat, std, size = stats(os.path.join(RES, "Tails", f"tail-{t}.webp"))
        if cov < 0.05:
            tb.append(f"{t} (coverage {cov:.3f})")
        elif sat < 6:
            tg.append(f"{t} (saturation {sat:.1f})")
    add("airlines", "visible", "tail fin almost empty", tb)
    add("airlines", "low", "tail fin with almost no colour (check it is not a blank)", tg)
    lb, mono = [], []
    for f in logo_dir:
        if f.endswith(".webp"):
            cov, sat, std, size = stats(os.path.join(RES, "Logos", f))
            if cov < 0.01:
                lb.append(f"{f} (coverage {cov:.3f})")
            elif std < 1:
                mono.append(f)
    add("airlines", "visible", "logo almost empty", lb)
    add("airlines", "low", "single-colour logo (check legibility on the dark theme)", mono)
    ill = []
    for d in os.listdir(os.path.join(RES, "Illustrations.xcassets")):
        if d.endswith(".imageset"):
            meta = json.load(open(os.path.join(RES, "Illustrations.xcassets", d, "Contents.json")))
            files = [i.get("filename") for i in meta.get("images", []) if i.get("filename")]
            if not files or any(not os.path.exists(os.path.join(RES, "Illustrations.xcassets", d, x)) for x in files):
                ill.append(d)
    add("illustrations", "visible", "imageset with a missing image file", ill)
except ImportError:
    print("Pillow or numpy missing: pixel checks skipped", file=sys.stderr)

# SwiftPM flattens resource folders: file names must be unique outside the asset catalogs
names_seen = Counter()
for dirpath, dirnames, files in os.walk(RES):
    if ".xcassets" in dirpath:
        continue
    for f in files:
        names_seen[f] += 1
add("bundle", "data", "resource file name used twice (SwiftPM flattens folders, one copy wins)", [k for k, n in names_seen.items() if n > 1])

# ---------------------------------------------------------------------------------------------------------
order = {"visible": 0, "legal": 1, "data": 2, "low": 3}
findings.sort(key=lambda f: (order[f["severity"]], f["catalog"], -f["count"]))
if "--json" in sys.argv:
    print(json.dumps({"counts": counts, "findings": findings}, indent=1))
else:
    print(json.dumps(counts, indent=1))
    for f in findings:
        print(f"\n[{f['severity']}] {f['catalog']}: {f['check']} ({f['count']})")
        for i in f["items"]:
            print("   ", i)
