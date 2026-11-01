"""Clean a raw generation into an app asset: drop the faint alpha halo, trim, resize, write the imageset.

    python3 assets/empty-states/post.py raw/profile-1.png empty-jet-profile [--preview DIR] [--lo 40] [--erode]

--lo raises the alpha floor for a raw with a wider glow; --erode then shaves one pixel off the rim so no light
fringe survives on the dark sheet (the app icon's cleanup).
"""
import json, pathlib, sys
import numpy as np
from PIL import Image, ImageFilter

ROOT = pathlib.Path(__file__).resolve().parents[2]
SETS = ROOT / "Packages/FlightKit/Sources/FlightKit/Resources/Illustrations.xcassets"
WIDTH = 900  # 300 pt wide at @3x, the largest the empty states draw it


def clean(path, lo=40, erode=False):
    im = Image.open(path).convert("RGBA")
    a = np.array(im).astype(np.float32)
    alpha = a[..., 3]
    # The model leaves a faint white glow (alpha under ~40) around the aircraft: fade it out.
    alpha = np.clip((alpha - lo) * 255 / (255 - lo), 0, 255)
    if erode:
        er = np.array(Image.fromarray(alpha.astype(np.uint8)).filter(ImageFilter.MinFilter(3))).astype(np.float32)
        alpha = np.array(Image.fromarray(np.minimum(alpha, er).astype(np.uint8)).filter(ImageFilter.GaussianBlur(0.6)))
    a[..., 3] = alpha
    im = Image.fromarray(a.astype(np.uint8))
    im = im.crop(im.getbbox())
    pad = int(im.width * 0.02)
    out = Image.new("RGBA", (im.width + 2 * pad, im.height + 2 * pad))
    out.paste(im, (pad, pad))
    h = round(out.height * WIDTH / out.width)
    return out.resize((WIDTH, h), Image.LANCZOS)


def preview(im, name, d):
    d = pathlib.Path(d); d.mkdir(parents=True, exist_ok=True)
    for tag, bg in (("dark", (9, 9, 10)), ("light", (242, 242, 247))):
        c = Image.new("RGBA", (im.width + 120, im.height + 120), bg + (255,))
        c.alpha_composite(im, (60, 60))
        c.convert("RGB").save(d / f"{name}-{tag}.png")


if __name__ == "__main__":
    src, name = sys.argv[1], sys.argv[2]
    lo = int(sys.argv[sys.argv.index("--lo") + 1]) if "--lo" in sys.argv else 40
    im = clean(src, lo, "--erode" in sys.argv)
    if "--preview" in sys.argv:
        preview(im, name, sys.argv[sys.argv.index("--preview") + 1])
        sys.exit()
    d = SETS / f"{name}.imageset"
    d.mkdir(exist_ok=True)
    im.save(d / f"{name}.png", optimize=True)
    (d / "Contents.json").write_text(json.dumps({
        "images": [{"filename": f"{name}.png", "idiom": "universal"}],
        "info": {"author": "xcode", "version": 1}}, indent=2) + "\n")
    print(d / f"{name}.png", im.size, (d / f"{name}.png").stat().st_size // 1024, "KB")
