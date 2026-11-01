"""Soma Flight icon options, Airbnb-like design language (own mark).

Writes SVG + PNG (1024 light, dark, tinted, 60 and 29 previews) per option,
and a contact sheet options.png.
"""
import subprocess, pathlib, math
from PIL import Image

OUT = pathlib.Path("/Users/quentin/Desktop/Soma/Soma_Flight/assets/icon-airbnb-style")
TMP = pathlib.Path(__file__).parent / "tmp"
TMP.mkdir(exist_ok=True)
CHROME = str(pathlib.Path.home() / "Library/Caches/ms-playwright/chromium_headless_shell-1217/chrome-headless-shell-mac-arm64/chrome-headless-shell")

# Our warm tone: "Ember", an orange-coral, warmer and more orange than Airbnb Rausch.
EMBER_HI, EMBER, EMBER_LO = "#FF8A4C", "#FF6A3D", "#EE4E2B"
WHITE = "#FFFFFF"
DARK_BG = "#14110F"

DEFS = f"""<defs>
<linearGradient id="ember" x1="0" y1="0" x2="1" y2="1">
<stop offset="0" stop-color="{EMBER_HI}"/><stop offset="1" stop-color="{EMBER_LO}"/></linearGradient>
<linearGradient id="emberU" gradientUnits="userSpaceOnUse" x1="200" y1="200" x2="824" y2="824">
<stop offset="0" stop-color="{EMBER_HI}"/><stop offset="1" stop-color="{EMBER_LO}"/></linearGradient>
<linearGradient id="darkbg" x1="0" y1="0" x2="0" y2="1">
<stop offset="0" stop-color="#211C19"/><stop offset="1" stop-color="#0E0C0B"/></linearGradient>
</defs>"""


def stroke(d, col, w, extra=""):
    return f'<path d="{d}" fill="none" stroke="{col}" stroke-width="{w}" stroke-linecap="round" stroke-linejoin="round" {extra}/>'


# ---------- A: contrail loop -------------------------------------------------
def glyph_a(col):
    # one stroke: takes off low left, loops once, climbs to a plane dot top right
    d = ("M 214 744 C 330 744 452 700 540 604 "
         "C 628 508 640 392 560 360 C 474 326 400 420 452 506 "
         "C 504 592 650 560 724 470 C 770 414 792 360 806 312")
    return stroke(d, col, 84) + plane_shape(820, 236, 20, 0.40, col)


def plane_head(x, y, ang, col, s):
    # a tiny friendly arrow-plane: rounded triangle at the end of the trail
    pts = [(0, -110), (78, 46), (0, 18), (-78, 46)]
    a = math.radians(ang + 90)
    def tr(p):
        px, py = p[0] * s, p[1] * s
        return (x + px * math.cos(a) - py * math.sin(a), y + px * math.sin(a) + py * math.cos(a))
    p = [tr(q) for q in pts]
    d = "M " + " L ".join(f"{u:.1f} {v:.1f}" for u, v in p) + " Z"
    return f'<path d="{d}" fill="{col}" stroke="{col}" stroke-width="44" stroke-linejoin="round"/>'


# ---------- B: orbit over a globe -------------------------------------------
def glyph_b(col, bg_is_paint=True):
    cx, cy, r = 512, 590, 206
    R = 318
    def P(t):
        t = math.radians(t); return cx + R*math.cos(t), cy + R*math.sin(t)
    (x0, y0), (x1, y1) = P(200), P(322)
    arc = f"M {x0:.1f} {y0:.1f} A {R} {R} 0 0 1 {x1:.1f} {y1:.1f}"
    globe = f'<circle cx="{cx}" cy="{cy}" r="{r}" fill="none" stroke="{col}" stroke-width="64"/>' \
            f'<ellipse cx="{cx}" cy="{cy}" rx="78" ry="{r}" fill="none" stroke="{col}" stroke-width="52"/>'
    return globe + stroke(arc, col, 64) + f'<circle cx="{x1:.1f}" cy="{y1:.1f}" r="64" fill="{col}"/>'

def plane_shape(cx, cy, deg, sc, col, sw=70):
    half = [(0, -330), (46, -282), (52, -90), (300, 40), (300, 92), (52, 40),
            (44, 196), (128, 262), (128, 300), (0, 270)]
    full = half + [(-x, y) for x, y in reversed(half[1:-1])]
    a = math.radians(deg)
    pts = [(cx + sc*(x * math.cos(a) - y * math.sin(a)), cy + sc*(x * math.sin(a) + y * math.cos(a))) for x, y in full]
    d = "M " + " L ".join(f"{u:.1f} {v:.1f}" for u, v in pts) + " Z"
    return f'<path d="{d}" fill="{col}" stroke="{col}" stroke-width="{sw*sc:.1f}" stroke-linejoin="round"/>'


# ---------- C: soft chunky plane --------------------------------------------
def glyph_c(col):
    # top view, nose up, built as one closed outline rounded by a fat join
    half = [(0, -330), (46, -282), (52, -90), (300, 40), (300, 92), (52, 40),
            (44, 196), (128, 262), (128, 300), (0, 270)]
    full = half + [(-x, y) for x, y in reversed(half[1:-1])]
    a = math.radians(45)
    pts = [(512 + x * math.cos(a) - y * math.sin(a), 520 + x * math.sin(a) + y * math.cos(a)) for x, y in full]
    d = "M " + " L ".join(f"{u:.1f} {v:.1f}" for u, v in pts) + " Z"
    return f'<path d="{d}" fill="{col}" stroke="{col}" stroke-width="70" stroke-linejoin="round"/>'


