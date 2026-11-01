#!/usr/bin/env python3
"""Copies the whole Commons logo library into the app as lossless WebP, for use offline.

    python3 -I Scripts/logos/bundle_logos.py

Source: assets/logos/commons/png/<ICAO>.png (wordmarks) and symbol/png/<ICAO>.png (symbols), both already
192 px on the longest side, transparent (written by fetch_commons.py and crop_symbols.py). 192 px is about
3x the largest square the app draws a mark in (AirlineLogo at 48 pt; 34 pt rows), and the size the backend
stores as its small rendition.

Writes Packages/FlightKit/Sources/FlightKit/Resources/Logos/:
    commons-wordmark-<ICAO>.webp, commons-symbol-<ICAO>.webp   pixels unchanged (cwebp -lossless), except
        a mark that came on a white box (its border opaque and white: BAW, CEB, ARG): the white is
        knocked out to transparency, each ink pixel keeping its colour (see knock_out_white)
    commons-logos.json   {"version", "wordmarks": [ICAO...], "symbols": [ICAO...]}, read by BundledLogos.swift
SwiftPM flattens resource folders, so the names carry a prefix no other resource uses.

Refuses to write when a file has no credit in Resources/Licenses/airline-logos.json (the list Settings >
Acknowledgements shows), or a credit has no file: what ships and what is credited stay the same set.
Needs cwebp, Pillow and numpy.
"""
import json
import pathlib
import subprocess
import sys
import tempfile

import numpy as np
from PIL import Image
from scipy import ndimage as ndi

ROOT = pathlib.Path(__file__).resolve().parents[2]
LIB = ROOT / "assets/logos/commons"
RES = ROOT / "Packages/FlightKit/Sources/FlightKit/Resources"
OUT = RES / "Logos"


def icaos(folder: pathlib.Path) -> list[str]:
    return sorted(p.stem for p in folder.glob("*.png") if len(p.stem) == 3 and p.stem.isalnum())


def on_white_box(im: Image.Image) -> bool:
    """True when the mark sits on an opaque white rectangle instead of a transparent canvas."""
    a = np.array(im.convert("RGBA")).astype(int)
    edge = np.concatenate([a[0], a[-1], a[:, 0], a[:, -1]])
    return bool(((edge[:, 3] > 200) & (edge[:, :3].min(axis=1) > 235)).mean() > 0.9)


def knock_out_white(im: Image.Image) -> Image.Image:
    """Turns a mark on white into a mark on transparency, without a white fringe.

    Each pixel's ink is its distance from white along its darkest channel. Its alpha is that ink
    relative to the strongest ink within 2 px (so flat light colours stay opaque and only the
    antialiased rim goes partial), and its colour is un-mixed from white at that alpha.
    """
    a = np.array(im.convert("RGBA")).astype(np.float32)
    rgb = a[..., :3]
    ink = 255.0 - rgb.min(axis=2)
    local = ndi.maximum_filter(ink, size=5)
    alpha = np.where(local < 24, 0.0, np.clip(ink / np.maximum(local, 1), 0, 1))
    alpha[ink < 6] = 0.0
    alpha *= a[..., 3] / 255.0
    fg = 255.0 - (255.0 - rgb) / np.maximum(alpha, 1e-3)[..., None]
    out = np.dstack([np.clip(fg, 0, 255), alpha * 255.0]).round().astype(np.uint8)
    out[out[..., 3] == 0] = 0
    return Image.fromarray(out)


def to_webp(src: pathlib.Path, dst: pathlib.Path) -> None:
    im = Image.open(src)
    with tempfile.TemporaryDirectory() as tmp:
        if on_white_box(im):
            src = pathlib.Path(tmp) / src.name
            knock_out_white(im).save(src)
            print("knocked out the white box of", dst.name)
        subprocess.run(["cwebp", "-quiet", "-lossless", "-z", "9", "-exact", str(src), "-o", str(dst)], check=True)


def main() -> int:
    manifest = json.loads((LIB / "manifest.json").read_text())
    credits = json.loads((RES / "Licenses/airline-logos.json").read_text())
    words, symbols = icaos(LIB / "png"), icaos(LIB / "symbol/png")
    credited = {c["icao"] for c in credits}
    credited_symbols = {c["icao"] for c in credits if c.get("symbol")}
    problems = []
    if set(words) != credited:
        problems.append(f"wordmarks without credit {sorted(set(words) - credited)}, "
                        f"credits without file {sorted(credited - set(words))}")
    if set(symbols) != credited_symbols:
        problems.append(f"symbols without credit {sorted(set(symbols) - credited_symbols)}, "
                        f"symbol credits without file {sorted(credited_symbols - set(symbols))}")
    if problems:
        print("\n".join(problems), file=sys.stderr)
        return 1

    OUT.mkdir(parents=True, exist_ok=True)
    for old in OUT.glob("commons-*.webp"):
        old.unlink()
    for kind, folder, names in (("wordmark", LIB / "png", words), ("symbol", LIB / "symbol/png", symbols)):
        for icao in names:
            to_webp(folder / f"{icao}.png", OUT / f"commons-{kind}-{icao}.webp")
    index = {"version": f"commons-{manifest['retrieved']}", "wordmarks": words, "symbols": symbols}
    (OUT / "commons-logos.json").write_text(json.dumps(index, indent=0) + "\n")
    size = sum(p.stat().st_size for p in OUT.iterdir())
    print(f"{len(words)} wordmarks, {len(symbols)} symbols, {size / 1e6:.2f} MB")
    return 0


if __name__ == "__main__":
    sys.exit(main())
