#!/usr/bin/env python3
"""Side-by-side reference vs Soma Flight component renders.

Crops the owner's reference screenshots (1320 px wide, @3x) and puts each crop on the left of
our ImageRenderer output (docs/screens/components, 393 pt @3x) on the right. Both stay at their
native @3x pixel size so type and spacing compare 1:1 in points; the shorter side is padded with
the page background to the same height.

Screen slices (docs/screens/screens/airport-N.png) are set beside the reference screens they
cover, stacked, as docs/screens/compare/screen-airport-N.png.

iOS shell screenshots (docs/screens/ios/NAME.png, simulator captures at half of @3x) are set
beside the whole reference screen, also halved, as docs/screens/compare/ios-NAME.png.

v1.1 iOS screenshots (docs/screens/ios/v2-NAME.png) are set beside the v1.1 references in
.superpowers/ref-v2, as docs/screens/compare/v2-NAME.png (name them: `compare.py v2-passport-tab`).

Mac shell screenshots (docs/screens/mac/NAME.png, window captures at @2x) are set beside the
Mac reference window, also @2x, as docs/screens/compare/mac-NAME.png.

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
    # Task 6b screens. Mac screenshots are @2x, scaled by 1.5 to sit at @3x beside ours.
    "my-flights-empty": [("IMG_0292.PNG", (0, 1912, 1320, 2868))],
    "search": [("IMG_0308.PNG", (0, 190, 1320, 2868))],
    "passport-1": [("IMG_0310.PNG", (0, 1227, 1320, 2868)), ("10.50.29", (36, 50, 612, 1300), 1.5)],
    "passport-2": [("10.50.56", (20, 50, 612, 1290), 1.5)],
    "settings": [("IMG_0313.PNG", (0, 190, 1320, 2868)), ("IMG_0314.PNG", (0, 380, 1320, 2868))],
}


# iOS shell: our simulator capture beside the full reference screen it matches.
IOS = ROOT / "docs/screens/ios"
IOS_REFS = {
    "home": "IMG_0292.PNG",
    "detail": "IMG_0294.PNG",  # no flight sheet in the references: compared for the sheet chrome
    "airport": "IMG_0294.PNG",
    "passport": "IMG_0310.PNG",
}


# v1.1 iOS captures (docs/screens/ios/v2-NAME.png, halved) beside the v1.1 references
# (.superpowers/ref-v2/NN.png, git-ignored), also halved and stacked side by side, as
# docs/screens/compare/v2-NAME.png. The delay page has no reference screen of its own: it sits beside
# the Passport tab's delays card (52) for the card it grows from.
REFS_V2 = ROOT / ".superpowers/ref-v2"
V2_REFS = {
    "passport-tab": ["52", "53"],
    "delays": ["52"],
    # Full Passport, top to bottom: header map (42), flights and distance (44), distance comparisons,
    # shortest and longest, flight time (43), flight time grid and its shortest and longest (41). The
    # sparse run (one flight) sits beside the header it shrinks.
    "passport-full-1": ["42"],
    "passport-full-2": ["44"],
    "passport-full-3": ["43"],
    "passport-full-4": ["41"],
    "passport-full-sparse": ["42"],
}


def compose_v2(name: str) -> Path:
    refs = [Image.open(REFS_V2 / f"{n}.png").convert("RGB") for n in V2_REFS[name]]
    refs = [r.resize((r.width // 2, r.height // 2), Image.LANCZOS) for r in refs]
    left = Image.new("RGB", (sum(r.width for r in refs) + GAP * (len(refs) - 1), max(r.height for r in refs)), BG)
    x = 0
    for r in refs:
        left.paste(r, (x, 0))
        x += r.width + GAP
    right = Image.open(IOS / f"v2-{name}.png").convert("RGB")
    return side_by_side(left, right, OUT / f"v2-{name}.png")


# Mac shell: our window capture beside the Mac reference window (fragments of the file names).
MAC = ROOT / "docs/screens/mac"
MAC_REFS = {
    "home": "3.43.17",
    "detail": "3.43.17",  # no flight panel in the references: compared for the panel chrome
    "airport": "3.43.17",
    "passport": "10.50.29",
}


def compose_mac(name: str, refs: Path) -> Path:
    left = open_ref(refs, MAC_REFS[name])
    right = Image.open(MAC / f"{name}.png").convert("RGB")
    return side_by_side(left, right, OUT / f"mac-{name}.png")


def compose_ios(name: str, refs: Path) -> Path:
    ref = open_ref(refs, IOS_REFS[name])
    left = ref.resize((ref.width // 2, ref.height // 2), Image.LANCZOS)
    right = Image.open(IOS / f"{name}.png").convert("RGB")
    return side_by_side(left, right, OUT / f"ios-{name}.png")


def open_ref(refs: Path, name: str) -> Image.Image:
    """A reference by file name, or by a fragment of it (the Mac screenshots' names hold odd spaces)."""
    path = refs / name
    if not path.exists():
        path = next(p for p in sorted(refs.iterdir()) if name in p.name)
    return Image.open(path).convert("RGB")


def ref_crop(refs: Path, entry) -> Image.Image:
    name, box, *scale = entry
    crop = open_ref(refs, name).crop(box)
    if scale:
        crop = crop.resize((round(crop.width * scale[0]), round(crop.height * scale[0])), Image.LANCZOS)
    return crop


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
    crops = [ref_crop(refs, e) for e in SCREEN_REFS[name]]
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
    ap.add_argument("names", nargs="*", default=list(CROPS) + list(SCREEN_REFS) + [f"ios-{n}" for n in IOS_REFS]
                    + [f"mac-{n}" for n in MAC_REFS])
    args = ap.parse_args()
    for n in args.names:
        refs = Path(args.refs)
        if n.startswith("v2-"):
            print(compose_v2(n.removeprefix("v2-")))
        elif n.startswith("mac-"):
            print(compose_mac(n.removeprefix("mac-"), refs))
        elif n.startswith("ios-"):
            print(compose_ios(n.removeprefix("ios-"), refs))
        else:
            print(compose_screen(n, refs) if n in SCREEN_REFS else compose(n, refs))


if __name__ == "__main__":
    main()
