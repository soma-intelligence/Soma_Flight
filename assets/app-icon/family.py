"""The app icon family: the climbing Jet and the Supersonic, each on nine grounds and as a blueprint.

    python3 assets/app-icon/family.py [--sheet PATH]

Builds both jets with build.py's tile, shadow and tinted mapping, then writes every catalog:
- Apps/iOS AppIcon (primary Jet: light appearance black on white, dark appearance white on charcoal) and the
  alternates AppIcon-supersonic (the same, following the appearance) and AppIcon-<plane>-<ground> for each
  plane on white, paper, grey, charcoal, black, navy, sky, dusk and blue (black plane on the light grounds,
  white on the others; build.BACKGROUNDS) and AppIcon-<plane>-blueprint (blueprint.py, a vector line drawing);
- FlightKit Resources/AppIconPreviews.xcassets: one Preview-<slug> per icon (light and dark appearance) for the
  Settings picker, and BrandMark (the Jet, light and dark) for the sign-in screen;
- the Watch and Mac AppIcon sets (white jet on charcoal, the Mac in its framed tile).
"""
import json, pathlib, sys
from PIL import Image
import build as B

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parents[1]
IOS = ROOT / "Apps/iOS/Assets.xcassets"
PREVIEWS = ROOT / "Packages/FlightKit/Sources/FlightKit/Resources/AppIconPreviews.xcassets"
PREVIEW_PX = 300  # the picker draws 76 pt and the sign-in mark 92 pt, at @3x

PLANES = {
    # slug: (raw, scale, rotate, nudge)
    "jet": ("raw/icon-climb-1.png", 0.89, 8, (0, 6)),
    "supersonic": ("raw/sst-three-quarter-1.png", 0.92, 4, (0, 8)),
}


def render(slug):
    raw, scale, rot, nudge = PLANES[slug]
    sp = B.clean(Image.open(HERE / raw))
    if rot:
        sp = sp.rotate(rot, expand=True, resample=Image.BICUBIC)
        sp = sp.crop(sp.getbbox())
    out = {m: B.make(sp, m, scale, nudge) for m in ("light", "dark", "white")}
    out["tinted"] = B.tinted_of(B.make(sp, "tint", scale, nudge))
    d = HERE / slug
    d.mkdir(exist_ok=True)
    for m, im in out.items():
        im.save(d / f"{m}.png")
    return out


def appicon(name, any_, dark, tinted):
    d = IOS / f"{name}.appiconset"
    d.mkdir(exist_ok=True)
    for f in d.glob("*.png"):
        f.unlink()
    any_.convert("RGB").save(d / "light.png", optimize=True)
    dark.convert("RGB").save(d / "dark.png", optimize=True)
    tinted.convert("RGB").save(d / "tinted.png", optimize=True)
    (d / "Contents.json").write_text(
        '{\n  "images" : [\n'
        '    { "filename" : "light.png", "idiom" : "universal", "platform" : "ios", "size" : "1024x1024" },\n'
        '    { "appearances" : [ { "appearance" : "luminosity", "value" : "dark" } ], "filename" : "dark.png", '
        '"idiom" : "universal", "platform" : "ios", "size" : "1024x1024" },\n'
        '    { "appearances" : [ { "appearance" : "luminosity", "value" : "tinted" } ], "filename" : "tinted.png", '
        '"idiom" : "universal", "platform" : "ios", "size" : "1024x1024" }\n'
        '  ],\n  "info" : { "author" : "xcode", "version" : 1 }\n}\n')


def preview(name, light, dark):
    d = PREVIEWS / f"{name}.imageset"
    d.mkdir(parents=True, exist_ok=True)
    stem = name.lower()
    light.resize((PREVIEW_PX, PREVIEW_PX), Image.LANCZOS).convert("RGB").save(d / f"{stem}.png", optimize=True)
    dark.resize((PREVIEW_PX, PREVIEW_PX), Image.LANCZOS).convert("RGB").save(d / f"{stem}-dark.png", optimize=True)
    (d / "Contents.json").write_text(json.dumps({"images": [
        {"filename": f"{stem}.png", "idiom": "universal"},
        {"appearances": [{"appearance": "luminosity", "value": "dark"}], "filename": f"{stem}-dark.png",
         "idiom": "universal"}], "info": {"author": "xcode", "version": 1}}, indent=2) + "\n")


