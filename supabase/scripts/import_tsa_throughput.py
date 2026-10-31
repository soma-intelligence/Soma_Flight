#!/usr/bin/env python3
"""TSA checkpoint throughput, reduced to a typical week per checkpoint for security-wait.

    python3 -I supabase/scripts/import_tsa_throughput.py [--weeks 8] [--work DIR] [--offline]
        [--out supabase/migrations/<number>_security_throughput_seed.sql]
        [--fixture SFO]...

TSA posts a weekly report of the passengers each checkpoint screened, by airport, checkpoint and hour, in
its FOIA Reading Room (https://www.tsa.gov/foia/readingroom, "TSA Throughput Data"). It is a US government
work, public (https://catalog.data.gov/dataset/tsa-foia-reading-room-weekly-passenger-throughput-data). Each
report is a PDF of about 1,400 pages exported from MicroStrategy: one row per checkpoint and hour, with the
date, the hour and the airport printed once in merged cells (vertically centred over their rows, repeated
on every page). Requires poppler's pdftotext (brew install poppler).

What it does:
    1. Lists the report PDFs on the Reading Room search page and keeps the newest --weeks of them.
    2. Downloads them into <work>/pdf (cached: a rerun downloads nothing new, --offline never touches the
       network). The PDFs are untrusted data: only pdftotext reads them, nothing in them is run.
    3. Extracts every row with pdftotext -bbox (word boxes). Rows are the counts in the last column, with
       the checkpoint words beside them; each merged cell (date, hour, airport) owns the contiguous run
       of rows whose vertical span is centred on it, found by dynamic programming per page. Every page
       is checked: header found, labels centred within 5 pt of their rows, airports alphabetical within
       an hour and hours in order across the file. A report that fails a check stops the run.
    4. Reduces to a typical week: for each checkpoint, weekday (0 Sunday) and local hour, the median of
       the passengers over the weeks the checkpoint appears in (an hour with no row that week counts as
       0). A checkpoint must appear in the newest report and in at least half of the weeks: renamed or
       closed checkpoints drop out.
    5. Keeps the checkpoints a departing passenger can use. Employee, crew and FIS (arriving
       international passengers re-screened) checkpoints, arrival rechecks, private terminals and paid
       suites are left out (EXCLUDE). The terminal comes from the name ("Terminal 4 Main" is 4, "T-3
       North" is 3) or from TERMINALS for names that do not say it; PreCheck is true when the name says
       PreCheck, else unknown.
    6. Writes a SQL migration (--out) that replaces the content of security_checkpoints and
       security_throughput (and clears security_wait_cache), so a later refresh is the same command with
       the next migration number. Hours are packed in one int[] of 168 values per checkpoint (Sunday
       00:00 first) and unpacked on insert; zero hours are not stored (security-wait reads a missing
       hour as 0). Airports are matched to supabase/seed/airports.csv by IATA code, the way
       build_airports_seed.ts assigns it.

Also writes <work>/typical_week.json (every kept checkpoint and its week) and, per --fixture IATA, a test
fixture of real aggregated rows to supabase/functions/_shared/fixtures/security_throughput_<icao>.json.
The work folder (default supabase/.tsa-cache) is gitignored: raw PDFs are never committed.
"""
import argparse
import csv
import datetime
import html
import json
import re
import statistics
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
READING_ROOM = "https://www.tsa.gov/foia/readingroom?search_api_fulltext=throughput&page={page}"
SITE = "https://www.tsa.gov"
USER_AGENT = "SomaFlight-TSA-throughput-importer/1.0 (security wait estimates; one request per second)"
MONTHS = ["january", "february", "march", "april", "may", "june", "july", "august", "september",
          "october", "november", "december"]

# Checkpoints a departing passenger does not use.
EXCLUDE = re.compile(r"(?i)employee|\bcrew\b|\bFIS\b|FIS$|arrival|private terminal|^suites$|\(ESC\)")