# ---------- D: Soma wings (four arms, open centre, plus the dot) -------------
def glyph_d(col):
    a = math.radians(45)
    def T(x, y):
        return (512 + x * math.cos(a) - y * math.sin(a) - 20, 540 + x * math.sin(a) + y * math.cos(a) + 20)
    segs = [
        [(0, -110), (0, -300)],                 # nose
        [(-92, 24), (-280, 112)],               # left wing, swept back
        [(92, 24), (280, 112)],                 # right wing
        [(0, 128), (0, 236)],                   # tail
    ]
    out = ""
    for s in segs:
        p = [T(*q) for q in s]
        out += stroke(f"M {p[0][0]:.1f} {p[0][1]:.1f} L {p[1][0]:.1f} {p[1][1]:.1f}", col, 108)
    dx, dy = T(0, -440)
    out += f'<circle cx="{dx:.1f}" cy="{dy:.1f}" r="60" fill="{col}"/>'
    return out


OPTIONS = {
    "A": dict(name="Contrail loop", glyph=glyph_a, light_bg=WHITE, light_fg="url(#emberU)"),
    "B": dict(name="Orbit globe", glyph=glyph_b, light_bg="url(#ember)", light_fg=WHITE),
    "C": dict(name="Soft plane", glyph=glyph_c, light_bg=WHITE, light_fg="url(#emberU)"),
    "D": dict(name="Soma wings", glyph=glyph_d, light_bg="url(#ember)", light_fg=WHITE),
}


def svg(bg, glyph):
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">'
            f'{DEFS}<rect width="1024" height="1024" fill="{bg}"/>{glyph}</svg>')


from playwright.sync_api import sync_playwright
_pw = sync_playwright().start()
_br = _pw.chromium.launch(executable_path=CHROME, args=["--disable-gpu"])


def shot(url, path, w, h, transparent=True):
    pg = _br.new_page(viewport={"width": w, "height": h})
    pg.goto(url, timeout=60000)
    pg.wait_for_load_state("load")
    pg.screenshot(path=str(path), omit_background=transparent, timeout=60000)
    pg.close()


def run_chrome(args):
    for _ in range(4):
        try:
            subprocess.run([CHROME, "--headless", "--no-sandbox", "--disable-gpu"] + args, check=True, capture_output=True, timeout=20)
            return
        except subprocess.TimeoutExpired:
            subprocess.run(["pkill", "-f", "chrome-headless-shell"])
    raise RuntimeError(args)


def render(svg_path, png_path, size):
    html = TMP / (svg_path.stem + f"_{size}.html")
    html.write_text(f'<html><body style="margin:0;background:transparent">'
                    f'<img src="file://{svg_path}" width="{size}" height="{size}" style="display:block"></body></html>')
    shot(f"file://{html}", png_path, size, size)
    im = Image.open(png_path).convert("RGB")  # opaque, no alpha (App Store rule)
    im.save(png_path)


def main():
    import sys
    only = sys.argv[1:] or list(OPTIONS)
    for k, o in OPTIONS.items():
        if k not in only: continue
        base = f"option-{k.lower()}"
        variants = {
            "": svg(o["light_bg"], o["glyph"](o["light_fg"])),
            "-dark": svg("url(#darkbg)", o["glyph"]("url(#emberU)")),
            "-tinted": svg("#000000", o["glyph"]("#FFFFFF")),
        }
        for suf, s in variants.items():
            p = OUT / f"{base}{suf}.svg"
            p.write_text(s)
            render(p, OUT / f"{base}{suf}.png", 1024)
        light = OUT / f"{base}.svg"
        for sz in (60, 29):
            render(light, OUT / f"{base}-{sz}.png", sz)
    sheet()


def sheet():
    W = 2400
    cards = ""
    for k, o in OPTIONS.items():
        b = f"option-{k.lower()}"
        cards += f"""<div class="card"><div class="lab">{k}<span>{o['name']}</span></div>
<img class="big" src="{b}.png">
<div class="row"><img class="v" src="{b}-dark.png"><img class="v" src="{b}-tinted.png">
<div class="sm"><img src="{b}-60.png" style="width:60px;height:60px;border-radius:13.4px">
<img src="{b}-29.png" style="width:29px;height:29px;border-radius:6.5px"></div></div>
<div class="cap"><span>dark</span><span>tinted</span><span>60 / 29 px</span></div></div>"""
    html = OUT / "_sheet.html"
    html.write_text(f"""<html><head><style>
body{{margin:0;background:#F4F1EE;font-family:-apple-system,'SF Pro Display',Helvetica,sans-serif;width:{W}px}}
.wrap{{display:flex;gap:40px;padding:60px 60px 50px}}
.card{{flex:1;min-width:0;box-sizing:border-box;background:#fff;border-radius:36px;padding:32px;box-shadow:0 2px 14px rgba(0,0,0,.06)}}
.lab{{font-size:56px;font-weight:700;color:#222;margin-bottom:24px}}
.lab span{{font-size:28px;font-weight:500;color:#888;margin-left:18px}}
.big{{width:100%;aspect-ratio:1;border-radius:22.37%;display:block;box-shadow:0 8px 30px rgba(0,0,0,.12)}}
.row{{display:flex;align-items:center;gap:22px;margin-top:28px}}
.sm{{background:#ECE8E4;border-radius:22px;padding:24px 22px;height:102px;box-sizing:border-box;align-items:center!important}}
.v{{width:150px;height:150px;border-radius:33.5px}}
.sm{{display:flex;align-items:flex-end;gap:16px;margin-left:8px}}
.cap{{display:flex;gap:22px;font-size:20px;color:#999;margin-top:10px}}
.cap span{{width:150px}}
</style></head><body><div class="wrap">{cards}</div></body></html>""")
    shot(f"file://{html}", OUT / "options.png", W, 950, transparent=False)
    html.unlink()


if __name__ == "__main__":
    main()
