"""iPad, Mac, README hero and contact sheet layouts; called from compose.py with its Playwright page and render()."""
import pathlib
from PIL import Image
from compose import SRC, OUT, CSS, FONT

IPAD = [
    ("01-home",     "home",     "Every flight, live",          "Times, gates and delays update on their own."),
    ("02-detail",   "detail",   "Know before the board",  "Delays, gates and baggage belts as they move."),
    ("03-airport",  "airport",  "Every airport at a glance",   "Weather, FAA delays and runway closures."),
    ("04-passport", "passport", "Every trip you've taken",     "Your routes, distance and hours in the air."),
    ("05-friends",  "friends",  "See your friends' flights",  "Share a link. You choose what they see."),
]
MAC = [
    ("01-home",     "home",     "Every flight, live",          "Times, gates and delays update on their own."),
    ("02-detail",   "detail",   "Know before the board",  "Delays, gates and baggage belts as they move."),
    ("03-friends",  "friends",  "See your friends' flights",  "Share a link. You choose what they see."),
]

def head(w, h, bg):
    return CSS % dict(font=FONT, w=w, h=h, bg=bg, rim=7, rim2=11, sy=70, sb=160, sy2=24, sb2=48)

def ipad_html(shot, size, title, sub):
    W, H = 2064, 2752
    sw = 1580; sh = round(sw * size[1] / size[0]); bez = 44
    k = sw / size[0]; rad = 18 * 2 * k * 1.6
    dw, dh = sw + 2 * bez, sh + 2 * bez
    left, top = (W - dw) / 2, H - dh - 120
    bg = (SRC / "bg" / "dusk-portrait.png").as_uri()
    return f"""<!doctype html><html><head><meta charset="utf-8"><style>{head(W, H, bg)}</style></head><body>
<div class="bg"></div><div class="shade"></div>
<div class="copy" style="top:150px"><h1 style="font-size:128px">{title}</h1>
<p style="font-size:58px;margin-top:30px">{sub}</p></div>
<div class="dev" style="left:{left}px;top:{top}px;width:{dw}px;height:{dh}px;border-radius:{rad+bez}px"><div class="shadow"></div>
<img class="scr" src="{shot}" style="left:{bez}px;top:{bez}px;width:{sw}px;height:{sh}px;border-radius:{rad}px"></div>
</body></html>"""

def mac_html(shot, size, title, sub):
    W, H = 2880, 1800
    top = 340; mh = H - top - 56
    mw = round(mh * size[0] / size[1])
    left = (W - mw) / 2
    bg = (SRC / "bg" / "dusk-landscape.png").as_uri()
    return f"""<!doctype html><html><head><meta charset="utf-8"><style>{head(W, H, bg)}
.win {{ position:absolute; filter: drop-shadow(0 40px 70px rgba(0,0,0,.55)) drop-shadow(0 10px 20px rgba(0,0,0,.35)); }}</style></head><body>
<div class="bg"></div><div class="shade"></div>
<div class="copy" style="top:84px"><h1 style="font-size:104px">{title}</h1>
<p style="font-size:50px;margin-top:20px">{sub}</p></div>
<img class="win" src="{shot}" style="left:{left}px;top:{top}px;width:{mw}px;height:{mh}px">
</body></html>"""

def run(s, page, render):
    if s == "hero":
        return hero(page, render)
    if s == "ipad-13":
        (OUT / s).mkdir(exist_ok=True)
        for fname, key, t, sub in IPAD:
            shot = SRC / "raw" / s / f"{key}.png"
            if not shot.exists(): print("missing", shot); continue
            render(ipad_html(shot.as_uri(), Image.open(shot).size, t, sub), f"{s}-{fname}", 2064, 2752, OUT / s / f"{fname}.png", page)
    elif s == "mac":
        (OUT / s).mkdir(exist_ok=True)
        for fname, key, t, sub in MAC:
            shot = SRC / "raw" / s / f"{key}.png"
            if not shot.exists(): print("missing", shot); continue
            render(mac_html(shot.as_uri(), Image.open(shot).size, t, sub), f"{s}-{fname}", 2880, 1800, OUT / s / f"{fname}.png", page)


def phone_block(shot, size, x, y, sw):
    """A drawn iPhone at (x, y) with screen width sw on the hero canvas."""
    k = sw / size[0]; pt = 3; bez = round(sw * 0.026)
    sh = round(sw * size[1] / size[0]); rad = 62 * pt * k
    iw, ih, it = 125.3 * pt * k, 36.7 * pt * k, 14 * pt * k
    return (f'<div class="dev" style="left:{x}px;top:{y}px;width:{sw+2*bez}px;height:{sh+2*bez}px;border-radius:{rad+bez}px">'
            f'<div class="shadow"></div><img class="scr" src="{shot}" style="left:{bez}px;top:{bez}px;width:{sw}px;height:{sh}px;border-radius:{rad}px">'
            f'<div class="island" style="left:{bez+(sw-iw)/2}px;top:{bez+it}px;width:{iw}px;height:{ih}px"></div></div>')

def hero(page, render):
    W, H = 2400, 1200
    mac = SRC / "raw" / "mac" / "home.png"; ms = Image.open(mac).size
    mh = 900; mw = round(mh * ms[0] / ms[1])
    p1 = SRC / "raw" / "iphone-69" / "detail-large.png"; p2 = SRC / "raw" / "iphone-69" / "passport.png"
    ps = Image.open(p1).size
    bg = (SRC / "bg" / "dusk-landscape.png").as_uri()
    css = CSS % dict(font=FONT, w=W, h=H, bg=bg, rim=4, rim2=6, sy=40, sb=90, sy2=12, sb2=28)
    html = f"""<!doctype html><html><head><meta charset="utf-8"><style>{css}
.win {{ position:absolute; filter: drop-shadow(0 30px 50px rgba(0,0,0,.55)) drop-shadow(0 8px 16px rgba(0,0,0,.35)); }}
.shade {{ background: linear-gradient(180deg, rgba(3,8,22,.35), rgba(3,8,22,0) 40%); }}</style></head><body>
<div class="bg"></div><div class="shade"></div>
<img class="win" src="{mac.as_uri()}" style="left:224px;top:150px;width:{mw}px;height:{mh}px">
{phone_block(p2.as_uri(), ps, 1334, 190, 400)}
{phone_block(p1.as_uri(), ps, 1734, 140, 420)}
</body></html>"""
    render(html, "readme-hero", W, H, OUT / "readme-hero.png", page)
