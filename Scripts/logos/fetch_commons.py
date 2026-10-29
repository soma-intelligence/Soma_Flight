#!/usr/bin/env python3
"""Builds the airline logo library from Wikimedia Commons.

    python3 -I Scripts/logos/fetch_commons.py [--work DIR] [--offline]

For every airline in supabase/seed/airlines.csv: find its Wikidata item by ICAO airline code (P230),
read its logo image (P154), ask the Commons API for the file's URL, type and licence metadata, and
keep only free licences (public domain, CC0, CC BY, CC BY-SA). SVG is preferred over raster.

Downloads land in <work>/download first. They are untrusted data: nothing in them is run, the SHA-1
Commons reports is checked, the bytes must look like the declared type, and rendering goes through an
<img> element (no script, no external loads). Accepted files are copied to assets/logos/commons/:

    <ICAO>.svg            the Commons file as published
    <ICAO>.png            PNG sources only, scaled to 192 px on the longest side (sips)
    png/<ICAO>.png        every logo at 192 px on the longest side, transparent background
    manifest.json         per ICAO: file, sha256, source page, licence, author, attribution, date
    rejected.json         every airline without a usable logo, with the reason

It also writes the attribution list the app shows in Acknowledgements:
Packages/FlightKit/Sources/FlightKit/Resources/Licenses/airline-logos.json

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
    query = f"""SELECT ?icao ?a ?iata ?links ?dissolved ?logo WHERE {{
  VALUES ?icao {{ {values} }}
  ?a wdt:P230 ?icao .
  OPTIONAL {{ ?a wdt:P229 ?iata }}
  OPTIONAL {{ ?a wikibase:sitelinks ?links }}
  OPTIONAL {{ ?a wdt:P576 ?dissolved }}
  OPTIONAL {{ ?a wdt:P154 ?logo }}
}}"""
    url = SPARQL + "?" + urllib.parse.urlencode({"query": query, "format": "json"})
    rows = json.loads(net.get(url))["results"]["bindings"]
    items = {}
    for r in rows:
        icao = r["icao"]["value"]
        qid = r["a"]["value"].rsplit("/", 1)[-1]
        it = items.setdefault(icao, {}).setdefault(
            qid, {"qid": qid, "iata": set(), "links": 0, "dissolved": False, "logos": set()})
        if "iata" in r:
            it["iata"].add(r["iata"]["value"])
        if "links" in r:
            it["links"] = int(r["links"]["value"])
        if "dissolved" in r:
            it["dissolved"] = True
        if "logo" in r:
            name = urllib.parse.unquote(r["logo"]["value"].rsplit("/", 1)[-1])
            it["logos"].add(name.replace("_", " "))
    return items


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


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--work", default=os.path.join(tempfile.gettempdir(), "soma-flight-logos"))
    ap.add_argument("--offline", action="store_true")
    args = ap.parse_args()
    work = Path(args.work)
    download = work / "download"
    download.mkdir(parents=True, exist_ok=True)
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
            continue
        # SVG first, then by name for a stable order.
        logos = sorted(item["logos"], key=lambda n: (not n.lower().endswith(".svg"), n))
        chosen[icao] = (a, item, logos)

    info = commons_info(net, [n for _, _, logos in chosen.values() for n in logos])

    (OUT / "png").mkdir(parents=True, exist_ok=True)
    for old in list(OUT.glob("*.svg")) + list(OUT.glob("*.png")) + list((OUT / "png").glob("*.png")):
        old.unlink()

    manifest = {}
    for icao, (a, item, logos) in sorted(chosen.items()):
        reasons = []
        for name in logos:
            ii = info.get(name)
            if ii is None:
                reasons.append(("not on Commons", f"{name}: not hosted on Commons (local or non-free upload)"))
                continue
            mime = ii.get("mime", "")
            if mime not in ("image/svg+xml", "image/png"):
                reasons.append(("unsupported type", f"{name}: {mime}"))
                continue
            kind, why = classify(ii)
            if not kind:
                reasons.append((why.split(" (")[0], f"{name}: {why}"))
                continue
            data = net.get(ii["url"])
            if hashlib.sha1(data).hexdigest() != ii.get("sha1"):
                reasons.append(("checksum mismatch", f"{name}: SHA-1 differs from Commons"))
                continue
            if not looks_like(data, mime):
                reasons.append(("bad file", f"{name}: bytes are not {mime}"))
                continue
            ext = "svg" if mime == "image/svg+xml" else "png"
            raw = download / f"{icao}.{ext}"
            raw.write_bytes(data)
            dest = OUT / f"{icao}.{ext}"
            small = OUT / "png" / f"{icao}.png"
            if ext == "svg":
                shutil.copyfile(raw, dest)
                render_svg(dest, small, work)
            else:
                scale_png(raw, dest)
                shutil.copyfile(dest, small)
            stored = dest.read_bytes()
            page = ii.get("descriptionurl") or ("https://commons.wikimedia.org/wiki/File:" + urllib.parse.quote(name.replace(" ", "_")))
            author = meta(ii, "Artist")
            credit = meta(ii, "Credit")
            short = meta(ii, "LicenseShortName")
            title = meta(ii, "ObjectName") or name.rsplit(".", 1)[0]
            pw, ph = png_size(small.read_bytes())
            manifest[icao] = {
                "name": a["name"],
                "iata": a["iata"] or None,
                "wikidata": item["qid"],
                "file": dest.name,
                "format": ext,
                "sha256": hashlib.sha256(stored).hexdigest(),
                "bytes": len(stored),
                "png": f"png/{icao}.png",
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
                "credit": credit or None,
                "trademarked": "trademark" in meta(ii, "Restrictions").lower(),
                "attribution": attribution(kind, title, author, short, page),
                "retrieved": today,
            }
            break
        else:
            reason, detail = reasons[0] if reasons else ("not found", "no candidate")
            rejected[icao] = {"name": a["name"], "reason": reason, "detail": "; ".join(d for _, d in reasons),
                              "wikidata": item["qid"]}
            continue

    dump = lambda obj: json.dumps(obj, indent=2, sort_keys=True, ensure_ascii=False) + "\n"
    (OUT / "manifest.json").write_text(dump({
        "source": "Wikimedia Commons via Wikidata P230 (ICAO airline code) and P154 (logo image)",
        "generated_by": "Scripts/logos/fetch_commons.py",
        "retrieved": today,
        "logos": manifest,
    }))
    (OUT / "rejected.json").write_text(dump(rejected))
    APP_ATTRIBUTION.write_text(dump([
        {"icao": k, "name": v["name"], "author": v["author"] or "Unknown author", "license": v["license"],
         "license_url": v["license_url"], "source": v["source_page"], "attribution": v["attribution"]}
        for k, v in sorted(manifest.items())
    ]))

    counts = {}
    for r in rejected.values():
        counts[r["reason"]] = counts.get(r["reason"], 0) + 1
    print(f"accepted {len(manifest)} of {len(airlines)}")
    for k, v in sorted(counts.items()):
        print(f"  {k}: {v}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
