"""Icon set v3: one generated chrome widebody (nose up, rotated here), PIL tiles and accents.

Each maker takes a render mode: "light", "dark" or "tint". Tint renders the same
composition on black with a lifted grey plane, then maps luminance to a white glyph.
"""
import json, math, sys, numpy as np
from PIL import Image, ImageFilter, ImageDraw, ImageChops

D = "/Users/quentin/Desktop/Soma/Soma_Flight/assets/icon-set-v3/"
R = D + "raw/"
S = 1024
CORAL_A, CORAL_B = (255, 138, 76), (238, 78, 43)
ANGLE = -45  # nose up -> nose up-right


def clean(im, lo=60, hi=235):
    a = np.array(im.convert("RGBA"))
    al = a[..., 3].astype(float)
    a[..., 3] = (np.clip((al - lo) / (hi - lo), 0, 1) * 255).astype("uint8")
    return Image.fromarray(a)


def rot_pt(p, src_size, dst_size, ang=ANGLE):
    """Map a point of the source through PIL rotate(ang, expand=True)."""
    cx, cy = src_size[0] / 2, src_size[1] / 2
    t = math.radians(ang)
    x, y = p[0] - cx, p[1] - cy
    # PIL rotates counter-clockwise for positive angles (screen y down)
    xr = x * math.cos(t) + y * math.sin(t)
    yr = -x * math.sin(t) + y * math.cos(t)
    return xr + dst_size[0] / 2, yr + dst_size[1] / 2


def light(sprite, top=1.07, bottom=0.80):
    """Bias the symmetric render toward a top-left key light."""
    a = np.array(sprite).astype(float)
    h, w = a.shape[:2]
    yy, xx = np.mgrid[0:h, 0:w]
    t = ((xx / w) + (yy / h)) / 2  # 0 top-left .. 1 bottom-right
    g = top + (bottom - top) * np.clip((t - 0.2) / 0.6, 0, 1)
    # lift the mids so the chrome stays bright at 29 px, keep the dark reflections
    v = (a[..., :3] / 255) ** 0.78 * 255 * 1.04
    a[..., :3] = np.clip(v * g[..., None], 0, 255)
    return Image.fromarray(a.astype("uint8"))


def prep(name, lo=60, flames=False):
    src = clean(Image.open(R + name + ".png"), lo)
    a = np.array(src)[..., 3]
    ys, xs = np.nonzero(a > 128)
    pts = {}
    # wingtips: extreme left / right opaque points; tail: lowest point
    i, j = np.argmin(xs), np.argmax(xs)
    pts["port"], pts["stbd"] = (xs[i], ys[i]), (xs[j], ys[j])
    k = np.argmax(ys)
    pts["tail"] = (xs[k], ys[k])
    k = np.argmin(ys)
    pts["nose"] = (xs[k], ys[k])
    rot = src.rotate(ANGLE, expand=True, resample=Image.BICUBIC)
    pts = {n: rot_pt(p, src.size, rot.size) for n, p in pts.items()}
    bb = rot.getbbox()
    rot = rot.crop(bb)
    pts = {n: (p[0] - bb[0], p[1] - bb[1]) for n, p in pts.items()}
    return light(rot), pts


PLANE, PTS = prep("chrome-v2")
DELTA, DPTS = prep("delta-a", lo=90)


def lift(sprite, base=0.62):
    """Grey version of the plane for the tinted render: mostly flat, a little shading."""
    a = np.array(sprite).astype(float)
    lum = a[..., :3].mean(2) / 255
    v = (base + (1 - base) * lum) * 255
    a[..., 0] = a[..., 1] = a[..., 2] = v
    return Image.fromarray(a.astype("uint8"))


def place(sprite, pts, scale, center):
    w = int(S * scale)
    k = w / max(sprite.size)
    sp = sprite.resize((int(sprite.width * k), int(sprite.height * k)), Image.LANCZOS)
    pos = (int(center[0] - sp.width / 2), int(center[1] - sp.height / 2))
    p = {n: (pos[0] + x * k, pos[1] + y * k) for n, (x, y) in pts.items()}
    return sp, pos, p


