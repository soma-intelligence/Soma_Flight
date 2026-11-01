"""Composite the abstract icon set: one generated jet glyph, PIL tiles and accents."""
import json, math, numpy as np
from PIL import Image, ImageFilter, ImageDraw, ImageFont, ImageChops

D = "/Users/quentin/Desktop/Soma/Soma_Flight/assets/icon-set-abstract/"
R = D + "raw/"
S = 1024
CORAL_A, CORAL_B = (255, 138, 76), (238, 78, 43)


def raw(n):
    return Image.open(R + n + ".png").convert("RGBA")


def clean(im):
    a = np.array(im)
    al = a[..., 3].astype(float)
    al = np.clip((al - 10) / 235, 0, 1) * 255
    a[..., 3] = al.astype("uint8")
    return Image.fromarray(a)


JET = clean(raw("jet-a")).crop((87, 74, 956, 966))  # 869 x 892


def jet(scale=0.60, center=(512, 512), dx=0, dy=0):
    w = int(S * scale)
    h = int(JET.height * w / JET.width)
    j = JET.resize((w, h), Image.LANCZOS)
    x = center[0] - w // 2 + dx
    y = center[1] - h // 2 + dy
    return j, (x, y), w / JET.width


def jet_pt(px, py, ox, oy, k):
    return ox + (px - 87) * k, oy + (py - 74) * k


# ---------- tile ----------
def squircle(size, inset=0, n=5.0):
    m = Image.new("L", (size, size), 0)
    a = np.zeros((size, size), "uint8")
    yy, xx = np.mgrid[0:size, 0:size]
    r = size / 2 - inset
    u = np.abs((xx - size / 2 + 0.5) / r)
    v = np.abs((yy - size / 2 + 0.5) / r)
    a[(u ** n + v ** n) <= 1] = 255
    return Image.fromarray(a)


def tile(top=(30, 30, 33), bottom=(11, 11, 13), rim=0.16):
    t = np.linspace(0, 1, S)[:, None, None]
    g = np.array(top, float) * (1 - t) + np.array(bottom, float) * t
    base = np.repeat(g, S, axis=1)
    im = Image.fromarray(base.astype("uint8")).convert("RGB")
    if rim:
        # soft inner edge light following the iOS mask, stronger at the top
        outer = squircle(S, 0)
        inner = squircle(S, 10).filter(ImageFilter.GaussianBlur(12))
        ring = ImageChops.subtract(outer, inner).filter(ImageFilter.GaussianBlur(3))
        fall = np.linspace(1.0, 0.25, S)[:, None]
        ring = Image.fromarray((np.array(ring) * fall * rim).astype("uint8"))
        im = Image.composite(Image.new("RGB", (S, S), (255, 255, 255)), im, ring)
    return im


def glow(im, center, radius, color, strength):
    yy, xx = np.mgrid[0:S, 0:S]
    d = np.hypot(xx - center[0], yy - center[1]) / radius
    m = np.exp(-d ** 2 * 2.2) * strength
    a = np.array(im).astype(float)
    c = np.array(color, float)
    a = a * (1 - m[..., None]) + c * m[..., None]
    return Image.fromarray(np.clip(a, 0, 255).astype("uint8"))


def add_glow(im, center, radius, color, strength):
    """Additive light (for wingtip lights, embers)."""
    yy, xx = np.mgrid[0:S, 0:S]
    d = np.hypot(xx - center[0], yy - center[1]) / radius
    m = np.exp(-d ** 2 * 2.5) * strength
    a = np.array(im).astype(float) + np.array(color, float) * m[..., None]
    return Image.fromarray(np.clip(a, 0, 255).astype("uint8"))


def shadow(im, sprite, pos, off=(18, 34), blur=26, alpha=0.55, color=(0, 0, 0)):
    a = sprite.split()[3]
    sh = Image.new("L", (S, S), 0)
    sh.paste(a, (pos[0] + off[0], pos[1] + off[1]))
    sh = sh.filter(ImageFilter.GaussianBlur(blur))
    sh = sh.point(lambda v: int(v * alpha))
    return Image.composite(Image.new("RGB", (S, S), color), im, sh)