# Terminals of checkpoints whose name does not say it, by IATA code and exact checkpoint name, in the
# airport's own terms (the way flight data names the terminal: "1", "B", "International").
TERMINALS = {
    "SFO": {
        "Security Checkpoint A": "International",
        "Security Checkpoint G": "International",
        "Security Checkpoint B": "1",
        "Security Checkpoint T1 B Mezzanine": "1",
        "Security Checkpoint D": "2",
        "Security Checkpoint F-1": "3",
    },
    "LAX": {
        "TBIT Main Checkpoint": "B",
        "TBIT MSC - Passenger": "B",
    },
}


# ---------------------------------------------------------------------------------------------- network

class Net:
    """Polite cached fetches: at most one request per second, every answer kept under the work folder."""

    def __init__(self, work: Path, offline: bool):
        self.work, self.offline, self.last = work, offline, 0.0

    def get(self, url: str) -> bytes:
        if self.offline:
            raise RuntimeError(f"offline: {url}")
        wait = 1.0 - (time.time() - self.last)
        if wait > 0:
            time.sleep(wait)
        self.last = time.time()
        req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
        with urllib.request.urlopen(req, timeout=120) as r:
            return r.read()


def report_end(name: str):
    """The last date in a report's file name ("...-october-24-2026.pdf"), or None."""
    found = re.findall(r"(" + "|".join(MONTHS) + r")-(\d{1,2})-(\d{4})", name)
    if not found:
        return None
    m, d, y = found[-1]
    return datetime.date(int(y), MONTHS.index(m) + 1, int(d))


def list_reports(net: Net, weeks: int, work: Path):
    """The newest `weeks` report URLs, newest first. Offline: the PDFs already in the cache."""
    if net.offline:
        names = sorted((p.name for p in (work / "pdf").glob("*.pdf")), key=lambda n: report_end(n) or
                       datetime.date.min, reverse=True)
        return [f"{SITE}/sites/default/files/foia-readingroom/{n}" for n in names[:weeks]]
    found = {}
    for page in range(0, 6):
        text = net.get(READING_ROOM.format(page=page)).decode("utf-8", "replace")
        for href in re.findall(r'href="(/sites/default/files/foia-readingroom/[^"]*throughput[^"]*\.pdf)"', text):
            end = report_end(href)
            if end:
                found[href] = end
        if len(found) >= weeks:
            break
    newest = sorted(found, key=found.get, reverse=True)[:weeks]
    return [SITE + h for h in newest]


def fetch_pdf(net: Net, url: str, work: Path) -> Path:
    path = work / "pdf" / url.rsplit("/", 1)[1]
    if not path.exists():
        print(f"downloading {path.name}", file=sys.stderr)
        data = net.get(url)
        if not data.startswith(b"%PDF"):
            raise RuntimeError(f"not a PDF: {url}")
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
    return path


# ------------------------------------------------------------------------------------------- extraction

WORD = re.compile(r'<word xMin="([\d.]+)" yMin="([\d.]+)" xMax="([\d.]+)" yMax="([\d.]+)">(.*?)</word>')
PAGE = re.compile(r'<page width="([\d.]+)" height="([\d.]+)">(.*?)</page>', re.S)
COUNT = re.compile(r"[\d,]+")
HEADERS = ("Date", "Hour", "Airport", "State", "Checkpoint", "Total")


def partition(rows, labels):
    """Splits rows (top, bottom), in page order, into one contiguous non-empty run per label (a y centre,
    in order) so that each run's span is centred on its label: least squares by dynamic programming.
    Returns the runs as (start, end) and the worst distance in points, or None when it cannot."""
    n, k = len(rows), len(labels)
    if k == 0 or n < k:
        return None
    inf = float("inf")
    best = [[inf] * (n + 1) for _ in range(k + 1)]
    back = [[0] * (n + 1) for _ in range(k + 1)]
    best[0][0] = 0.0
    for j in range(1, k + 1):
        for e in range(j, n + 1):
            for s in range(j - 1, e):
                if best[j - 1][s] == inf:
                    continue
                err = best[j - 1][s] + ((rows[s][0] + rows[e - 1][1]) / 2 - labels[j - 1]) ** 2
                if err < best[j][e]:
                    best[j][e], back[j][e] = err, s
    runs, e = [], n
    for j in range(k, 0, -1):
        s = back[j][e]
        runs.append((s, e))
        e = s
    runs.reverse()
    worst = max(abs((rows[s][0] + rows[e - 1][1]) / 2 - labels[i]) for i, (s, e) in enumerate(runs))
    return runs, worst