# ---------- tile ----------
def squircle(size, inset=0, n=5.0):
    yy, xx = np.mgrid[0:size, 0:size]
    r = size / 2 - inset
    u = np.abs((xx - size / 2 + 0.5) / r)
    v = np.abs((yy - size / 2 + 0.5) / r)
    return Image.fromarray(((u ** n + v ** n) <= 1).astype("uint8") * 255)


def tile(mode, top=(44, 44, 48), bottom=(16, 16, 18), rim=0):
    if mode == "tint":
        return Image.new("RGB", (S, S), (0, 0, 0))
    if mode == "dark":
        top, bottom, rim = tuple(int(c * 0.55) for c in top), tuple(int(c * 0.45) for c in bottom), rim * 0.6
    t = np.linspace(0, 1, S)[:, None, None]
    g = np.array(top, float) * (1 - t) + np.array(bottom, float) * t
    # faint radial lift behind the subject, top-left key
    yy, xx = np.mgrid[0:S, 0:S]
    d = np.hypot(xx - 430, yy - 400) / 700
    g = np.repeat(g, S, axis=1) + (np.exp(-d ** 2 * 2) * 10)[..., None]
    im = Image.fromarray(np.clip(g, 0, 255).astype("uint8")).convert("RGB")
    if rim:
        outer = squircle(S, 0)
        inner = squircle(S, 8).filter(ImageFilter.GaussianBlur(10))
        ring = ImageChops.subtract(outer, inner).filter(ImageFilter.GaussianBlur(3))
        fall = np.linspace(1.0, 0.2, S)[:, None]
        ring = Image.fromarray((np.array(ring) * fall * rim).astype("uint8"))
        im = Image.composite(Image.new("RGB", (S, S), (255, 255, 255)), im, ring)
    return im


def glow(im, center, radius, color, strength):
    yy, xx = np.mgrid[0:S, 0:S]
    d = np.hypot(xx - center[0], yy - center[1]) / radius
    m = np.exp(-d ** 2 * 2.2) * strength
    a = np.array(im).astype(float)
    a = a * (1 - m[..., None]) + np.array(color, float) * m[..., None]
    return Image.fromarray(np.clip(a, 0, 255).astype("uint8"))


def add_glow(im, center, radius, color, strength):
    yy, xx = np.mgrid[0:S, 0:S]
    d = np.hypot(xx - center[0], yy - center[1]) / radius
    m = np.exp(-d ** 2 * 2.5) * strength
    a = np.array(im).astype(float) + np.array(color, float) * m[..., None]
    return Image.fromarray(np.clip(a, 0, 255).astype("uint8"))


def contact_shadow(im, sprite, pos, alpha=0.75, color=(0, 0, 0)):
    """Two-layer soft shadow, cast down-right from a top-left key."""
    a = sprite.split()[3]
    for off, blur, al in (((10, 16), 8, 0.55), ((26, 44), 34, 0.6)):
        sh = Image.new("L", (S, S), 0)
        sh.paste(a, (pos[0] + off[0], pos[1] + off[1]))
        sh = sh.filter(ImageFilter.GaussianBlur(blur)).point(lambda v, al=al: int(v * al * alpha))
        im = Image.composite(Image.new("RGB", (S, S), color), im, sh)
    return im


def put(im, sprite, pos):
    im = im.convert("RGBA")
    im.alpha_composite(sprite, (int(pos[0]), int(pos[1])))
    return im.convert("RGB")


def with_plane(bg, mode, scale=0.76, center=(512, 512), sprite=None, pts=None, shadow_color=(0, 0, 0)):
    sprite = sprite or PLANE
    pts = pts or PTS
    if mode == "tint":
        sprite = lift(sprite)
    sp, pos, p = place(sprite, pts, scale, center)
    if mode != "tint":
        bg = contact_shadow(bg, sp, pos, color=shadow_color)
    return put(bg, sp, pos), p


# ---------- icons ----------
def orbit_chrome(mode):
    im, _ = with_plane(tile(mode), mode)
    return im


