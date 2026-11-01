"""The primary app icon: a generated side-view jet (assets/app-icon/raw) on the Jet icon's charcoal tile.

    python3 assets/app-icon/build.py raw/icon-climb-1.png [--scale 0.80] [--rotate DEG] [--nudge X,Y] [--install] [--out DIR] [--mock DIR]

Writes <out>/icon.png, icon-dark.png, icon-tinted.png (1024 px, opaque RGB, square corners) and, with --mock,
a home screen mock (1024 master, 60 pt and 29 pt on dark and light wallpaper, watch circle). The tile, shadow
and tinted mapping are the v4 set's (assets/icon-set-v4/raw/src/build.py), so the brand colour stays the same.
"""
import pathlib, sys
import numpy as np
from PIL import Image, ImageDraw, ImageFilter

HERE = pathlib.Path(__file__).resolve().parent
S = 1024


def arg(name, default):
    return sys.argv[sys.argv.index(name) + 1] if name in sys.argv else default


def clean(im, lo=60, hi=235):
    """Hard-ish alpha ramp, then shave one pixel off the rim so no light fringe or halo survives."""
    a = np.array(im.convert("RGBA"))
    al = a[..., 3].astype(float)
    al = np.clip((al - lo) / (hi - lo), 0, 1) * 255
    er = np.array(Image.fromarray(al.astype("uint8")).filter(ImageFilter.MinFilter(3))).astype(float)
    al = np.array(Image.fromarray(np.minimum(al, er).astype("uint8")).filter(ImageFilter.GaussianBlur(0.6)))
    a[..., 3] = al
    im = Image.fromarray(a)
    return im.crop(im.getbbox())


def tile(mode, top=(44, 44, 48), bottom=(16, 16, 18)):
    if mode == "tint":
        return Image.new("RGB", (S, S), (0, 0, 0))
    if mode == "dark":
        top, bottom = tuple(int(c * 0.55) for c in top), tuple(int(c * 0.45) for c in bottom)
    t = np.linspace(0, 1, S)[:, None, None]
    g = np.array(top, float) * (1 - t) + np.array(bottom, float) * t
    yy, xx = np.mgrid[0:S, 0:S]
    d = np.hypot(xx - 430, yy - 400) / 700
    g = np.repeat(g, S, axis=1) + (np.exp(-d ** 2 * 2) * 10)[..., None]
    return Image.fromarray(np.clip(g, 0, 255).astype("uint8")).convert("RGB")


def contact_shadow(im, sprite, pos, alpha=0.75):
    """Two-layer soft shadow cast down from the top-left key (the jet floats above the tile)."""
    a = sprite.split()[3]
    for off, blur, al in (((8, 22), 10, 0.5), ((18, 56), 38, 0.55)):
        sh = Image.new("L", (S, S), 0)
        sh.paste(a, (pos[0] + off[0], pos[1] + off[1]))
        sh = sh.filter(ImageFilter.GaussianBlur(blur)).point(lambda v, al=al: int(v * al * alpha))
        im = Image.composite(Image.new("RGB", (S, S), (0, 0, 0)), im, sh)
    return im


def lift(sprite, base=0.62):
    a = np.array(sprite).astype(float)
    lum = a[..., :3].mean(2) / 255
    a[..., 0] = a[..., 1] = a[..., 2] = (base + (1 - base) * lum) * 255
    return Image.fromarray(a.astype("uint8"))


def tinted_of(im):
    g = np.array(im.convert("L")).astype(float) / 255
    t = np.clip((g - 0.04) / 0.9, 0, 1)
    return Image.fromarray((t * 255).astype("uint8")).convert("RGB")


def make(sprite, mode, scale, nudge):
    w = int(S * scale)
    k = w / max(sprite.size)
    sp = sprite.resize((round(sprite.width * k), round(sprite.height * k)), Image.LANCZOS)
    if mode == "tint":
        sp = lift(sp)
    pos = (int(S / 2 - sp.width / 2 + nudge[0]), int(S / 2 - sp.height / 2 + nudge[1]))
    bg = tile(mode)
    if mode != "tint":
        bg = contact_shadow(bg, sp, pos)
    im = bg.convert("RGBA")
    im.alpha_composite(sp, pos)
    return im.convert("RGB")


def squircle(size, n=5.0):
    yy, xx = np.mgrid[0:size, 0:size]
    r = size / 2
    u, v = np.abs((xx - r + 0.5) / r), np.abs((yy - r + 0.5) / r)
    return Image.fromarray(((u ** n + v ** n) <= 1).astype("uint8") * 255)


