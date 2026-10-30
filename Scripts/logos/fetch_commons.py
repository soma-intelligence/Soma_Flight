#!/usr/bin/env python3
"""Builds the airline logo library from Wikimedia Commons.

    python3 -I Scripts/logos/fetch_commons.py [--work DIR] [--offline]

For every airline in supabase/seed/airlines.csv: find its Wikidata item by ICAO airline code (P230),
read its logo image (P154), ask the Commons API for the file's URL, type and licence metadata, and
keep only free licences (public domain, CC0, CC BY, CC BY-SA). SVG is preferred over raster.

Symbol pass (Task 8c): wide wordmarks are unreadable at 24 to 34 pt, so the script also looks for the
airline's compact symbol mark, in this order:
    1. Wikidata P8972 (small logo or icon)
    2. Wikidata P2910 (icon)
    3. a P154 logo whose file name says it is the symbol (when the item lists several logos)
    4. a file of the airline's Commons category (P373, and its "... logos" subcategories) whose name
       says symbol, tail logo, icon, emblem, crown...
Wikidata answers (1, 2) are trusted as the airline's mark. A name match (3, 4) is only a candidate: it
ships when SYMBOL_REVIEW below accepts that exact file (checked by eye to be the mark of the airline's
current branding), and every other candidate is recorded with its verdict, never shipped. Same licence
filter, same download checks. Nothing is cropped or edited: a symbol that only exists inside a wordmark
stays a candidate for the owner.

Downloads land in <work>/download first. They are untrusted data: nothing in them is run, the SHA-1
Commons reports is checked, the bytes must look like the declared type, and rendering goes through an
<img> element (no script, no external loads). Accepted files are copied to assets/logos/commons/:

    <ICAO>.svg            the Commons file as published
    <ICAO>.png            PNG sources only, scaled to 192 px on the longest side (sips)
    png/<ICAO>.png        every logo at 192 px on the longest side, transparent background
    symbol/<ICAO>.svg     the airline's symbol mark (or symbol/<ICAO>.png for PNG sources, 192 px)
    symbol/png/<ICAO>.png every symbol at 192 px on the longest side, transparent background
    manifest.json         "logos" (kind wordmark) and "symbols" (kind symbol), per ICAO: file, sha256,
                          source page, licence, author, attribution, date, and for symbols the source
    rejected.json         every airline without a usable logo, with the reason
    symbols-report.json   the symbol search: what was found where, every candidate and its verdict

It also writes the attribution list the app shows in Acknowledgements:
Packages/FlightKit/Sources/FlightKit/Resources/Licenses/airline-logos.json
(one entry per airline for its wordmark, with a nested "symbol" credit when a symbol ships).
At the end it runs crop_symbols.py, which adds the symbols cropped out of these logos (Task 8d,
assets/logos/commons/crops.json) and rewrites that credit list with them.

Polite client: descriptive User-Agent, at most one network request per second, every API answer and
download cached under <work>/cache so a rerun costs nothing (--offline refuses any network call).
"""
import argparse
import csv
import datetime
import hashlib
import html
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.parse
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
AIRLINES = ROOT / "supabase/seed/airlines.csv"
OUT = ROOT / "assets/logos/commons"
APP_ATTRIBUTION = ROOT / "Packages/FlightKit/Sources/FlightKit/Resources/Licenses/airline-logos.json"
USER_AGENT = "SomaFlightLogoLibrary/1.0 (+https://somalabs.me; Soma Labs, airline logo attribution build)"
SPARQL = "https://query.wikidata.org/sparql"
COMMONS_API = "https://commons.wikimedia.org/w/api.php"
PX = 192
MAX_BYTES = 8 * 1024 * 1024
CHROME_GLOB = "chromium_headless_shell-*/chrome-headless-shell-mac-arm64/chrome-headless-shell"

# A file name that may be a symbol mark rather than a wordmark. Only a hint: see SYMBOL_REVIEW.
SYMBOL_NAME = re.compile(
    r"\b(symbol|tail|icon|emblem|roundel|monogram|avatar|signet|insignia|isotype|crown|crane|motif|queue)\b",
    re.I)
NOT_SYMBOL = re.compile(r"wordmark|livery|liveries|destination|stamp|badge|medal|map|route", re.I)

