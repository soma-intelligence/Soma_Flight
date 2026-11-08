"""Builds Packages/FlightKit/Sources/FlightKit/Resources/Reference/landmarks.json: famous places a passenger
can see from a window (peaks, volcanoes, big cities, lakes, glaciers, islands, deserts, canyons, waterfalls,
river deltas, fjords), with a visibility radius for each.

Source: Wikidata (CC0), one SPARQL request at build time. The app never calls Wikidata: it reads the JSON.

    python3 Scripts/world/landmarks.py fetch raw.json    # the one request, saved as is
    python3 Scripts/world/landmarks.py build raw.json out.json

The request lists items that are directly an instance of one of the classes below (no subclass walk, so the
query stays fast), on Earth, with coordinates and at least MIN_SITELINKS Wikipedia/Wikimedia sitelinks. The
build keeps the best known of each kind by sitelinks (a fair proxy for fame), drops near duplicates and gives
each a radius: how far from the place a passenger at cruise height still picks it out. The radii are our own
rule of thumb (a high peak stands out from far, a city reads from about 40 km), not Wikidata facts.
"""
import json, math, re, sys, urllib.parse, urllib.request

ENDPOINT = "https://query.wikidata.org/sparql"
USER_AGENT = "SomaFlight-landmarks/1.0 (https://somalabs.me; build script, run once)"
MIN_SITELINKS = 25

# Wikidata class -> our kind.
CLASSES = {
    "Q8502": "mountain",
    "Q8072": "volcano", "Q169358": "volcano", "Q212057": "volcano",  # volcano, stratovolcano, shield volcano
    "Q1637706": "city", "Q174844": "city", "Q200250": "city",  # city with millions, megacity, metropolis
    "Q23397": "lake",
    "Q35666": "glacier",
    "Q23442": "island", "Q42523": "island",                 # island, atoll
    "Q8514": "desert",
    "Q150784": "canyon",
    "Q34038": "waterfall",
    "Q43197": "delta", "Q47053": "delta",                   # river delta, estuary
    "Q45776": "fjord",
}

# How many of each kind to keep, best known first.
QUOTA = {"mountain": 120, "volcano": 45, "city": 120, "lake": 45, "glacier": 20, "island": 45, "desert": 20,
         "canyon": 12, "waterfall": 12, "delta": 15, "fjord": 8}


# Wikidata items kept out: hills famous for something else, small gorges, a river, a range filed as a
# glacier, a metro area doubling its city, places too small to pick out from the air.
EXCLUDE = {"Monte San Giorgio", "Mount Rushmore", "Mount Helicon", "Meron", "Burkhan Khaldun", "Aburaj",
           "Mount Ida", "Ironbridge Gorge", "Pankisi Gorge", "Samariá Gorge National Park", "Valley of Geysers",
           "Darial Gorge", "Matka Canyon", "Vikos Gorge", "Eldgjá", "East River", "Sierra Nevada de Santa Marta",
           "New York metropolitan area", "Gongzhuling", "Taguig", "Montserrat"}

# Shorter names as a passenger says them.
RENAME = {"Metropolis of Lyon": "Lyon", "Greater Buenos Aires": "Buenos Aires", "Cotopaxi volcano": "Cotopaxi",
          "Tungurahua volcano": "Tungurahua", "Bali Island": "Bali", "Taiwan Island": "Taiwan",
          "Kati Thanda\u2013Lake Eyre": "Lake Eyre", "Milford Sound / Piopiotahi": "Milford Sound",
          "Mayon Volcano": "Mayon", "Arenal Volcano": "Arenal", "Iguaçu Falls": "Iguazu Falls",
          "Yushan Main Peak": "Yushan", "Baekdu Mountain": "Mount Paektu", "Snowdon": "Snowdon"}

# Radius overrides, km.
RADIUS = {"Grand Canyon": 60, "Sahara": 250, "Mount Fuji": 80}