def put(im, sprite, pos):
    im = im.convert("RGBA")
    im.alpha_composite(sprite, (int(pos[0]), int(pos[1])))
    return im.convert("RGB")


def with_jet(bg, scale=0.60, center=(512, 512), shadow_kw=None):
    j, pos, k = jet(scale, center)
    bg = shadow(bg, j, pos, **(shadow_kw or {}))
    return put(bg, j, pos), pos, k


# ---------- icons ----------
def ember():
    bg = tile()
    bg = glow(bg, (560, 600), 520, CORAL_B, 0.55)
    bg = glow(bg, (560, 600), 300, CORAL_A, 0.45)
    im, _, _ = with_jet(bg, shadow_kw=dict(off=(20, 40), blur=30, alpha=0.65, color=(70, 14, 4)))
    return im


def redeye():
    bg = tile(top=(22, 23, 30), bottom=(9, 9, 13))
    j, pos, k = jet()
    bg = shadow(bg, j, pos, off=(18, 34), blur=26, alpha=0.7)
    im = put(bg, j, pos)
    port = jet_pt(152, 217, *pos, k)
    stbd = jet_pt(875, 906, *pos, k)
    for (x, y), c in ((port, (255, 40, 50)), (stbd, (40, 255, 120))):
        im = add_glow(im, (x + 2, y + 2), 110, c, 0.42)
        im = add_glow(im, (x + 2, y + 2), 16, (255, 255, 255), 0.25)
        im = add_glow(im, (x + 2, y + 2), 28, c, 0.75)
    return im


def sweep():
    bg = tile()
    c = (512, 512)
    yy, xx = np.mgrid[0:S, 0:S]
    r = np.hypot(xx - c[0], yy - c[1])
    disc_r = 430
    a = np.array(bg).astype(float)
    disc = np.clip((disc_r - r) / 3, 0, 1)
    a = a * (1 - 0.35 * disc[..., None]) + np.array((22, 22, 24)) * 0.35 * disc[..., None]
    rings = np.zeros_like(r)
    for rr in (140, 250, 360, disc_r):
        rings = np.maximum(rings, np.exp(-((r - rr) / 1.6) ** 2))
    ang = (np.degrees(np.arctan2(yy - c[1], xx - c[0])) + 360) % 360
    # sweep beam: leading edge at -45 deg (upper right), trailing tail counter-clockwise
    lead = 315.0
    behind = (lead - ang) % 360
    beam = np.where(behind < 70, np.clip(1 - behind / 70, 0, 1) ** 2.2, 0) * disc
    col = np.array(CORAL_A, float)
    a = a + rings[..., None] * disc[..., None] * 48
    a = a * (1 - beam[..., None] * 0.55) + col * beam[..., None] * 0.55
    edge = np.exp(-(((ang - lead + 180) % 360 - 180) / 0.6) ** 2) * disc * (r > 8)
    a = a + edge[..., None] * col * 0.6
    bg = Image.fromarray(np.clip(a, 0, 255).astype("uint8"))
    for bx, by in ((300, 340), (705, 680), (640, 245)):
        bg = add_glow(bg, (bx, by), 14, CORAL_A, 0.9)
    im, _, _ = with_jet(bg, scale=0.56, shadow_kw=dict(off=(16, 30), blur=24, alpha=0.7))
    return im