# Verdicts on name-matched candidates (sources 3 and 4), by Commons file name. "accept" ships the file
# as the airline's symbol; anything else is the reason it does not. Looked at 2026-10-29.
SYMBOL_REVIEW = {
    "AA Symbol.svg": "accept",
    "Black AA Symbol.svg": "reject: one-colour variant of AA Symbol.svg",
    "Delta Air Lines 2007 symbol.svg": "accept",
    "Delta Air Lines rotated symbol.svg": "reject: rotated variant, not the mark as used",
    "KLM crown logo.svg": "accept",
    "TAROM Logo tail.svg": "reject: ROT's P154 logo is already the compact tail mark (TAROM Logo tail (blue).svg); this tricolour variant would only add an unverified second version",
    "TAROM Logo tail (blue).svg": "reject: already ROT's P154 logo",
    "Finnair F emblem.svg": "reject: not confirmed as a mark of Finnair's current branding, and as wide as a wordmark (4.2:1)",
    "Queue royal air maroc.png": "reject: user-drawn tail on an opaque white square, not the official artwork",
    "Royal Air Maroc Motif.png": "reject: brand pattern, not the symbol",
    "ZIPAIR Tokyo Monogram.svg": "reject: ZIPAIR, a different airline",
    "ZIPAIR Tokyo Monogram with corporate colour.svg": "reject: ZIPAIR, a different airline",
}


class Net:
    """Cached GET with a one request per second floor."""

    def __init__(self, cache: Path, offline: bool):
        self.cache = cache
        self.offline = offline
        self.last = 0.0
        cache.mkdir(parents=True, exist_ok=True)

    def get(self, url: str) -> bytes:
        key = hashlib.sha256(url.encode()).hexdigest()
        path = self.cache / key
        if path.is_file():
            return path.read_bytes()
        if self.offline:
            raise RuntimeError(f"offline and not cached: {url}")
        wait = 1.0 - (time.monotonic() - self.last)
        if wait > 0:
            time.sleep(wait)
        req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT, "Accept-Encoding": "identity"})
        for attempt in range(3):
            self.last = time.monotonic()
            try:
                with urllib.request.urlopen(req, timeout=60) as res:
                    body = res.read(MAX_BYTES + 1)
                break
            except urllib.error.HTTPError as e:
                if e.code in (429, 503) and attempt < 2:
                    time.sleep(int(e.headers.get("Retry-After") or 5))
                    continue
                raise
        if len(body) > MAX_BYTES:
            raise RuntimeError(f"over {MAX_BYTES} bytes: {url}")
        tmp = path.with_suffix(".part")
        tmp.write_bytes(body)
        tmp.replace(path)
        return body


def read_airlines():
    with AIRLINES.open(newline="") as f:
        return [r for r in csv.DictReader(f)]


def wikidata_items(net: Net, icaos):
    """ICAO -> list of candidate items with iata, sitelinks, dissolved flag and logo file names."""
    values = " ".join(f'"{c}"' for c in icaos)
    query = f"""SELECT ?icao ?a ?iata ?links ?dissolved ?logo ?small ?icon ?cat WHERE {{
  VALUES ?icao {{ {values} }}
  ?a wdt:P230 ?icao .
  OPTIONAL {{ ?a wdt:P229 ?iata }}
  OPTIONAL {{ ?a wikibase:sitelinks ?links }}
  OPTIONAL {{ ?a wdt:P576 ?dissolved }}
  OPTIONAL {{ ?a wdt:P154 ?logo }}
  OPTIONAL {{ ?a wdt:P8972 ?small }}
  OPTIONAL {{ ?a wdt:P2910 ?icon }}
  OPTIONAL {{ ?a wdt:P373 ?cat }}
}}"""
    url = SPARQL + "?" + urllib.parse.urlencode({"query": query, "format": "json"})
    rows = json.loads(net.get(url))["results"]["bindings"]
    items = {}
    for r in rows:
        icao = r["icao"]["value"]
        qid = r["a"]["value"].rsplit("/", 1)[-1]
        it = items.setdefault(icao, {}).setdefault(
            qid, {"qid": qid, "iata": set(), "links": 0, "dissolved": False, "logos": set(),
                  "small": set(), "icons": set(), "category": None})
        if "iata" in r:
            it["iata"].add(r["iata"]["value"])
        if "links" in r:
            it["links"] = int(r["links"]["value"])
        if "dissolved" in r:
            it["dissolved"] = True
        for col, key in (("logo", "logos"), ("small", "small"), ("icon", "icons")):
            if col in r:
                it[key].add(file_name(r[col]["value"]))
        if "cat" in r:
            it["category"] = r["cat"]["value"]
    return items