def mock(icon, path):
    """1024 master, then 60 pt (180 px) and 29 pt (87 px) masked icons on dark and light wallpaper, and a watch circle."""
    W, H = 1024 + 40 + 2 * 620, 1064
    c = Image.new("RGB", (W, H), (128, 128, 128))
    c.paste(icon.resize((1024, 1024)), (20, 20))
    for i, (bg, x0) in enumerate((((18, 22, 34), 1064), ((222, 226, 236), 1684))):
        ImageDraw.Draw(c).rectangle([x0, 20, x0 + 600, 1044], fill=bg)
        y = 60
        for px in (180, 87):
            small = icon.resize((px, px), Image.LANCZOS)
            c.paste(small, (x0 + 40, y), squircle(px).filter(ImageFilter.GaussianBlur(0.5)))
            # 2x zoom of the same size to judge it as on a retina screen
            z = small.resize((px * 2, px * 2), Image.NEAREST)
            c.paste(z, (x0 + 60 + px, y), squircle(px * 2))
            y += px * 2 + 40
        wpx = 160
        m = Image.new("L", (wpx, wpx), 0)
        ImageDraw.Draw(m).ellipse([0, 0, wpx - 1, wpx - 1], fill=255)
        c.paste(icon.resize((wpx, wpx), Image.LANCZOS), (x0 + 40, y), m)
    c.save(path)


def mac_tile(icon):
    """macOS frame: the art in an 824 px rounded square (Big Sur grid, radius 185) with a soft drop shadow."""
    m = Image.new("L", (S, S), 0)
    ImageDraw.Draw(m).rounded_rectangle([100, 100, 923, 923], 185, fill=255)
    sh = m.filter(ImageFilter.GaussianBlur(14)).point(lambda v: int(v * 0.35))
    sh = Image.fromarray(np.roll(np.array(sh), 12, axis=0))
    out = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    out.paste(Image.new("RGBA", (S, S), (0, 0, 0, 255)), (0, 0), sh)
    art = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    art.paste(icon.resize((824, 824), Image.LANCZOS), (100, 100))
    out.alpha_composite(Image.composite(art, Image.new("RGBA", (S, S), (0, 0, 0, 0)), m))
    return out


def install(out):
    """Copy the built icon into every catalog that carries the primary icon."""
    root = HERE.parents[1]
    ios = root / "Apps/iOS/Assets.xcassets"
    light, dark, tint = (Image.open(out / n).convert("RGB") for n in ("icon.png", "icon-dark.png", "icon-tinted.png"))
    light.save(ios / "AppIcon.appiconset/AppIcon-light.png", optimize=True)
    dark.save(ios / "AppIcon.appiconset/AppIcon-dark.png", optimize=True)
    tint.save(ios / "AppIcon.appiconset/AppIcon-tinted.png", optimize=True)
    light.resize((180, 180), Image.LANCZOS).save(ios / "Preview-jet.imageset/preview-jet.png", optimize=True)
    light.save(root / "Apps/Watch/Assets.xcassets/AppIcon.appiconset/AppIcon.png", optimize=True)
    light.resize((360, 360), Image.LANCZOS).save(
        root / "Packages/FlightKit/Sources/FlightKit/Resources/brand-app-icon.png", optimize=True)
    mac = mac_tile(light)
    for px in (16, 32, 64, 128, 256, 512, 1024):
        mac.resize((px, px), Image.LANCZOS).save(root / f"Apps/macOS/Assets.xcassets/AppIcon.appiconset/mac-{px}.png",
                                                optimize=True)


if __name__ == "__main__":
    src = HERE / sys.argv[1] if not pathlib.Path(sys.argv[1]).is_absolute() else pathlib.Path(sys.argv[1])
    scale = float(arg("--scale", "0.80"))
    nudge = tuple(int(v) for v in arg("--nudge", "0,-10").split(","))
    out = pathlib.Path(arg("--out", str(HERE)))
    out.mkdir(parents=True, exist_ok=True)
    sprite = clean(Image.open(src))
    rot = float(arg("--rotate", "0"))
    if rot:
        sprite = sprite.rotate(rot, expand=True, resample=Image.BICUBIC)
        sprite = sprite.crop(sprite.getbbox())
    light = make(sprite, "light", scale, nudge)
    light.save(out / "icon.png")
    make(sprite, "dark", scale, nudge).save(out / "icon-dark.png")
    tinted_of(make(sprite, "tint", scale, nudge)).save(out / "icon-tinted.png")
    if "--mock" in sys.argv:
        mock(light, arg("--mock", ""))
    if "--install" in sys.argv:
        install(out)
    print(out)
