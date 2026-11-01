"""Contact sheet: light / dark / tinted at 300 px, then real home-screen sizes:
180 px (60 pt at 3x), 60 px and 29 px previews, each on a wallpaper-ish backdrop."""
import json
from PIL import Image, ImageDraw, ImageFont
from build import squircle, D, NAMES
def font(sz):
    try: return ImageFont.truetype("/System/Library/Fonts/SFNS.ttf", sz)
    except Exception: return ImageFont.load_default()
card = 300; rowh = card + 90
W = 40 + 3 * (card + 24) + 180 + 30 + 60 + 24 + 29 + 60
sheet = Image.new("RGB", (W, 160 + len(NAMES) * rowh), (8, 8, 9))
dr = ImageDraw.Draw(sheet)
dr.text((40, 40), "Soma Flight . icon set v4 (business jet)", fill=(255, 255, 255), font=font(44))
dr.text((40, 100), "light / dark / tinted, then 180 px (home screen at 3x), 60 and 29 px", fill=(130, 126, 122), font=font(22))
m = {s: squircle(s) for s in (card, 180, 60, 29)}
for i, n in enumerate(NAMES):
    slug = n["slug"]; y = 160 + i * rowh; x = 40
    for suf in ("", "-dark", "-tinted"):
        im = Image.open(D + slug + suf + ".png").resize((card, card), Image.LANCZOS)
        sheet.paste(im, (x, y), m[card]); x += card + 24
    for s in (180, 60, 29):
        im = Image.open(D + f"{slug}-{s}.png")
        sheet.paste(im, (x, y + card - s), m[s]); x += s + 24
    dr.text((40, y + card + 14), n["name"], fill=(255, 255, 255), font=font(30))
    dr.text((40 + dr.textlength(n["name"], font=font(30)) + 16, y + card + 21), f"{slug}  .  {n['tagline']}", fill=(190, 182, 176), font=font(21))
sheet.save(D + "sheet.png"); print(sheet.size)