def sheet(icons, path, per_row=11):
    """Every icon at 60 pt (180 px), masked, on a light and on a dark wallpaper, with its name, one plane per row."""
    from PIL import ImageDraw, ImageFont, ImageFilter
    font = ImageFont.truetype("/System/Library/Fonts/SFNS.ttf", 24)
    cell, pad, band = 214, 30, 280
    rows = [icons[i:i + per_row] for i in range(0, len(icons), per_row)]
    w = pad * 2 + per_row * cell
    c = Image.new("RGB", (w, 2 * len(rows) * band), (0, 0, 0))
    mask = B.squircle(180).filter(ImageFilter.GaussianBlur(0.5))
    y = 0
    for bg, fg, key in (((232, 234, 240), (40, 40, 44), "light"), ((20, 22, 30), (230, 230, 235), "dark")):
        for row in rows:
            ImageDraw.Draw(c).rectangle([0, y, w, y + band], fill=bg)
            for i, (name, look) in enumerate(row):
                x = pad + i * cell
                c.paste(look[key].resize((180, 180), Image.LANCZOS), (x, y + 28), mask)
                ImageDraw.Draw(c).text((x + 90, y + 222), name, font=font, fill=fg, anchor="mt")
            y += band
    c.save(path)


GROUNDS = ["white", "paper", "grey", "charcoal", "black", "navy", "sky", "dusk", "blue"]
LABELS = {"white": "White", "paper": "Paper", "grey": "Grey", "charcoal": "Charcoal", "black": "Black",
          "navy": "Navy", "sky": "Sky", "dusk": "Dusk", "blue": "Blue", "blueprint": "Blueprint"}


def plane_sprite(slug):
    raw, scale, rot, nudge = PLANES[slug]
    sp = B.clean(Image.open(HERE / raw))
    if rot:
        sp = sp.rotate(rot, expand=True, resample=Image.BICUBIC)
        sp = sp.crop(sp.getbbox())
    return sp, scale, nudge


if __name__ == "__main__":
    import blueprint as BP
    for old in ("jet-light", "jet-dark", "supersonic-light", "supersonic-dark"):
        for d in (IOS / f"AppIcon-{old}.appiconset", PREVIEWS / f"Preview-{old}.imageset"):
            if d.exists():
                for f in d.iterdir():
                    f.unlink()
                d.rmdir()
    looks, rows = {}, []
    for plane in PLANES:
        base = render(plane)
        sp, scale, nudge = plane_sprite(plane)
        bp_nudge = (nudge[0], nudge[1] - 16)
        tinted = base["tinted"]
        looks[plane] = (base["white"], base["dark"], tinted)  # Auto: black on white by day, charcoal at night
        for g in GROUNDS:
            im = B.make_on(sp, g, scale, nudge)
            looks[f"{plane}-{g}"] = (im, im, tinted)
        bpi = BP.blueprint(sp, scale - 0.03, bp_nudge)
        looks[f"{plane}-blueprint"] = (bpi, bpi, B.tinted_of(BP.blueprint(sp, scale - 0.03, bp_nudge, tint=True)))
        d = HERE / plane
        for g in GROUNDS + ["blueprint"]:
            looks[f"{plane}-{g}"][0].save(d / f"{g}.png")
    for slug, (lt, dk, tn) in looks.items():
        appicon("AppIcon" if slug == "jet" else f"AppIcon-{slug}", lt, dk, tn)
        preview(f"Preview-{slug}", lt, dk)
    jet = looks["jet"]
    preview("BrandMark", jet[0], looks["jet-charcoal"][0])
    looks["jet-charcoal"][0].convert("RGB").save(ROOT / "Apps/Watch/Assets.xcassets/AppIcon.appiconset/AppIcon.png",
                                                optimize=True)
    mac = B.mac_tile(looks["jet-charcoal"][0])
    for px in (16, 32, 64, 128, 256, 512, 1024):
        mac.resize((px, px), Image.LANCZOS).save(ROOT / f"Apps/macOS/Assets.xcassets/AppIcon.appiconset/mac-{px}.png",
                                                optimize=True)
    if "--sheet" in sys.argv:
        order = []
        for plane in PLANES:
            title = "Jet" if plane == "jet" else "SST"
            order.append((f"{title} Auto", looks[plane]))
            order += [(f"{title} {LABELS[g]}", looks[f"{plane}-{g}"]) for g in GROUNDS + ["blueprint"]]
        sheet([(n, {"light": l[0], "dark": l[1]}) for n, l in order], sys.argv[sys.argv.index("--sheet") + 1])
    print("done", len(looks), "icons")