def file_name(commons_url: str) -> str:
    return urllib.parse.unquote(commons_url.rsplit("/", 1)[-1]).replace("_", " ")


def symbol_named(name: str) -> bool:
    return bool(SYMBOL_NAME.search(name)) and not NOT_SYMBOL.search(name)


def category_files(net: Net, category: str):
    """Image files of a Commons category and of its logo subcategories (one level down)."""
    def members(title):
        url = COMMONS_API + "?" + urllib.parse.urlencode({
            "action": "query", "format": "json", "formatversion": "2", "list": "categorymembers",
            "cmtitle": title, "cmtype": "file|subcat", "cmlimit": "500",
        })
        return [m["title"] for m in json.loads(net.get(url))["query"]["categorymembers"]]

    top = members("Category:" + category)
    files = [t for t in top if t.startswith("File:")]
    for sub in sorted(t for t in top if t.startswith("Category:") and re.search(r"\blogos?\b", t, re.I)):
        files += [t for t in members(sub) if t.startswith("File:")]
    return sorted({t.split(":", 1)[1] for t in files if t.lower().endswith((".svg", ".png"))})


def pick_item(cands, iata):
    """Same rule as the reference seed: not dissolved, matching IATA, then most sitelinks."""
    return sorted(
        cands.values(),
        key=lambda c: (c["dissolved"], not (iata and iata in c["iata"]), -c["links"], c["qid"]),
    )[0]


def commons_info(net: Net, names):
    """File name -> imageinfo dict (or None when Commons has no such file)."""
    out = {}
    names = sorted(set(names))
    for i in range(0, len(names), 50):
        batch = names[i:i + 50]
        url = COMMONS_API + "?" + urllib.parse.urlencode({
            "action": "query", "format": "json", "formatversion": "2", "prop": "imageinfo",
            "iiprop": "url|mime|sha1|size|extmetadata", "titles": "|".join("File:" + n for n in batch),
        })
        data = json.loads(net.get(url))["query"]
        norm = {n["to"]: n["from"] for n in data.get("normalized", [])}
        for page in data.get("pages", []):
            title = norm.get(page["title"], page["title"])
            name = title.split(":", 1)[1]
            ii = (page.get("imageinfo") or [None])[0]
            if page.get("missing") or not ii or page.get("imagerepository") not in ("local", None):
                out[name] = None
            else:
                out[name] = ii
    return out


def plain(s):
    """Commons extmetadata values are HTML fragments; keep the visible text."""
    s = re.sub(r"<[^>]+>", " ", s or "")
    return re.sub(r"\s+", " ", html.unescape(s)).strip()


def meta(ii, key):
    v = (ii.get("extmetadata") or {}).get(key) or {}
    return plain(str(v.get("value", "")))


def classify(ii):
    """(accepted kind or None, reason). Kinds: public-domain, cc0, cc-by, cc-by-sa."""
    short = meta(ii, "LicenseShortName")
    code = meta(ii, "License").lower()
    if meta(ii, "NonFree").lower() == "true":
        return None, f"non-free ({short or code or 'no licence'})"
    s = short.lower()
    if code.startswith("pd") or s.startswith("pd") or s == "public domain":
        return "public-domain", short
    if code.startswith("cc0") or s.startswith("cc0") or s.startswith("cc-zero"):
        return "cc0", short
    m = re.match(r"^cc[- ]by(-sa)?[- ](\d\.\d)", code) or re.match(r"^cc by(-sa)? (\d\.\d)", s)
    if m:
        return ("cc-by-sa" if m.group(1) else "cc-by"), short
    if re.search(r"\b(nc|nd)\b", code + " " + s):
        return None, f"non-free licence ({short or code})"
    if not short and not code:
        return None, "unknown licence (no licence metadata)"
    return None, f"licence not accepted ({short or code})"


def looks_like(data: bytes, mime: str) -> bool:
    if mime == "image/svg+xml":
        head = data[:2048].lstrip(b"\xef\xbb\xbf").lstrip().lower()
        return (head.startswith(b"<?xml") or head.startswith(b"<svg") or head.startswith(b"<!--")
                or head.startswith(b"<!doctype svg")) and b"<svg" in data[:65536].lower()
    if mime == "image/png":
        return data[:8] == b"\x89PNG\r\n\x1a\n"
    return False