def ember(mode):
    bg = tile(mode)
    s = 0.6 if mode == "tint" else (0.8 if mode == "dark" else 1.0)
    bg = glow(bg, (540, 560), 560, CORAL_B, 0.55 * s)
    bg = glow(bg, (540, 560), 320, CORAL_A, 0.5 * s)
    im, _ = with_plane(bg, mode, shadow_color=(80, 18, 6))
    return im


def redeye(mode):
    bg = tile(mode, top=(36, 37, 46), bottom=(12, 12, 17))
    im, p = with_plane(bg, mode)
    for n, c in (("port", (255, 38, 48)), ("stbd", (40, 255, 120))):
        x, y = p[n]
        if mode == "tint":
            c = (200, 200, 200)
        im = add_glow(im, (x, y), 120, c, 0.40)
        im = add_glow(im, (x, y), 30, c, 0.85)
        im = add_glow(im, (x, y), 12, (255, 255, 255), 0.55)
    return im


def sweep(mode):
    bg = tile(mode)
    c = (512, 512)
    yy, xx = np.mgrid[0:S, 0:S]
    r = np.hypot(xx - c[0], yy - c[1])
    disc_r = 440
    a = np.array(bg).astype(float)
    disc = np.clip((disc_r - r) / 3, 0, 1)
    rings = np.zeros_like(r)
    for rr in (150, 295, disc_r):
        rings = np.maximum(rings, np.exp(-((r - rr) / 1.8) ** 2))
    cross = (np.exp(-((xx - c[0]) / 1.2) ** 2) + np.exp(-((yy - c[1]) / 1.2) ** 2)) * disc * 0.5
    ang = (np.degrees(np.arctan2(yy - c[1], xx - c[0])) + 360) % 360
    lead = 300.0
    behind = (lead - ang) % 360
    beam = np.where(behind < 80, np.clip(1 - behind / 80, 0, 1) ** 2.0, 0) * disc
    col = np.array((255, 255, 255) if mode == "tint" else CORAL_A, float)
    k = 0.7 if mode == "dark" else 1.0
    a = a + (rings + cross)[..., None] * disc[..., None] * 40 * k
    a = a * (1 - beam[..., None] * 0.5 * k) + col * beam[..., None] * 0.5 * k
    edge = np.exp(-(((ang - lead + 180) % 360 - 180) / 0.5) ** 2) * disc * (r > 8)
    a = a + edge[..., None] * col * 0.7 * k
    bg = Image.fromarray(np.clip(a, 0, 255).astype("uint8"))
    for bx, by in ((250, 380), (760, 700), (690, 190)):
        bg = add_glow(bg, (bx, by), 14, tuple(col), 0.9 * k)
    im, _ = with_plane(bg, mode, scale=0.70)
    return im


