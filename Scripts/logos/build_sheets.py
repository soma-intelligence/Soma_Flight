#!/usr/bin/env python3
"""Review sheets for the bundled brand art.

    python3 -I Scripts/logos/build_sheets.py

docs/logos/library.png  every accepted Commons logo (assets/logos/commons/png) on a dark and a light
                        tile with its ICAO code, then the airlines with no usable logo and why.
docs/logos/flags.png    every flag in Flags.xcassets, labelled with its ISO 3166-1 alpha-2 code.

Rendered with Playwright's headless Chromium. Images are shown through <img> only.
"""
import html
import json
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
COMMONS = ROOT / "assets/logos/commons"
FLAGS = ROOT / "Packages/FlightKit/Sources/FlightKit/Resources/Flags.xcassets"
OUT = ROOT / "docs/logos"
CHROME_GLOB = "chromium_headless_shell-*/chrome-headless-shell-mac-arm64/chrome-headless-shell"
WIDTH = 1600
STYLE = """
html,body{margin:0;background:#f2f2f4;font:14px -apple-system,system-ui,sans-serif;color:#1c1c1e}
h1{font-size:22px;margin:0 0 4px} p{margin:0 0 20px;color:#636366}
.wrap{padding:32px}
.grid{display:grid;gap:14px 12px}
.cell{display:flex;flex-direction:column;align-items:center;gap:6px}
.pair{display:flex;gap:4px}
.tile{width:112px;height:72px;border-radius:10px;display:flex;align-items:center;justify-content:center}
.tile img{max-width:96px;max-height:56px}
.dark{background:#1c1c1e}.light{background:#fff;box-shadow:inset 0 0 0 1px #d1d1d6}
.code{font:600 12px ui-monospace,Menlo,monospace;letter-spacing:.04em}
table{border-collapse:collapse;margin-top:8px;width:100%}
td{padding:5px 10px 5px 0;border-top:1px solid #d1d1d6;vertical-align:top}
td.c{font:600 12px ui-monospace,Menlo,monospace;width:48px}
.flag img{width:56px;height:56px}
"""


def chrome() -> str:
    found = sorted((Path.home() / "Library/Caches/ms-playwright").glob(CHROME_GLOB))
    if not found:
        raise RuntimeError("no Playwright headless Chromium in ~/Library/Caches/ms-playwright")
    return str(found[-1])


def shoot(body: str, height: int, out: Path):
    with tempfile.TemporaryDirectory() as tmp:
        page = Path(tmp) / "sheet.html"
        page.write_text(f"<!doctype html><meta charset=utf-8><style>{STYLE}</style>{body}")
        subprocess.run([
            chrome(), "--headless", "--disable-gpu", "--hide-scrollbars", "--force-device-scale-factor=1",
            f"--user-data-dir={tmp}/profile", f"--window-size={WIDTH},{height}", f"--screenshot={out}",
            page.as_uri(),
        ], check=True, capture_output=True, timeout=120)


def library():
    manifest = json.loads((COMMONS / "manifest.json").read_text())
    logos = manifest["logos"]
    rejected = json.loads((COMMONS / "rejected.json").read_text())
    cols = 6
    cells = []
    for icao, v in sorted(logos.items()):
        src = (COMMONS / v["png"]).resolve().as_uri()
        cells.append(
            f'<div class=cell><div class=pair><div class="tile dark"><img src="{src}"></div>'
            f'<div class="tile light"><img src="{src}"></div></div><div class=code>{icao}</div></div>')
    rows = "".join(
        f"<tr><td class=c>{k}</td><td>{html.escape(v['name'])}</td><td>{html.escape(v['reason'])}</td>"
        f"<td>{html.escape(v['detail'])}</td></tr>" for k, v in sorted(rejected.items()))
    body = (
        f"<div class=wrap><h1>Airline logos from Wikimedia Commons</h1>"
        f"<p>{len(logos)} accepted, retrieved {manifest['retrieved']}. 192 px renders on dark and light tiles.</p>"
        f"<div class=grid style='grid-template-columns:repeat({cols},1fr)'>{''.join(cells)}</div>"
        f"<h1 style='margin-top:36px'>No usable logo ({len(rejected)})</h1>"
        f"<table>{rows}</table></div>")
    grid_rows = -(-len(cells) // cols)
    height = 32 + 60 + grid_rows * 106 + 70 + len(rejected) * 31 + 60
    shoot(body, height, OUT / "library.png")
    return len(logos), len(rejected)


def flags():
    sets = sorted(p for p in FLAGS.glob("flag-*.imageset"))
    cols = 16
    cells = []
    for s in sets:
        iso = s.name[len("flag-"):-len(".imageset")]
        svg = next(s.glob("*.svg"))
        cells.append(f'<div class="cell flag"><img src="{svg.resolve().as_uri()}"><div class=code>{iso.upper()}</div></div>')
    body = (
        f"<div class=wrap><h1>Bundled flags (circle-flags, MIT)</h1>"
        f"<p>{len(sets)} flags in Flags.xcassets, labelled ISO 3166-1 alpha-2 (XX is the unknown country fallback).</p>"
        f"<div class=grid style='grid-template-columns:repeat({cols},1fr)'>{''.join(cells)}</div></div>")
    height = 32 + 60 + -(-len(cells) // cols) * 94 + 40
    shoot(body, height, OUT / "flags.png")
    return len(sets)


def main() -> int:
    OUT.mkdir(parents=True, exist_ok=True)
    a, r = library()
    n = flags()
    print(f"library.png: {a} logos, {r} without; flags.png: {n} flags")
    return 0


if __name__ == "__main__":
    sys.exit(main())