# Famous places Wikidata files under classes the query leaves out (a city "in the United States", a massif):
# entered by hand from their well known coordinates, rounded to about 1 km, which is far finer than the radii.
EXTRA = [
    ("Los Angeles", "city", 34.05, -118.24, 50), ("Chicago", "city", 41.88, -87.63, 50),
    ("San Francisco", "city", 37.77, -122.42, 40), ("Singapore", "city", 1.29, 103.85, 40),
    ("Toronto", "city", 43.65, -79.38, 40), ("Madrid", "city", 40.42, -3.70, 40),
    ("Barcelona", "city", 41.39, 2.17, 40), ("Las Vegas", "city", 36.17, -115.14, 40),
    ("Houston", "city", 29.76, -95.37, 40), ("Miami", "city", 25.76, -80.19, 40),
    ("Washington", "city", 38.90, -77.04, 40), ("Boston", "city", 42.36, -71.06, 40),
    ("Seattle", "city", 47.61, -122.33, 40), ("Vancouver", "city", 49.28, -123.12, 40),
    ("Johannesburg", "city", -26.20, 28.05, 40), ("Cape Town", "city", -33.92, 18.42, 40),
    ("Athens", "city", 37.98, 23.73, 40), ("Amsterdam", "city", 52.37, 4.90, 40),
    ("Venice", "city", 45.44, 12.32, 30), ("Kuala Lumpur", "city", 3.14, 101.69, 40),
    ("Doha", "city", 25.29, 51.53, 40), ("Tel Aviv", "city", 32.08, 34.78, 40),
    ("Lisbon", "city", 38.72, -9.14, 40), ("Prague", "city", 50.08, 14.44, 40),
    ("Budapest", "city", 47.50, 19.04, 40), ("Copenhagen", "city", 55.68, 12.57, 40),
    ("Stockholm", "city", 59.33, 18.07, 40), ("Dublin", "city", 53.35, -6.26, 40),
    ("Brussels", "city", 50.85, 4.35, 40), ("Honolulu", "city", 21.31, -157.86, 40),
    ("Denver", "city", 39.74, -104.99, 40), ("Phoenix", "city", 33.45, -112.07, 40),
    ("Atlanta", "city", 33.75, -84.39, 40), ("Dallas", "city", 32.78, -96.80, 40),
    ("Bogotá", "city", 4.71, -74.07, 40), ("Santiago", "city", -33.45, -70.67, 40),
    ("Nairobi", "city", -1.29, 36.82, 40), ("Addis Ababa", "city", 9.03, 38.74, 40),
    ("Riyadh", "city", 24.71, 46.68, 40), ("Taipei", "city", 25.03, 121.57, 40),
    ("Hanoi", "city", 21.03, 105.85, 40),
    ("Mount Kilimanjaro", "volcano", -3.067, 37.356, 80), ("Aconcagua", "mountain", -32.653, -70.011, 80),
    ("Denali", "mountain", 63.069, -151.007, 80), ("Mount St. Helens", "volcano", 46.191, -122.194, 60),
    ("Mount Hood", "volcano", 45.374, -121.696, 60), ("Mount Shasta", "volcano", 41.409, -122.195, 60),
    ("Mount Baker", "volcano", 48.777, -121.813, 60), ("Jungfrau", "mountain", 46.537, 7.962, 60),
    ("Uluru", "mountain", -25.345, 131.036, 40), ("Mount Taranaki", "volcano", -39.296, 174.064, 60),
    ("Grand Teton", "mountain", 43.741, -110.802, 60), ("Pikes Peak", "mountain", 38.841, -105.044, 60),
    ("Mont-Saint-Michel", "island", 48.636, -1.511, 30), ("Lake Geneva", "lake", 46.45, 6.53, 45),
    ("Lake Como", "lake", 46.0, 9.26, 35),
]

def query():
    values = " ".join(f"wd:{q}" for q in CLASSES)
    # Kept light so it fits the endpoint's 60 s limit (a first, heavier version timed out): the sitelink
    # filter runs right after the class, coordinates come as the plain wdt:P625 literal (a globe other than
    # Earth shows in the literal and is dropped by the build), labels through rdfs:label.
    return f"""
SELECT ?item ?label ?class ?coord ?links ?elev ?pop ?area WHERE {{
  VALUES ?class {{ {values} }}
  ?item wdt:P31 ?class .
  ?item wikibase:sitelinks ?links .
  FILTER(?links >= {MIN_SITELINKS})
  ?item wdt:P625 ?coord .
  ?item rdfs:label ?label . FILTER(LANG(?label) = "en")
  OPTIONAL {{ ?item wdt:P2044 ?elev . }}
  OPTIONAL {{ ?item wdt:P1082 ?pop . }}
  OPTIONAL {{ ?item wdt:P2046 ?area . }}
}}"""


def fetch(path):
    url = ENDPOINT + "?" + urllib.parse.urlencode({"query": query(), "format": "json"})
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT, "Accept": "application/sparql-results+json"})
    with urllib.request.urlopen(req, timeout=120) as r:
        data = r.read()
    open(path, "wb").write(data)
    print(f"saved {len(data)} bytes to {path}")


def km(a, b):
    p1, p2 = math.radians(a[0]), math.radians(b[0])
    dp, dl = p2 - p1, math.radians(b[1] - a[1])
    h = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 6371 * 2 * math.atan2(math.sqrt(h), math.sqrt(max(0, 1 - h)))


def radius(kind, elev, pop, area):
    """Visibility radius, km, from the kind and its size."""
    if kind == "mountain":
        return 80 if (elev or 0) >= 4000 else 60 if (elev or 0) >= 2500 else 45
    if kind == "volcano":
        return 80 if (elev or 0) >= 4000 else 60 if (elev or 0) >= 2000 else 45
    if kind == "city":
        return 50 if (pop or 0) >= 8_000_000 else 40
    if kind in ("lake", "island", "desert"):
        # Half the width of a disc of that area, plus what is seen past its edge; clamped.
        extra = 30
        r = math.sqrt(area / math.pi) + extra if area else 40
        return round(min(max(r, 30), 250 if kind == "desert" else 150))
    if kind == "glacier":
        return 50
    if kind == "canyon":
        return 35
    if kind == "waterfall":
        return 25
    if kind == "delta":
        return 60
    if kind == "fjord":
        return 40
    return 40