def lastcall(mode):
    bg = tile(mode)
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
            if mode == "tint":
                top, bot, hl = ((200,) * 3, (170,) * 3, (230,) * 3) if coral else ((60,) * 3, (48,) * 3, (80,) * 3)
            else:
                top = (255, 146, 84) if coral else (58, 58, 63)
                bot = (236, 86, 46) if coral else (42, 42, 46)
                hl = (255, 196, 160) if coral else (88, 88, 94)
            ld.rounded_rectangle([x, y, x + tw, y + th // 2 - 3], 16, fill=top + (255,))
            ld.rounded_rectangle([x, y + th // 2 + 3, x + tw, y + th], 16, fill=bot + (255,))
            ld.line([x + 14, y + 2, x + tw - 14, y + 2], fill=hl + (255,), width=2)
    fade = np.clip((np.arange(S) - (rows_y[0] - 20)) / 220, 0, 1)
    la = np.array(lay)
    la[..., 3] = (la[..., 3] * (0.35 + 0.65 * fade[:, None])).astype("uint8")
    bg = put(bg, Image.fromarray(la), (0, 0))
    im, _ = with_plane(bg, mode, scale=0.66, center=(512, 395))
    return im


def spectrum(mode):
    bg = tile(mode)
    sp_scale, center = 0.62, (580, 440)
    sprite = lift(PLANE) if mode == "tint" else PLANE
    sp, pos, p = place(sprite, PTS, sp_scale, center)
    rib = clean(Image.open(R + "ribbon-prev.png"))
    a = np.array(rib).astype(float)
    rgb = a[..., :3] / 255
    sat = rgb.max(2) - rgb.min(2)
    al = a[..., 3] / 255
    keep = np.clip((al - 0.75) / 0.2, 0, 1) * np.clip((sat - 0.05) / 0.15 + (al > 0.97), 0, 1)
    a[..., 3] = np.array(Image.fromarray((keep * 255).astype("uint8")).filter(ImageFilter.GaussianBlur(0.8)))
    if mode == "tint":
        g = a[..., :3].mean(2) * 0.8
        a[..., 0] = a[..., 1] = a[..., 2] = g
    rib = Image.fromarray(a.astype("uint8"))
    rib = rib.crop(rib.getbbox()).rotate(-22, expand=True, resample=Image.BICUBIC)
    k = 0.66 * S / max(rib.size)
    rib = rib.resize((int(rib.width * k), int(rib.height * k)), Image.LANCZOS)
    ra = np.array(rib)[..., 3]
    ys, xs = np.nonzero(ra > 128)
    i = np.argmax(xs - ys)
    tx, ty = p["tail"]
    # tuck the ribbon end just under the tail cone
    rx, ry = int(tx - xs[i] + 14), int(ty - ys[i] - 14)
    if mode != "tint":
        bg = contact_shadow(bg, rib, (rx, ry), alpha=0.6)
    bg = put(bg, rib, (rx, ry))
    if mode != "tint":
        bg = contact_shadow(bg, sp, pos)
    return put(bg, sp, pos)


def mach(mode):
    bg = tile(mode, top=(40, 40, 45), bottom=(14, 14, 16))
    im, p = with_plane(bg, mode, scale=0.76, center=(524, 494), sprite=DELTA, pts=DPTS)
    # strengthen the afterburners along the jet axis behind the tail
    tx, ty = p["tail"]
    fl = (255, 255, 255) if mode == "tint" else (255, 120, 50)
    k = 0.5 if mode == "dark" else 0.7
    for t in np.linspace(0, 1, 14):
        im = add_glow(im, (tx - 60 * t, ty + 60 * t), 34 * (1 - 0.5 * t), fl, k * 0.18 * (1 - t))
    return im


def nightside(mode):
    bg = Image.open(R + "globe-prev.png").convert("RGB").resize((S, S), Image.LANCZOS)
    if mode == "dark":
        bg = Image.fromarray((np.array(bg) * 0.7).astype("uint8"))
    if mode == "tint":
        g = np.array(bg.convert("L")).astype(float)
        bg = Image.fromarray(np.clip((g - 30) * 2.2, 0, 255).astype("uint8")).convert("RGB")
    im, _ = with_plane(bg, mode, scale=0.66, center=(512, 410))
    return im


def tinted_of(im):
    g = np.array(im.convert("L")).astype(float) / 255
    t = np.clip((g - 0.04) / 0.9, 0, 1)
    return Image.fromarray((t * 255).astype("uint8")).convert("RGB")


NAMES = json.load(open(R + "src/names.json"))
MAKERS = {"orbit-chrome": orbit_chrome, "ember": ember, "redeye": redeye, "sweep": sweep,
          "lastcall": lastcall, "spectrum": spectrum, "mach": mach, "nightside": nightside}

if __name__ == "__main__":
    only = sys.argv[1:] or [n["slug"] for n in NAMES]
    for slug in only:
        f = MAKERS[slug]
        im = f("light")
        im.save(D + slug + ".png")
        f("dark").save(D + slug + "-dark.png")
        tinted_of(f("tint")).save(D + slug + "-tinted.png")
        for s in (180, 60, 29):
            im.resize((s, s), Image.LANCZOS).save(D + f"{slug}-{s}.png")
        print("built", slug)
    if not sys.argv[1:]:
        # standalone plane for empty states: ~1200 px long side, transparent
        k = 1200 / max(PLANE.size)
        PLANE.resize((round(PLANE.width * k), round(PLANE.height * k)), Image.LANCZOS).save(D + "plane-chrome.png")
        json.dump(NAMES, open(D + "names.json", "w"), indent=2, ensure_ascii=False)