def label_of(runs, values, i):
    for r, (s, e) in enumerate(runs):
        if s <= i < e:
            return values[r]
    raise ValueError(i)


def parse_page(pno: int, height: float, body: str):
    """The rows of one page as (date, hour, iata, checkpoint, passengers)."""
    words = [(float(a), float(b), float(c), float(d), html.unescape(t)) for a, b, c, d, t in WORD.findall(body)]
    head = {}
    for w in words:
        if 55 < w[1] < 90 and w[4] in HEADERS and w[4] not in head:
            head[w[4]] = w[0]
    if len(head) < len(HEADERS):
        raise ValueError(f"page {pno}: header not found ({sorted(head)})")
    top = max(w[3] for w in words if 55 < w[1] < 90) + 2
    data = [w for w in words if w[1] > top and w[3] < height - 40]  # the page number sits below
    x_hour = (head["Date"] + head["Hour"]) / 2
    x_code = (head["Hour"] + head["Airport"]) / 2
    x_name = head["Airport"] + 12
    x_state = head["State"] - 8
    x_check = head["Checkpoint"] - 10
    x_count = head["Total"] - 20

    def yc(w):
        return (w[1] + w[3]) / 2

    is_count = lambda w: w[0] >= x_count and COUNT.fullmatch(w[4])
    counts = sorted((w for w in data if is_count(w)), key=yc)
    rows = [[c] for c in counts]
    for w in data:
        if w[0] < x_check or is_count(w):
            continue
        i = min(range(len(counts)), key=lambda i: abs(yc(counts[i]) - yc(w)), default=None)
        if i is None or abs(yc(counts[i]) - yc(w)) > 14:
            raise ValueError(f"page {pno}: checkpoint word {w[4]!r} has no count")
        rows[i].append(w)
    spans = [(min(w[1] for w in r), max(w[3] for w in r)) for r in rows]
    names = [" ".join(w[4] for w in sorted(r[1:], key=lambda w: (round(yc(w)), w[0]))) for r in rows]

    dates = sorted((w for w in data if w[0] < x_hour and re.fullmatch(r"\d{1,2}/\d{1,2}/\d{4}", w[4])), key=yc)
    hours = sorted((w for w in data if x_hour <= w[0] < x_code and re.fullmatch(r"\d\d:00", w[4])), key=yc)
    states = sorted((w for w in data if x_state <= w[0] < x_check and re.fullmatch(r"[A-Z]{2}", w[4])), key=yc)
    codes = [w for w in data if x_code <= w[0] < x_name]
    # A code can wrap ("MD" over "W"): its pieces sit within 8 pt of the airport's one-line state.
    iatas = ["".join(w[4] for w in sorted((c for c in codes if abs(yc(c) - yc(s)) < 8), key=yc)) for s in states]
    if sum(1 for c in codes if any(abs(yc(c) - yc(s)) < 8 for s in states)) != len(codes):
        raise ValueError(f"page {pno}: an airport code is not beside its state")
    if not rows:
        return []
    runs = {}
    for kind, labels in (("date", dates), ("hour", hours), ("airport", states)):
        got = partition(spans, [yc(w) for w in labels])
        if got is None:
            raise ValueError(f"page {pno}: {len(labels)} {kind} labels for {len(rows)} rows")
        if got[1] > 5:
            raise ValueError(f"page {pno}: {kind} labels off their rows by {got[1]:.1f} pt")
        runs[kind] = got[0]
    out = []
    for i, r in enumerate(rows):
        out.append((label_of(runs["date"], [iso_date(w[4]) for w in dates], i),
                    label_of(runs["hour"], [w[4] for w in hours], i),
                    label_of(runs["airport"], iatas, i), names[i], int(r[0][4].replace(",", ""))))
    return out