def svg_aspect(data: bytes):
    """Width over height from the root element's viewBox or width/height; 1 when unreadable."""
    m = re.search(rb"<svg\b[^>]*>", data[:65536], re.I | re.S)
    if not m:
        return 1.0
    tag = m.group(0).decode("utf-8", "replace")
    vb = re.search(r'viewBox\s*=\s*["\']\s*([-\d.eE+]+)[\s,]+([-\d.eE+]+)[\s,]+([\d.eE+]+)[\s,]+([\d.eE+]+)', tag)
    if vb:
        w, h = float(vb.group(3)), float(vb.group(4))
        if w > 0 and h > 0:
            return w / h
    wm = re.search(r'\swidth\s*=\s*["\']\s*([\d.]+)', tag)
    hm = re.search(r'\sheight\s*=\s*["\']\s*([\d.]+)', tag)
    if wm and hm and float(wm.group(1)) > 0 and float(hm.group(1)) > 0:
        return float(wm.group(1)) / float(hm.group(1))
    return 1.0


def png_size(data: bytes):
    return int.from_bytes(data[16:20], "big"), int.from_bytes(data[20:24], "big")


def fit(aspect: float):
    if aspect >= 1:
        return PX, max(1, round(PX / aspect))
    return max(1, round(PX * aspect)), PX


def chrome() -> str:
    base = Path.home() / "Library/Caches/ms-playwright"
    found = sorted(base.glob(CHROME_GLOB))
    if not found:
        raise RuntimeError("no Playwright headless Chromium in ~/Library/Caches/ms-playwright")
    return str(found[-1])


def render_svg(svg: Path, out: Path, work: Path):
    """192 px on the longest side, transparent, through an <img> so the SVG cannot run anything."""
    w, h = fit(svg_aspect(svg.read_bytes()))
    page = work / f"render-{svg.stem}.html"
    page.write_text(
        "<!doctype html><meta charset=utf-8><style>html,body{margin:0;background:transparent}"
        f"img{{display:block;width:{w}px;height:{h}px;object-fit:contain}}</style>"
        f'<img src="{svg.resolve().as_uri()}">'
    )
    with tempfile.TemporaryDirectory(dir=work) as profile:
        subprocess.run([
            chrome(), "--headless", "--disable-gpu", "--hide-scrollbars", "--disable-javascript",
            "--force-device-scale-factor=1", "--default-background-color=00000000",
            f"--user-data-dir={profile}", f"--window-size={w},{h}", f"--screenshot={out}", page.as_uri(),
        ], check=True, capture_output=True, timeout=60)
    page.unlink()


def scale_png(src: Path, out: Path):
    shutil.copyfile(src, out)
    w, h = png_size(src.read_bytes())
    if max(w, h) > PX:
        subprocess.run(["sips", "-Z", str(PX), str(out)], check=True, capture_output=True, timeout=60)


def attribution(kind, title, author, short, page):
    who = author or "Unknown author"
    if kind == "public-domain":
        return f"{title} by {who}, public domain, via Wikimedia Commons ({page})"
    if kind == "cc0":
        return f"{title} by {who}, CC0, via Wikimedia Commons ({page})"
    return f"{title} by {who}, {short}, via Wikimedia Commons ({page})"


def take(net: Net, work: Path, icao: str, a, item, name: str, ii, folder: Path, prefix: str, today: str):
    """Checks one Commons file and stores it under folder. (entry, None) or (None, (reason, detail))."""
    if ii is None:
        return None, ("not on Commons", f"{name}: not hosted on Commons (local or non-free upload)")
    mime = ii.get("mime", "")
    if mime not in ("image/svg+xml", "image/png"):
        return None, ("unsupported type", f"{name}: {mime}")
    kind, why = classify(ii)
    if not kind:
        return None, (why.split(" (")[0], f"{name}: {why}")
    data = net.get(ii["url"])
    if hashlib.sha1(data).hexdigest() != ii.get("sha1"):
        return None, ("checksum mismatch", f"{name}: SHA-1 differs from Commons")
    if not looks_like(data, mime):
        return None, ("bad file", f"{name}: bytes are not {mime}")
    ext = "svg" if mime == "image/svg+xml" else "png"
    download = work / "download" / (prefix.strip("/") or "wordmark")
    download.mkdir(parents=True, exist_ok=True)
    raw = download / f"{icao}.{ext}"
    raw.write_bytes(data)
    dest = folder / f"{icao}.{ext}"
    small = folder / "png" / f"{icao}.png"
    if ext == "svg":
        shutil.copyfile(raw, dest)
        render_svg(dest, small, work)
    else:
        scale_png(raw, dest)
        shutil.copyfile(dest, small)
    stored = dest.read_bytes()
    page = ii.get("descriptionurl") or ("https://commons.wikimedia.org/wiki/File:" + urllib.parse.quote(name.replace(" ", "_")))
    author = meta(ii, "Artist")
    short = meta(ii, "LicenseShortName")
    title = meta(ii, "ObjectName") or name.rsplit(".", 1)[0]
    pw, ph = png_size(small.read_bytes())
    return {
        "name": a["name"],
        "iata": a["iata"] or None,
        "wikidata": item["qid"],
        "file": prefix + dest.name,
        "format": ext,
        "sha256": hashlib.sha256(stored).hexdigest(),
        "bytes": len(stored),
        "png": f"{prefix}png/{icao}.png",
        "png_sha256": hashlib.sha256(small.read_bytes()).hexdigest(),
        "png_size": [pw, ph],
        "source_file": name,
        "source_page": page,
        "source_sha1": ii["sha1"],
        "resized_from_source": ext == "png" and stored != data,
        "license_kind": kind,
        "license": short,
        "license_url": meta(ii, "LicenseUrl") or None,
        "attribution_required": meta(ii, "AttributionRequired").lower() == "true",
        "author": author or None,
        "credit": meta(ii, "Credit") or None,
        "trademarked": "trademark" in meta(ii, "Restrictions").lower(),
        "attribution": attribution(kind, title, author, short, page),
        "retrieved": today,
    }, None


