#!/usr/bin/env python3
"""Side-by-side reference vs Soma Flight component renders.

Crops the owner's reference screenshots (1320 px wide, @3x) and puts each crop on the left of
our ImageRenderer output (docs/screens/components, 393 pt @3x) on the right. Both stay at their
native @3x pixel size so type and spacing compare 1:1 in points; the shorter side is padded with
the page background to the same height.

Screen slices (docs/screens/screens/airport-N.png) are set beside the reference screens they
cover, stacked, as docs/screens/compare/screen-airport-N.png.

Usage: python3 Scripts/compare.py [--refs "/Users/quentin/Desktop/Screenshot FLight app"]
Needs Pillow (python3 -m pip install --user pillow).
"""
import argparse
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
OURS = ROOT / "docs/screens/components"
SCREENS = ROOT / "docs/screens/screens"
OUT = ROOT / "docs/screens/compare"
BG = (24, 24, 26)
GAP = 24

# name: (reference file, (left, top, right, bottom) in reference pixels)
CROPS = {
    "PerformanceSplit": ("IMG_0295.PNG", (0, 1300, 1320, 1760)),
    "DelayTrendChart": ("IMG_0295.PNG", (0, 1740, 1320, 2530)),
    "DelayChart": ("IMG_0302.PNG", (0, 640, 1320, 1580)),
    "WeatherBlock": ("IMG_0297.PNG", (0, 1250, 1320, 2640)),
    "BoardRow": ("IMG_0302.PNG", (0, 1714, 1320, 2692)),  # six rows
}


# Screen slices: our slice on the right, the matching reference screens stacked on the left,
# each cropped to the scrolling sheet (below the pinned header, above the floating tab bar).
SHEET = (0, 478, 1320, 2600)
SCREEN_REFS = {
    "airport-1": [("IMG_0294.PNG", (0, 1240, 1320, 2600)), ("IMG_0295.PNG", SHEET)],
    "airport-2": [("IMG_0296.PNG", SHEET), ("IMG_0297.PNG", SHEET)],
    "airport-3": [("IMG_0298.PNG", SHEET), ("IMG_0299.PNG", SHEET), ("IMG_0300.PNG", SHEET)],
    "airport-4": [("IMG_0301.PNG", SHEET), ("IMG_0302.PNG", (0, 600, 1320, 2868)), ("IMG_0306.PNG", SHEET)],
}


def side_by_side(left: Image.Image, right: Image.Image, path: Path) -> Path:
    h = max(left.height, right.height)
    canvas = Image.new("RGB", (left.width + GAP + right.width, h), BG)
    canvas.paste(left, (0, 0))
    for y in range(h):
        for x in range(left.width + GAP // 2 - 1, left.width + GAP // 2 + 1):
            canvas.putpixel((x, y), (90, 90, 96))
    canvas.paste(right, (left.width + GAP, 0))
    OUT.mkdir(parents=True, exist_ok=True)
    canvas.save(path, optimize=True)
    return path


def compose_screen(name: str, refs: Path) -> Path:
    crops = [Image.open(refs / f).convert("RGB").crop(box) for f, box in SCREEN_REFS[name]]
    left = Image.new("RGB", (max(c.width for c in crops), sum(c.height for c in crops) + GAP * (len(crops) - 1)), BG)
    y = 0
    for c in crops:
        left.paste(c, (0, y))
        y += c.height + GAP
    right = Image.open(SCREENS / f"{name}.png").convert("RGB")
    return side_by_side(left, right, OUT / f"screen-{name}.png")


def compose(name: str, refs: Path) -> Path:
    ref_file, box = CROPS[name]
    left = Image.open(refs / ref_file).convert("RGB").crop(box)
    right = Image.open(OURS / f"{name}.png").convert("RGB")
    h = max(left.height, right.height)
    canvas = Image.new("RGB", (left.width + GAP + right.width, h), BG)
    canvas.paste(left, (0, 0))
    # A thin divider so the two halves read apart.
    for y in range(h):
        for x in range(left.width + GAP // 2 - 1, left.width + GAP // 2 + 1):
            canvas.putpixel((x, y), (90, 90, 96))
    canvas.paste(right, (left.width + GAP, 0))
    OUT.mkdir(parents=True, exist_ok=True)
    path = OUT / f"component-{name}.png"
    canvas.save(path, optimize=True)
    return path


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--refs", default="/Users/quentin/Desktop/Screenshot FLight app")
    ap.add_argument("names", nargs="*", default=list(CROPS) + list(SCREEN_REFS))
    args = ap.parse_args()
    for n in args.names:
        print(compose_screen(n, Path(args.refs)) if n in SCREEN_REFS else compose(n, Path(args.refs)))


if __name__ == "__main__":
    main()
