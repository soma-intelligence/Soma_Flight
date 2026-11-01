"""The app icon family: the climbing Jet and the Supersonic, each white on charcoal and black on white.

    python3 assets/app-icon/family.py [--sheet PATH]

Builds both jets with build.py's tile, shadow and tinted mapping, then writes every catalog:
- Apps/iOS AppIcon (primary Jet: light appearance black on white, dark appearance white on charcoal) and the
  alternates AppIcon-jet-light, AppIcon-jet-dark, AppIcon-supersonic, AppIcon-supersonic-light,
  AppIcon-supersonic-dark;
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


def sheet(icons, path):
    """Every icon at 60 pt (180 px), masked, on a light and a dark wallpaper, with its name."""
    from PIL import ImageDraw, ImageFont, ImageFilter
    font = ImageFont.truetype("/System/Library/Fonts/SFNS.ttf", 26)
    cell, pad = 230, 30
    w = pad + len(icons) * cell
    c = Image.new("RGB", (w, 2 * 300), (0, 0, 0))
    mask = B.squircle(180).filter(ImageFilter.GaussianBlur(0.5))
    for row, (bg, fg, key) in enumerate((((232, 234, 240), (40, 40, 44), "light"), ((20, 22, 30), (230, 230, 235), "dark"))):
        ImageDraw.Draw(c).rectangle([0, row * 300, w, row * 300 + 300], fill=bg)
        for i, (name, look) in enumerate(icons):
            x, y = pad + i * cell, row * 300 + 30
            c.paste(look[key].resize((180, 180), Image.LANCZOS), (x, y), mask)
            ImageDraw.Draw(c).text((x + 90, y + 200), name, font=font, fill=fg, anchor="mt")
    c.save(path)


if __name__ == "__main__":
    jet, sst = render("jet"), render("supersonic")
    # light appearance / dark appearance of each choice, as the system and the picker show them
    looks = {
        "jet": (jet["white"], jet["dark"]), "jet-light": (jet["white"], jet["white"]),
        "jet-dark": (jet["light"], jet["dark"]), "supersonic": (sst["white"], sst["dark"]),
        "supersonic-light": (sst["white"], sst["white"]), "supersonic-dark": (sst["light"], sst["dark"]),
    }
    tints = {"jet": jet["tinted"], "supersonic": sst["tinted"]}
    for slug, (lt, dk) in looks.items():
        appicon("AppIcon" if slug == "jet" else f"AppIcon-{slug}", lt, dk, tints[slug.split("-")[0]])
        preview(f"Preview-{slug}", lt, dk)
    preview("BrandMark", jet["white"], jet["light"])
    jet["light"].convert("RGB").save(ROOT / "Apps/Watch/Assets.xcassets/AppIcon.appiconset/AppIcon.png", optimize=True)
    mac = B.mac_tile(jet["light"])
    for px in (16, 32, 64, 128, 256, 512, 1024):
        mac.resize((px, px), Image.LANCZOS).save(ROOT / f"Apps/macOS/Assets.xcassets/AppIcon.appiconset/mac-{px}.png",
                                                optimize=True)
    if not (PREVIEWS / "Contents.json").exists():
        (PREVIEWS / "Contents.json").write_text('{\n  "info" : { "author" : "xcode", "version" : 1 }\n}\n')
    if "--sheet" in sys.argv:
        names = {"jet": "Jet", "jet-light": "Jet Light", "jet-dark": "Jet Dark", "supersonic": "Supersonic",
                 "supersonic-light": "SST Light", "supersonic-dark": "SST Dark"}
        sheet([(names[s], {"light": lt, "dark": dk}) for s, (lt, dk) in looks.items()],
              sys.argv[sys.argv.index("--sheet") + 1])
    print("done")
