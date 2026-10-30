#!/usr/bin/env python3
"""One labelled sheet of the v1.1 screens for the owner: docs/screens/v1-1-overview.png.

Takes the simulator captures in docs/screens/ios (v2-*.png, 660 by 1434) and the Mac window captures in
docs/screens/mac, and lays them out in labelled rows. Refresh the captures first (see docs/screens/README.md).

Usage: python3 Scripts/overview.py
Needs Pillow.
"""
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parent.parent
IOS = ROOT / "docs/screens/ios"
MAC = ROOT / "docs/screens/mac"
OUT = ROOT / "docs/screens/v1-1-overview.png"

BG = (18, 18, 20)
INK = (235, 235, 240)
DIM = (150, 150, 158)
TILE_W = 300
GAP = 28
LABEL_H = 54

# Rows: a title, then (capture, label). iOS captures by name; Mac ones prefixed "mac/".
ROWS = [
    ("Home and the flight sheet", [
        ("v2-home", "Home"),
        ("v2-myflights", "My Flights"),
        ("v2-detail-top", "Flight detail, top"),
        ("v2-detail-good-to-know", "Flight detail, Good to Know"),
        ("v2-detail-plane", "Flight detail, where is my plane"),
        ("v2-detail-timetable", "Flight detail, timetable"),
        ("v2-add-flight", "Add Flight"),
    ]),
    ("Passport tab and its full pages", [
        ("v2-passport-tab", "Passport tab"),
        ("v2-delays", "Delay stats"),
        ("v2-aircraft-stats-1", "Aircraft stats, top"),
        ("v2-aircraft-stats-2", "Aircraft stats, cabin"),
        ("v2-aircraft-stats-3", "Aircraft stats, types"),
        ("v2-aircraft-stats-4", "Aircraft stats, seats"),
        ("v2-aircraft-stats-5", "Aircraft stats, tails and age"),
    ]),
    ("Full Passport, top to bottom", [
        ("v2-passport-full-1", "Map and card"),
        ("v2-passport-full-2", "Flights and distance"),
        ("v2-passport-full-3", "Flight time"),
        ("v2-passport-full-4", "Flight time grid"),
        ("v2-passport-full-5", "Top airports and airlines"),
        ("v2-passport-full-6", "Airlines and routes"),
        ("v2-passport-full-7", "Countries and regions"),
    ]),
    ("Mac", [
        ("mac/v2-detail", "Flight panel"),
        ("mac/v2-passport-full", "Full Passport sheet"),
        ("mac/v2-aircraft-stats", "Aircraft stats sheet"),
    ]),
]


def font(size: int, bold: bool = False):
    for path in ["/System/Library/Fonts/SFNS.ttf", "/System/Library/Fonts/Helvetica.ttc"]:
        try:
            return ImageFont.truetype(path, size, index=1 if bold and path.endswith(".ttc") else 0)
        except OSError:
            continue
    return ImageFont.load_default()


def load(name: str) -> Image.Image:
    path = MAC / f"{name.removeprefix('mac/')}.png" if name.startswith("mac/") else IOS / f"{name}.png"
    im = Image.open(path).convert("RGB")
    if name.startswith("mac/"):
        # Mac windows span two and a half phone tiles.
        w = TILE_W * 5 // 2 + GAP
    else:
        w = TILE_W
    return im.resize((w, round(im.height * w / im.width)), Image.LANCZOS)


def main() -> None:
    title_f, row_f, label_f = font(44, True), font(28, True), font(20)
    columns = max(len(r[1]) for r in ROWS)
    width = GAP + columns * (TILE_W + GAP)
    rows = [(title, [(load(n), label) for n, label in items]) for title, items in ROWS]
    height = 120 + sum(50 + max(im.height for im, _ in items) + LABEL_H + GAP for _, items in rows)
    sheet = Image.new("RGB", (width, height), BG)
    draw = ImageDraw.Draw(sheet)
    draw.text((GAP, 36), "Soma Flight v1.1, screens on fakes", font=title_f, fill=INK)
    y = 120
    for title, items in rows:
        draw.text((GAP, y), title, font=row_f, fill=DIM)
        y += 50
        x = GAP
        for im, label in items:
            sheet.paste(im, (x, y))
            draw.text((x, y + im.height + 12), label, font=label_f, fill=INK)
            x += im.width + GAP
        y += max(im.height for im, _ in items) + LABEL_H + GAP
    sheet.save(OUT, optimize=True)
    print(OUT, sheet.size)


if __name__ == "__main__":
    main()
