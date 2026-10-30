#!/usr/bin/env python3
"""Review sheets for the bundled brand art.

    python3 -I Scripts/logos/build_sheets.py

docs/logos/library.png          per airline, its symbol (assets/logos/commons/symbol/png) and its
                                wordmark (assets/logos/commons/png) side by side, each on a dark and a
                                light tile, with counts; then the airlines with no usable logo and why.
docs/logos/symbols-at-size.png  every symbol at 24, 34 and 64 pt (rendered at 3x, as on an iPhone) on
                                dark and light, with the wordmark at 34 pt for comparison.
docs/logos/flags.png            every flag in Flags.xcassets, labelled with its ISO 3166-1 alpha-2 code.

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
.tile.none{color:#8e8e93;font-size:11px}.gap{width:10px}
.src{font:400 11px -apple-system,system-ui,sans-serif;color:#636366;letter-spacing:0}
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


def shoot(body: str, height: int, out: Path, scale: int = 1, width: int = WIDTH):
    with tempfile.TemporaryDirectory() as tmp:
        page = Path(tmp) / "sheet.html"
        page.write_text(f"<!doctype html><meta charset=utf-8><style>{STYLE}</style>{body}")
        subprocess.run([
            chrome(), "--headless", "--disable-gpu", "--hide-scrollbars", f"--force-device-scale-factor={scale}",
            f"--user-data-dir={tmp}/profile", f"--window-size={width},{height}", f"--screenshot={out}",
            page.as_uri(),
        ], check=True, capture_output=True, timeout=120)


def tiles(src, label):
    if not src:
        return (f'<div class="tile dark none">{label}</div><div class="tile light none">{label}</div>')
    return f'<div class="tile dark"><img src="{src}"></div><div class="tile light"><img src="{src}"></div>'


def library():
    manifest = json.loads((COMMONS / "manifest.json").read_text())
    logos = manifest["logos"]
    symbols = manifest.get("symbols", {})
    rejected = json.loads((COMMONS / "rejected.json").read_text())
    names = {**{k: v["name"] for k, v in logos.items()}, **{k: v["name"] for k, v in symbols.items()}}
    cols = 4
    cells = []
    # Airlines with a symbol first, then the rest, each in ICAO order.
    for icao in sorted(names, key=lambda k: (k not in symbols, k)):
        sym = (COMMONS / symbols[icao]["png"]).resolve().as_uri() if icao in symbols else None
        word = (COMMONS / logos[icao]["png"]).resolve().as_uri() if icao in logos else None
        src = html.escape(symbols[icao]["symbol_source"].split(" (")[0]) if icao in symbols else "wordmark only"
        cells.append(
            f'<div class=cell><div class=pair>{tiles(sym, "no symbol")}<div class=gap></div>'
            f'{tiles(word, "no wordmark")}</div>'
            f'<div class=code>{icao} <span class=src>{src}</span></div></div>')
    rows = "".join(
        f"<tr><td class=c>{k}</td><td>{html.escape(v['name'])}</td><td>{html.escape(v['reason'])}</td>"
        f"<td>{html.escape(v['detail'])}</td></tr>" for k, v in sorted(rejected.items()) if k not in symbols)
    no_logo = sum(1 for k in rejected if k not in symbols)
    by_source = {}
    for v in symbols.values():
        key = v["symbol_source"].split(" (")[0]
        by_source[key] = by_source.get(key, 0) + 1
    sources = ", ".join(f"{n} {html.escape(k)}" for k, n in sorted(by_source.items()))
    only_word = sum(1 for k in logos if k not in symbols)
    body = (
        f"<div class=wrap><h1>Airline marks from Wikimedia Commons</h1>"
        f"<p>Retrieved {manifest['retrieved']}. Each airline: symbol (left pair) and wordmark (right pair), "
        f"192 px renders on dark and light tiles.<br>"
        f"<b>{len(symbols)} symbols</b> ({sources}). <b>{len(logos)} wordmarks</b>. "
        f"<b>{only_word} wordmark only</b>. <b>{no_logo} with neither</b>.</p>"
        f"<div class=grid style='grid-template-columns:repeat({cols},1fr)'>{''.join(cells)}</div>"
        f"<h1 style='margin-top:36px'>No usable logo ({no_logo})</h1>"
        f"<table>{rows}</table></div>")
    grid_rows = -(-len(cells) // cols)
    height = 32 + 80 + grid_rows * 106 + 70 + no_logo * 31 + 60
    shoot(body, height, OUT / "library.png")
    return len(symbols), len(logos), no_logo


def symbols_at_size():
    manifest = json.loads((COMMONS / "manifest.json").read_text())
    logos = manifest["logos"]
    symbols = manifest.get("symbols", {})
    sizes = (24, 34, 64)

    def panel(cls, src, word):
        marks = "".join(
            f'<div class=sz><div class=box style="width:{s}px;height:{s}px"><img src="{src}"></div>'
            f'<div class=lab>{s} pt</div></div>' for s in sizes)
        w = (f'<div class=sz><div class=box style="width:34px;height:34px"><img src="{word}"></div>'
             f'<div class=lab>wordmark 34</div></div>') if word else ""
        return f'<div class="panel {cls}">{marks}{w}</div>'

    rows = []
    for icao, v in sorted(symbols.items()):
        src = (COMMONS / v["file"]).resolve().as_uri()
        word = (COMMONS / logos[icao]["file"]).resolve().as_uri() if icao in logos else None
        rows.append(
            f'<div class=row><div class=who><div class=code>{icao}</div><div>{html.escape(v["name"])}</div>'
            f'<div class=lic>{html.escape(v["license"])}, {html.escape(v["author"] or "Unknown author")}</div></div>'
            f'{panel("dark", src, word)}{panel("light", src, word)}</div>')
    style = (
        ".row{display:flex;gap:12px;align-items:stretch;margin-bottom:10px}"
        ".who{width:170px;font-size:12px;display:flex;flex-direction:column;justify-content:center;gap:2px}"
        ".lic{color:#636366;font-size:10px}"
        ".panel{flex:1;display:flex;align-items:flex-end;gap:22px;padding:14px 18px;border-radius:12px}"
        ".panel.dark{background:#000}.panel.light{background:#fff;box-shadow:inset 0 0 0 1px #d1d1d6}"
        ".sz{display:flex;flex-direction:column;align-items:center;gap:6px}"
        ".box{display:flex;align-items:center;justify-content:center}"
        ".box img{max-width:100%;max-height:100%}"
        ".lab{font:10px ui-monospace,Menlo,monospace;color:#8e8e93}")
    body = (
        f"<style>{style}</style><div class=wrap><h1>Symbols at app sizes</h1>"
        f"<p>{len(symbols)} symbols, drawn from the stored file at 24, 34 and 64 pt (3x pixels) on black and "
        f"white, wordmark at 34 pt for comparison.</p>{''.join(rows)}</div>")
    width = 1100
    height = 32 + 90 + len(rows) * 122 + 40
    shoot(body, height, OUT / "symbols-at-size.png", scale=3, width=width)
    return len(symbols)


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
    sym, word, none = library()
    at = symbols_at_size()
    n = flags()
    print(f"library.png: {sym} symbols, {word} wordmarks, {none} with neither; "
          f"symbols-at-size.png: {at}; flags.png: {n} flags")
    return 0


if __name__ == "__main__":
    sys.exit(main())