def build(raw_path, out_path):
    rows = json.load(open(raw_path))["results"]["bindings"]
    items = {}
    for r in rows:
        qid = r["item"]["value"].rsplit("/", 1)[1]
        name = r.get("label", {}).get("value", "")
        coord = r["coord"]["value"]
        m = re.fullmatch(r"Point\(([-0-9.eE]+) ([-0-9.eE]+)\)", coord)
        if not name or name == qid or not m or name in EXCLUDE:
            continue  # no English name, or a point on another globe ("<.../Q405> Point(...)")
        lon, lat = float(m.group(1)), float(m.group(2))
        kind = CLASSES[r["class"]["value"].rsplit("/", 1)[1]]
        f = lambda k: float(r[k]["value"]) if k in r else None
        it = items.setdefault(qid, {"id": qid, "name": name, "kinds": set(), "lat": lat, "lon": lon,
                                    "links": int(r["links"]["value"]), "elev": None, "pop": None, "area": None})
        it["kinds"].add(kind)
        for k in ("elev", "pop", "area"):
            v = f(k)
            if v is not None and (it[k] is None or v > it[k]):
                it[k] = v
    # One kind per item: a volcano is a volcano before it is a mountain.
    order = ["volcano", "mountain", "city", "glacier", "canyon", "waterfall", "delta", "fjord", "lake", "island", "desert"]
    for it in items.values():
        it["kind"] = next(k for k in order if k in it["kinds"])

    kept = []
    for kind, quota in QUOTA.items():
        pool = sorted((i for i in items.values() if i["kind"] == kind), key=lambda i: -i["links"])
        chosen = []
        for i in pool:
            if len(chosen) >= quota:
                break
            if kind in ("mountain", "volcano") and (i["elev"] or 0) < 1000:
                continue  # hills famous for something else
            if kind == "city" and (i["pop"] or 0) < 1_000_000:
                continue
            if kind == "island" and (i["area"] or 0) > 50_000:
                continue  # big islands are land below, named by the region line already
            if kind == "lake" and (i["area"] or 0) < 50:
                continue
            if any(km((i["lat"], i["lon"]), (c["lat"], c["lon"])) < 10 for c in chosen + kept if c["kind"] == kind):
                continue
            if any(c["name"] == i["name"] for c in chosen + kept):
                continue
            chosen.append(i)
        kept += chosen

    for name, kind, lat, lon, r in EXTRA:
        assert not any(i["name"] == name for i in kept), name
        kept.append({"id": None, "name": name, "kind": kind, "lat": lat, "lon": lon, "radius": r})
    for i in kept:
        i["name"] = RENAME.get(i["name"], i["name"])
        if "radius" not in i:
            i["radius"] = RADIUS.get(i["name"], radius(i["kind"], i["elev"], i["pop"], i["area"]))
    kept.sort(key=lambda i: (i["kind"], i["name"]))
    out = {
        "source": "Wikidata (https://www.wikidata.org), CC0 1.0 public domain dedication, one SPARQL query run by "
                  "Scripts/world/landmarks.py on 2026-11-08: items that are directly an instance of a mountain, "
                  "volcano, big city, lake, glacier, island, desert, canyon, waterfall, river delta or fjord class, "
                  f"with at least {MIN_SITELINKS} sitelinks; the best known of each kind by sitelinks. Coordinates "
                  "are Wikidata's (P625). radius_km is our own rule of thumb for how far a passenger at cruise "
                  "height still picks the place out, from its kind, height (P2044), population (P1082) or area (P2046). "
                  "Entries with a null id are not from Wikidata: famous places Wikidata files under classes the "
                  "query leaves out, entered by hand from their well known coordinates (rounded to about 1 km).",
        "license": "CC0-1.0",
        "landmarks": [{"id": i["id"], "name": i["name"], "kind": i["kind"], "lat": round(i["lat"], 4),
                       "lon": round(i["lon"], 4), "radius_km": i["radius"]}
                      for i in kept],
    }
    # One landmark a line, so a diff reads.
    with open(out_path, "w") as fh:
        fh.write("{\n" + f'"source":{json.dumps(out["source"], ensure_ascii=False)},\n'
                 + f'"license":{json.dumps(out["license"])},\n"landmarks":[\n')
        fh.write(",\n".join(json.dumps(l, ensure_ascii=False, separators=(",", ":")) for l in out["landmarks"]))
        fh.write("\n]}\n")
    counts = {}
    for i in kept:
        counts[i["kind"]] = counts.get(i["kind"], 0) + 1
    print(f"{len(kept)} landmarks to {out_path}: {counts}")


if __name__ == "__main__":
    if len(sys.argv) >= 3 and sys.argv[1] == "fetch":
        fetch(sys.argv[2])
    elif len(sys.argv) >= 4 and sys.argv[1] == "build":
        build(sys.argv[2], sys.argv[3])
    else:
        print(__doc__)
        sys.exit(1)