def extract(pdf: Path, work: Path):
    """Every row of a report, checked for order, with the text layer cached beside the PDF."""
    box = work / "text" / (pdf.stem + ".html")
    if not box.exists():
        box.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(["pdftotext", "-bbox", str(pdf), str(box)], check=True)
    rows = []
    for pno, (_, h, body) in enumerate(PAGE.findall(box.read_text(encoding="utf-8")), 1):
        rows.extend(parse_page(pno, float(h), body))
    if not rows:
        raise ValueError(f"{pdf.name}: no rows")
    prev = None
    for date, hour, iata, _, _ in rows:
        if not re.fullmatch(r"[A-Z0-9]{3}", iata):
            raise ValueError(f"{pdf.name}: bad airport code {iata!r}")
        key = (date, hour, iata)
        if prev and (key[:2] < prev[:2] or (key[:2] == prev[:2] and iata < prev[2])):
            raise ValueError(f"{pdf.name}: rows out of order at {date} {hour} {iata}")
        prev = key
    return rows


# ------------------------------------------------------------------------------------------- reduction

def slug(name: str) -> str:
    s = re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")
    return s[:40].rstrip("-") or "checkpoint"


def terminal_of(iata: str, name: str):
    fixed = TERMINALS.get(iata, {}).get(name)
    if fixed:
        return fixed
    m = re.search(r"(?i)\b(?:terminal|term\.?)\s*([A-Z]?\d+(?:\.\d)?[A-Z]?|[A-Z])\b", name)
    if m:
        return m.group(1).upper()
    m = re.search(r"\bT-?(\d{1,2})(?=\b|[A-Z]?-)", name)
    return m.group(1) if m else None


def iso_date(us: str) -> str:
    """"10/4/2026" as "2026-10-04"."""
    m, d, y = (int(x) for x in us.split("/"))
    return datetime.date(y, m, d).isoformat()


def weekday(date: str) -> int:
    return (datetime.date.fromisoformat(date).weekday() + 1) % 7  # 0 Sunday, as extract(dow)


def reduce(weeks):
    """weeks: per report, newest first, its rows. -> {(iata, name): [168 medians]}."""
    seen = []  # per week: {(iata, name): {slot: passengers}}
    for rows in weeks:
        cps = {}
        for date, hour, iata, name, pax in rows:
            slot = weekday(date) * 24 + int(hour[:2])
            cp = cps.setdefault((iata, name), {})
            cp[slot] = cp.get(slot, 0) + pax
        seen.append(cps)
    out = {}
    for key in seen[0]:
        present = [w[key] for w in seen if key in w]
        if len(present) * 2 < len(seen):
            continue
        out[key] = [round(statistics.median(w.get(s, 0) for w in present)) for s in range(168)]
    return out


def icao_by_iata():
    """IATA to ICAO as build_airports_seed.ts assigns it: the first scheduled airport carrying the code."""
    out = {}
    with open(ROOT / "supabase/seed/airports.csv", newline="", encoding="utf-8") as f:
        for r in csv.DictReader(f):
            icao, iata = r["ident"], r["iata_code"]
            if r["scheduled_service"] == "yes" and re.fullmatch(r"[A-Z]{4}", icao) and iata and iata not in out:
                out[iata] = icao
    return out


def sql(s):
    return "null" if s is None else "'" + s.replace("'", "''") + "'"


