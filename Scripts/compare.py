#!/usr/bin/env python3
"""Side-by-side reference vs Soma Flight component renders.

Crops the owner's reference screenshots (1320 px wide, @3x) and puts each crop on the left of
our ImageRenderer output (docs/screens/components, 393 pt @3x) on the right. Both stay at their
native @3x pixel size so type and spacing compare 1:1 in points; the shorter side is padded with
the page background to the same height.

Usage: python3 Scripts/compare.py [--refs "/Users/quentin/Desktop/Screenshot FLight app"]
Needs Pillow (python3 -m pip install --user pillow).
"""
import argparse
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
OURS = ROOT / "docs/screens/components"
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
    ap.add_argument("names", nargs="*", default=list(CROPS))
    args = ap.parse_args()
    for n in args.names:
        print(compose(n, Path(args.refs)))


if __name__ == "__main__":
    main()