def lastcall():
    bg = tile()
    d = ImageDraw.Draw(bg)
    # two rows of blank split-flap tiles across the lower edge, one coral tile
    tw, th, gap = 128, 150, 14
    rows_y = (S - 2 * th - gap + 20, S - th + 20)
    n = 7
    x0 = (S - (n * tw + (n - 1) * gap)) // 2
    lay = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ld = ImageDraw.Draw(lay)
    for ri, y in enumerate(rows_y):
        for i in range(n):
            x = x0 + i * (tw + gap)
            coral = (ri, i) in ((0, 4), (1, 2))
            top = (255, 146, 84) if coral else (50, 50, 55)
            bot = (236, 86, 46) if coral else (37, 37, 41)
            ld.rounded_rectangle([x, y, x + tw, y + th // 2 - 3], 16, fill=top + (255,))
            ld.rounded_rectangle([x, y + th // 2 + 3, x + tw, y + th], 16, fill=bot + (255,))
            hl = (255, 196, 160) if coral else (78, 78, 84)
            ld.line([x + 14, y + 2, x + tw - 14, y + 2], fill=hl + (255,), width=2)
    fade = np.clip((np.arange(S) - (rows_y[0] - 20)) / 220, 0, 1)
    fade = np.repeat(fade[:, None], S, axis=1)
    la = np.array(lay)
    la[..., 3] = (la[..., 3] * (0.35 + 0.65 * fade)).astype("uint8")
    bg = put(bg, Image.fromarray(la), (0, 0))
    im, _, _ = with_jet(bg, scale=0.56, center=(512, 400), shadow_kw=dict(off=(18, 46), blur=28, alpha=0.75))
    return im


def spectrum():
    bg = tile()
    rib = clean(raw("ribbon-a"))
    j, pos, k = jet(0.50, center=(590, 440))
    tail = jet_pt(205, 805, *pos, k)
    rb = rib.getbbox()
    rib = rib.crop(rb)
    return bg, rib, j, pos, tail


def mach():
    bg = tile(top=(26, 26, 30), bottom=(10, 10, 12))
    dl = clean(raw("delta-b"))
    dl = dl.crop(dl.getbbox())
    w = int(S * 0.76)
    h = int(dl.height * w / dl.width)
    dl = dl.resize((w, h), Image.LANCZOS)
    pos = ((S - w) // 2 - 6, (S - h) // 2 + 22)
    bg = shadow(bg, dl, pos, off=(18, 34), blur=26, alpha=0.6)
    return put(bg, dl, pos)


def nightside():
    bg = Image.open(R + "globe-a.png").convert("RGB").resize((S, S), Image.LANCZOS)
    im, _, _ = with_jet(bg, scale=0.52, center=(512, 420), shadow_kw=dict(off=(16, 30), blur=24, alpha=0.7))
    return im


# ---------- variants ----------
def dark_of(im):
    return im  # every tile is already near black; iOS 26 dark can reuse it


def tinted_of(im, lo=0.32):
    g = np.array(im.convert("L")).astype(float) / 255
    t = np.clip((g - lo) / (0.87 - lo), 0, 1) ** 1.25
    return Image.fromarray((t * 255).astype("uint8")).convert("RGB")


NAMES = [
    ("ember", "Ember", "Our white jet over a warm coral glow."),
    ("redeye", "Red Eye", "Red to port, green to starboard, wheels up at midnight."),
    ("sweep", "Sweep", "One coral sweep, every blip a flight."),
    ("lastcall", "Last Call", "The board flips, the gate closes, you're on."),
    ("spectrum", "Spectrum", "Fly proud and leave a rainbow behind."),
    ("mach", "Mach Two", "Afterburners on, breakfast in another time zone."),
    ("nightside", "Night Side", "Cities glowing below at cruising altitude."),
]

if __name__ == "__main__":
    import sys
    from spectrum_comp import spectrum_icon
    makers = dict(ember=ember, redeye=redeye, sweep=sweep, lastcall=lastcall,
                  spectrum=lambda: spectrum_icon(*spectrum()), mach=mach, nightside=nightside)
    only = sys.argv[1:] or [n[0] for n in NAMES]
    for slug in only:
        im = makers[slug]()
        im.save(D + slug + ".png")
        dark_of(im).save(D + slug + "-dark.png")
        tinted_of(im, 0.13 if slug == "lastcall" else 0.32).save(D + slug + "-tinted.png")
        for s in (60, 29):
            im.resize((s, s), Image.LANCZOS).save(D + f"{slug}-{s}.png")
        print("built", slug)