def write_sql(path: Path, cps, sources):
    lines = [
        f"-- Generated by supabase/scripts/import_tsa_throughput.py on {datetime.date.today().isoformat()}. Do not edit.",
        "-- A typical week per TSA checkpoint: the median passengers screened per weekday and local hour over",
        "-- these weekly reports from TSA's FOIA Reading Room (https://www.tsa.gov/foia/readingroom):",
        *[f"--   {s}" for s in sources],
        f"-- {len({c['icao'] for c in cps})} airports, {len(cps)} checkpoints. Replaces what an earlier import loaded.",
        "delete from security_wait_cache;",
        "delete from security_checkpoints;",
        "",
        "insert into security_checkpoints (airport_icao, id, name, terminal, precheck) values",
        ",\n".join(f"({sql(c['icao'])}, {sql(c['id'])}, {sql(c['name'])}, {sql(c['terminal'])}, "
                   f"{'true' if c['precheck'] else 'null'})" for c in cps) + ";",
        "",
        "-- Hours packed Sunday 00:00 first, 168 per checkpoint; zero hours are not stored.",
        "insert into security_throughput (airport_icao, checkpoint_id, weekday, hour, passengers)",
        "select v.airport_icao, v.checkpoint_id, (h.slot - 1) / 24, (h.slot - 1) % 24, h.passengers",
        "from (values",
        ",\n".join(f"({sql(c['icao'])}, {sql(c['id'])}, '{{{','.join(map(str, c['week']))}}}'::int[])" for c in cps),
        ") as v (airport_icao, checkpoint_id, week)",
        "cross join lateral unnest(v.week) with ordinality as h (passengers, slot)",
        "where h.passengers > 0;",
        "",
    ]
    path.write_text("\n".join(lines), encoding="utf-8")


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--weeks", type=int, default=8)
    ap.add_argument("--work", type=Path, default=ROOT / "supabase/.tsa-cache")
    ap.add_argument("--offline", action="store_true")
    ap.add_argument("--out", type=Path)
    ap.add_argument("--fixture", action="append", default=[], metavar="IATA")
    args = ap.parse_args()
    net = Net(args.work, args.offline)

    urls = list_reports(net, args.weeks, args.work)
    if not urls:
        sys.exit("no throughput report found")
    weeks, sources = [], []
    for url in urls:
        rows = extract(fetch_pdf(net, url, args.work), args.work)
        dates = sorted({r[0] for r in rows})
        print(f"{url.rsplit('/', 1)[1]}: {len(rows)} rows, {dates[0]} to {dates[-1]}, "
              f"{sum(r[4] for r in rows):,} passengers", file=sys.stderr)
        weeks.append(rows)
        sources.append(f"{url} ({dates[0]} to {dates[-1]})")

    typical = reduce(weeks)
    icaos = icao_by_iata()
    cps, skipped, unknown = [], [], set()
    for (iata, name), week in sorted(typical.items()):
        if EXCLUDE.search(name):
            skipped.append(f"{iata} {name}")
            continue
        if iata not in icaos:
            unknown.add(iata)
            continue
        if not any(week):
            continue
        name = name.replace("\u2014", "-")[:80]
        cps.append({"iata": iata, "icao": icaos[iata], "name": name, "terminal": terminal_of(iata, name),
                    "precheck": bool(re.search(r"(?i)pre-?check", name)), "week": week})
    taken = {}
    for c in cps:  # ids unique per airport and stable across runs (same name, same id)
        base = slug(c["name"])
        n = taken.setdefault(c["icao"], {}).get(base, 0) + 1
        taken[c["icao"]][base] = n
        c["id"] = base if n == 1 else f"{base[:37]}-{n}"

    print(f"kept {len(cps)} checkpoints at {len({c['icao'] for c in cps})} airports; left out "
          f"{len(skipped)} (employee, FIS, arrivals, private); airports not in the seed: "
          f"{', '.join(sorted(unknown)) or 'none'}", file=sys.stderr)
    (args.work / "typical_week.json").write_text(json.dumps(
        {"sources": sources, "skipped": skipped, "checkpoints": cps}, indent=1), encoding="utf-8")
    if args.out:
        write_sql(args.out, cps, sources)
    for iata in args.fixture:
        mine = [c for c in cps if c["iata"] == iata]
        if not mine:
            sys.exit(f"no checkpoint for fixture {iata}")
        fixture = {
            "_note": f"Real aggregated rows: TSA throughput at {iata}, typical week (median passengers per "
                     "checkpoint, weekday and local hour, Sunday 00:00 first), written by "
                     "supabase/scripts/import_tsa_throughput.py --fixture. Sources: " + "; ".join(sources),
            "airport": mine[0]["icao"],
            "checkpoints": [{k: c[k] for k in ("id", "name", "terminal", "precheck")} |
                            {"precheck": True if c["precheck"] else None,
                             "week": [c["week"][d * 24:(d + 1) * 24] for d in range(7)]} for c in mine],
        }
        out = ROOT / f"supabase/functions/_shared/fixtures/security_throughput_{mine[0]['icao'].lower()}.json"
        text = json.dumps(fixture, indent=1)
        # One line per day of 24 hours, not one line per number.
        text = re.sub(r"\[\s+([\d,\s]+?)\s+\]", lambda m: "[" + re.sub(r"\s+", " ", m.group(1)) + "]", text)
        out.write_text(text + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
