"""The climbing Jet on its own, no tile: a transparent square with the white plane exactly where the app icon
puts it (family.py's scale and nudge), so the launch screen, the splash and the sign-in mark line up with the
icon's plane.

    python3 assets/app-icon/plane_mark.py

Writes:
- Apps/iOS/Assets.xcassets/LaunchPlane.imageset (128 pt at @1x, @2x, @3x): the launch screen and the splash;
- FlightKit Resources/AppIconPreviews.xcassets/PlaneMark.imageset (300 px): the sign-in screen, the black jet
  in light mode (as the light app icon paints it) and the white jet in dark mode.
"""
import json, pathlib
from PIL import Image
import build as B
import family as F

ROOT = F.ROOT


def plane_square(px, paint=None):
    """The plane on a transparent px square, placed as `build.make` places it on the 1024 tile. `paint` recolours
    the sprite (build.black for the light icon's black jet); None keeps the white render."""
    sp, scale, nudge = F.plane_sprite("jet")
    if paint:
        sp = paint(sp)
    w = int(B.S * scale)
    k = w / max(sp.size)
    sp = sp.resize((round(sp.width * k), round(sp.height * k)), Image.LANCZOS)
    pos = (int(B.S / 2 - sp.width / 2 + nudge[0]), int(B.S / 2 - sp.height / 2 + nudge[1]))
    canvas = Image.new("RGBA", (B.S, B.S), (0, 0, 0, 0))
    canvas.alpha_composite(sp, pos)
    return canvas.resize((px, px), Image.LANCZOS)


def imageset(path, files):
    path.mkdir(exist_ok=True)
    for f in path.iterdir():
        if f.suffix == ".png":
            f.unlink()
    images = []
    for name, px, scale, *look in files:
        dark = look == ["dark"]
        plane_square(px, None if dark or not look else B.black).save(path / name, optimize=True)
        entry = {"filename": name, "idiom": "universal"}
        if dark:
            entry["appearances"] = [{"appearance": "luminosity", "value": "dark"}]
        if scale:
            entry["scale"] = scale
        images.append(entry)
    (path / "Contents.json").write_text(json.dumps({"images": images, "info": {"author": "xcode", "version": 1}},
                                                   indent=2) + "\n")


if __name__ == "__main__":
    imageset(ROOT / "Apps/iOS/Assets.xcassets/LaunchPlane.imageset",
             [("launch-plane@1x.png", 128, "1x"), ("launch-plane@2x.png", 256, "2x"), ("launch-plane@3x.png", 384, "3x")])
    imageset(F.PREVIEWS / "PlaneMark.imageset", [("planemark.png", 300, None, "light"), ("planemark-dark.png", 300, None, "dark")])