def symbol_candidates(net: Net, item, wordmark_file):
    """Ordered (source, file name, reviewed) candidates for the airline's symbol, and the name-matched
    files seen in its category (for the report)."""
    out = []
    for source, names in (("wikidata P8972", item["small"]), ("wikidata P2910", item["icons"])):
        for n in sorted(names, key=lambda n: (not n.lower().endswith(".svg"), n)):
            out.append((source, n, False))
    if len(item["logos"]) > 1:
        for n in sorted(item["logos"], key=lambda n: (not n.lower().endswith(".svg"), n)):
            if n != wordmark_file and symbol_named(n):
                out.append(("wikidata P154 (symbol-named)", n, True))
    seen = []
    if item["category"]:
        seen = [n for n in category_files(net, item["category"]) if symbol_named(n)]
        for n in sorted(seen, key=lambda n: (not n.lower().endswith(".svg"), n)):
            if n != wordmark_file:
                out.append((f"commons category ({item['category']})", n, True))
    return out, seen


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--work", default=os.path.join(tempfile.gettempdir(), "soma-flight-logos"))
    ap.add_argument("--offline", action="store_true")
    args = ap.parse_args()
    work = Path(args.work)
    (work / "download").mkdir(parents=True, exist_ok=True)
    net = Net(work / "cache", args.offline)
    today = datetime.date.today().isoformat()

    airlines = read_airlines()
    items = wikidata_items(net, [a["icao"] for a in airlines])

    chosen = {}
    rejected = {}
    for a in airlines:
        icao = a["icao"]
        if icao not in items:
            rejected[icao] = {"name": a["name"], "reason": "not found", "detail": "no Wikidata item with this ICAO code (P230)"}
            continue
        item = pick_item(items[icao], a["iata"])
        if not item["logos"]:
            rejected[icao] = {"name": a["name"], "reason": "not found", "detail": f"{item['qid']} has no logo image (P154)",
                              "wikidata": item["qid"]}
            chosen[icao] = (a, item, [])
            continue
        # The wordmark: SVG first, a file named as a symbol last (when the item lists several logos),
        # then by name for a stable order.
        several = len(item["logos"]) > 1
        logos = sorted(item["logos"], key=lambda n: (several and symbol_named(n), not n.lower().endswith(".svg"), n))
        chosen[icao] = (a, item, logos)

    symbol_dir = OUT / "symbol"
    for folder in (OUT, symbol_dir):
        (folder / "png").mkdir(parents=True, exist_ok=True)
        for old in list(folder.glob("*.svg")) + list(folder.glob("*.png")) + list((folder / "png").glob("*.png")):
            old.unlink()

    # Wordmarks (kind "wordmark"): the Task 8b library.
    info = commons_info(net, [n for _, _, logos in chosen.values() for n in logos])
    manifest = {}
    for icao, (a, item, logos) in sorted(chosen.items()):
        if not logos:
            continue
        reasons = []
        for name in logos:
            entry, why = take(net, work, icao, a, item, name, info.get(name), OUT, "", today)
            if entry:
                manifest[icao] = {"kind": "wordmark", **entry}
                break
            reasons.append(why)
        else:
            reason, detail = reasons[0] if reasons else ("not found", "no candidate")
            rejected[icao] = {"name": a["name"], "reason": reason, "detail": "; ".join(d for _, d in reasons),
                              "wikidata": item["qid"]}

    # Symbols (kind "symbol").
    plans = {}
    for icao, (a, item, logos) in sorted(chosen.items()):
        wordmark_file = manifest[icao]["source_file"] if icao in manifest else None
        plans[icao] = symbol_candidates(net, item, wordmark_file)
    sinfo = commons_info(net, [n for cands, _ in plans.values() for _, n, _ in cands])
    symbols = {}
    report = {}
    for icao, (cands, seen) in sorted(plans.items()):
        a, item, _ = chosen[icao]
        tried = []
        for source, name, reviewed in cands:
            if reviewed:
                verdict = SYMBOL_REVIEW.get(name, "unreviewed: not shipped until checked and added to SYMBOL_REVIEW")
                if verdict != "accept":
                    tried.append({"file": name, "source": source, "verdict": verdict})
                    continue
            entry, why = take(net, work, icao, a, item, name, sinfo.get(name), symbol_dir, "symbol/", today)
            if entry:
                symbols[icao] = {"kind": "symbol", "symbol_source": source, **entry}
                tried.append({"file": name, "source": source, "verdict": "shipped"})
                break
            tried.append({"file": name, "source": source, "verdict": f"refused: {why[1]}"})
        if tried or seen:
            report[icao] = {"name": a["name"], "candidates": tried, "symbol_named_in_category": seen}

    dump = lambda obj: json.dumps(obj, indent=2, sort_keys=True, ensure_ascii=False) + "\n"
    (OUT / "manifest.json").write_text(dump({
        "source": "Wikimedia Commons via Wikidata P230 (ICAO airline code); wordmarks from P154 (logo image), "
                  "symbols from P8972 (small logo or icon), P2910 (icon) or reviewed symbol files",
        "generated_by": "Scripts/logos/fetch_commons.py",
        "retrieved": today,
        "logos": manifest,
        "symbols": symbols,
    }))
    (OUT / "rejected.json").write_text(dump(rejected))
    (OUT / "symbols-report.json").write_text(dump(report))

    def credit(v):
        c = {"author": v["author"] or "Unknown author", "license": v["license"],
             "license_url": v["license_url"], "source": v["source_page"], "attribution": v["attribution"]}
        # A modified file (a share-alike one must say so) carries what was changed.
        if v.get("changes"):
            c["changes"] = v["changes"]
        return c

    credits = []
    for k, v in sorted(manifest.items()):
        c = {"icao": k, "name": v["name"], "kind": "wordmark", **credit(v)}
        if k in symbols:
            s = symbols[k]
            c["symbol"] = {"kind": "symbol", **credit(s)}
            c["attribution"] = f"Wordmark: {v['attribution']}; symbol: {s['attribution']}"
        credits.append(c)
    # A symbol without a wordmark still gets its own credit line.
    for k, s in sorted(symbols.items()):
        if k not in manifest:
            credits.append({"icao": k, "name": s["name"], "kind": "symbol", **credit(s)})
    credits.sort(key=lambda c: c["icao"])
    APP_ATTRIBUTION.write_text(dump(credits))

    # Task 8d: the symbols cropped out of these logos (crops.json) are rebuilt on top, and the credit list
    # rewritten with them. A crop whose source changed is refused there and reported here.
    crop = subprocess.run([sys.executable, "-I", str(Path(__file__).with_name("crop_symbols.py"))],
                          capture_output=True, text=True, timeout=600)
    print(crop.stdout, end="")
    if crop.returncode:
        print(f"crop_symbols.py: some crops refused (exit {crop.returncode}){': ' + crop.stderr if crop.stderr else ''}")

    counts = {}
    for r in rejected.values():
        counts[r["reason"]] = counts.get(r["reason"], 0) + 1
    print(f"wordmarks: accepted {len(manifest)} of {len(airlines)}")
    for k, v in sorted(counts.items()):
        print(f"  {k}: {v}")
    by_source = {}
    for s in symbols.values():
        src = s["symbol_source"].split(" (")[0]
        by_source[src] = by_source.get(src, 0) + 1
    print(f"symbols: {len(symbols)}")
    for k, v in sorted(by_source.items()):
        print(f"  {k}: {v}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
