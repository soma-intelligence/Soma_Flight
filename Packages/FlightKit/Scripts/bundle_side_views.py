#!/usr/bin/env python3
"""Copies the reviewed side views of aircraft-art into the package as WebP.

Source: Soma_Flight/aircraft-art/ai/<airline ICAO>-<type ICAO>.png (3200x1400, nose left, transparent;
the -raw files are the model's output before fitting and are skipped, rejects live in subfolders).
Each image is cut to the box of its pixels with alpha above 2% (as ProviderSideView.cropTransparent
does in the app), scaled to 1200 px wide (ProviderSideView.prepare's maxPixel) and written to
Sources/FlightKit/Resources/SideViews/<AIRLINE>-<TYPE>.webp, then index.json lists the pairs.
Usage: python3 Packages/FlightKit/Scripts/bundle_side_views.py [path/to/aircraft-art]
Needs Pillow and cwebp.
"""
import json, os, re, subprocess, sys, tempfile
from PIL import Image

here = os.path.dirname(os.path.abspath(__file__))
art = sys.argv[1] if len(sys.argv) > 1 else os.path.join(here, "../../../../../aircraft-art")
src = os.path.join(art, "ai")
out = os.path.join(here, "../Sources/FlightKit/Resources/SideViews")
os.makedirs(out, exist_ok=True)
name = re.compile(r"^([A-Z0-9]{3})-([A-Z0-9]{2,4})\.png$")

pairs = []
with tempfile.TemporaryDirectory() as tmp:
    for f in sorted(os.listdir(src)):
        m = name.match(f)
        if not m:
            continue
        im = Image.open(os.path.join(src, f)).convert("RGBA")
        box = im.getchannel("A").point(lambda a: 255 if a > 5 else 0).getbbox()
        if not box:
            print("empty", f)
            continue
        im = im.crop(box)
        if im.width > 1200:
            im = im.resize((1200, round(im.height * 1200 / im.width)), Image.LANCZOS)
        png = os.path.join(tmp, f)
        im.save(png)
        dst = os.path.join(out, f"{m[1]}-{m[2]}.webp")
        subprocess.run(["cwebp", "-quiet", "-q", "80", "-alpha_q", "90", "-m", "6", png, "-o", dst], check=True)
        pairs.append(f"{m[1]}-{m[2]}")

with open(os.path.join(out, "index.json"), "w") as fh:
    json.dump({"version": "aircraft-art-2026-10-30", "pairs": pairs}, fh, indent=0)
    fh.write("\n")
print(len(pairs), "side views")
