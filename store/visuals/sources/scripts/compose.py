"""Compose the store slides: real simulator screenshots in a drawn device frame over a photographic sky.
HTML in ../html, PNG (RGB, no alpha) rendered with Playwright headless Chromium at the exact ASC size.
Usage: python3 compose.py [set ...]   sets: iphone-69 iphone-63 ipad-13 mac"""
import json, sys, pathlib, io
from PIL import Image
from playwright.sync_api import sync_playwright

SRC = pathlib.Path(__file__).resolve().parent.parent          # store/visuals/sources
OUT = SRC.parent                                               # store/visuals
FONT = "file:///System/Library/Fonts/SFNS.ttf"
CHROME = str(pathlib.Path.home() / "Library/Caches/ms-playwright/chromium_headless_shell-1217/chrome-headless-shell-mac-arm64/chrome-headless-shell")

# Copy: English, short, contractions, no dashes, no "X, not Y", no Oxford comma, no invented stats.
PHONE = [
    ("01-home",      "home",          "Every flight, live",             "Times, gates and delays update on their own."),
    ("02-detail",    "detail-large",  "Know before the board",  "Delays, gates and baggage belts as they move."),
    ("03-search",    "search",        "Find any flight fast",           "Type a flight number, a route or an airport."),
    ("04-airport",   "airport",       "Every airport at a glance",      "Weather, FAA delays and runway closures."),
    ("05-passport",  "passport",      "Every trip you've taken",        "Your routes, distance and hours in the air."),
    ("06-record",    "passport-full", "A travel record to share",       "Flights, airports and countries on one card."),
    ("07-friends",   "friends",       "See your friends' flights",  "Share a link. You choose what they see."),
]

CSS = """
@font-face { font-family: SF; src: url(%(font)s); font-weight: 100 900; }
* { margin: 0; padding: 0; box-sizing: border-box; }
html, body { width: %(w)dpx; height: %(h)dpx; overflow: hidden; background: #050b1a; }
body { font-family: SF, -apple-system, sans-serif; color: #fff; position: relative;
       -webkit-font-smoothing: antialiased; }
.bg { position: absolute; inset: 0; background: url(%(bg)s) center bottom / cover no-repeat; }
.shade { position: absolute; inset: 0; background: linear-gradient(180deg, rgba(3,8,22,.55) 0%%, rgba(3,8,22,0) 30%%); }
.copy { position: absolute; left: 0; right: 0; text-align: center; }
h1 { font-weight: 640; letter-spacing: -0.022em; line-height: 1.04; }
p  { font-weight: 420; color: rgba(255,255,255,.72); letter-spacing: -0.005em; line-height: 1.25; }
.dev { position: absolute; background: #0a0a0b; }
.dev::before { content: ""; position: absolute; inset: 0; border-radius: inherit;
               box-shadow: inset 0 0 0 %(rim)spx #6b6d72, inset 0 0 0 %(rim2)spx #1b1c1e; pointer-events: none; z-index: 3; }
.dev .shadow { position: absolute; inset: 0; border-radius: inherit; z-index: -1;
               box-shadow: 0 %(sy)spx %(sb)spx rgba(0,0,0,.55), 0 %(sy2)spx %(sb2)spx rgba(0,0,0,.35); }
.dev img.scr { position: absolute; display: block; }
.island { position: absolute; background: #000; border-radius: 999px; z-index: 4; }
"""

def phone_html(shot, bg, title, sub, w, h, screen_px, pt):
    # Layout drawn for the 1320 x 2868 canvas, scaled with CSS zoom for the 6.3" size.
    z = w / 1320
    sw = 980                       # screen width on the canvas
    sh = round(sw * screen_px[1] / screen_px[0])
    bez = 26                       # bezel
    k = sw / screen_px[0]          # canvas px per screenshot px
    rad = 62 * pt * k              # display corner radius, 62 pt
    dw, dh = sw + 2 * bez, sh + 2 * bez
    left, top = (1320 - dw) / 2, 2868 - dh - 120
    isl_w, isl_h, isl_t = 125.3 * pt * k, 36.7 * pt * k, 14 * pt * k  # measured on a 17 Pro capture
    css = CSS % dict(font=FONT, w=1320, h=2868, bg=bg, rim=6, rim2=9, sy=60, sb=140, sy2=20, sb2=40)
    return f"""<!doctype html><html style="zoom:{z}"><head><meta charset="utf-8"><style>{css}</style></head><body>
<div class="bg"></div><div class="shade"></div>
<div class="copy" style="top:200px"><h1 style="font-size:106px">{title}</h1>
<p style="font-size:50px;margin-top:30px">{sub}</p></div>
<div class="dev" style="left:{left}px;top:{top}px;width:{dw}px;height:{dh}px;border-radius:{rad+bez}px"><div class="shadow"></div>
<img class="scr" src="{shot}" style="left:{bez}px;top:{bez}px;width:{sw}px;height:{sh}px;border-radius:{rad}px">
<div class="island" style="left:{bez + (sw-isl_w)/2}px;top:{bez+isl_t}px;width:{isl_w}px;height:{isl_h}px"></div></div>
</body></html>"""

def render(page_html, name, w, h, out_png, page):
    html_path = SRC / "html" / f"{name}.html"
    html_path.write_text(page_html)
    page.set_viewport_size({"width": w, "height": h})
    page.goto(html_path.as_uri())
    page.wait_for_load_state("networkidle")
    page.evaluate("document.fonts.ready")
    png = page.screenshot(type="png", full_page=False)
    Image.open(io.BytesIO(png)).convert("RGB").save(out_png, optimize=True)
    print(out_png, Image.open(out_png).size)

def run(sets):
    with sync_playwright() as p:
        b = p.chromium.launch(executable_path=CHROME)  # cached shell; the pip package wants another revision
        page = b.new_page(device_scale_factor=1)
        for s in sets:
            if s in ("iphone-69", "iphone-63"):
                w, h = (1320, 2868) if s == "iphone-69" else (1206, 2622)
                (OUT / s).mkdir(exist_ok=True)
                for fname, key, title, sub in PHONE:
                    shot = SRC / "raw" / s / f"{key}.png"
                    if not shot.exists():
                        print("missing", shot); continue
                    im = Image.open(shot)
                    html = phone_html(shot.as_uri(), (SRC / "bg" / "dusk-portrait.png").as_uri(), title, sub, w, h, im.size, 3)
                    render(html, f"{s}-{fname}", w, h, OUT / s / f"{fname}.png", page)
            else:
                import compose_wide
                compose_wide.run(s, page, render)
        b.close()

if __name__ == "__main__":
    run(sys.argv[1:] or ["iphone-69", "iphone-63"])
