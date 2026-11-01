"""raw/finishes.png: white vs silver, on the charcoal tile and in the empty-state context."""
import sys; sys.argv = ["build.py"]
import numpy as np
from PIL import Image, ImageDraw, ImageFont
import build as B
f = lambda s: ImageFont.truetype("/System/Library/Fonts/SFNS.ttf", s)
C = 520
def empty_state(sprite):
    S = B.S
    bg = Image.new("RGB", (S, S), (0x1C, 0x1C, 0x1E))
    bg = B.glow(bg, (512, 560), 520, B.CORAL_B, 0.30)
    bg = B.glow(bg, (512, 560), 260, B.CORAL_A, 0.22)
    sp, pos, _ = B.place(sprite, {}, 0.62, (512, 500))
    bg = B.contact_shadow(bg, sp, pos, alpha=0.6, color=(40, 10, 4))
    return B.put(bg, sp, pos)
out = Image.new("RGB", (40 + 4 * (C + 24), 200 + C + 70), (8, 8, 9)); d = ImageDraw.Draw(out)
d.text((40, 36), "Finish: glossy white vs brushed silver", fill=(255, 255, 255), font=f(40))
d.text((40, 96), "app tile on charcoal, then the empty state (#1C1C1E with a coral glow)", fill=(150, 146, 142), font=f(22))
m = B.squircle(C); x = 40
for fin in ("white", "silver"):
    sp, pts = B.PLANES[fin]
    tile = B.tile("light")
    sp_, pos, _ = B.place(sp, pts, 0.76, (512, 512)); tile = B.put(B.contact_shadow(tile, sp_, pos), sp_, pos)
    out.paste(tile.resize((C, C), Image.LANCZOS), (x, 160), m)
    d.text((x, 160 + C + 16), f"{fin}, tile", fill=(220, 214, 208), font=f(24)); x += C + 24
for fin in ("white", "silver"):
    out.paste(empty_state(B.PLANES[fin][0]).resize((C, C), Image.LANCZOS), (x, 160))
    d.text((x, 160 + C + 16), f"{fin}, empty state", fill=(220, 214, 208), font=f(24)); x += C + 24
out.save(B.R + "finishes.png"); print(out.size)
