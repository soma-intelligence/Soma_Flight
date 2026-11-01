import json
from PIL import Image, ImageDraw, ImageFont
from build import NAMES, squircle, D
json.dump([dict(slug=a, name=b, tagline=c) for a, b, c in NAMES], open(D + "names.json", "w"), indent=2)
def font(sz):
    try: return ImageFont.truetype("/System/Library/Fonts/SFNS.ttf", sz)
    except Exception: return ImageFont.load_default()
card = 420; W = 40 + 3 * (card + 30) + 200; rowh = card + 100
sheet = Image.new("RGB", (W, 150 + len(NAMES) * rowh), (8, 8, 9))
dr = ImageDraw.Draw(sheet)
dr.text((40, 40), "Soma Flight . alternate icons (abstract set)", fill=(255, 255, 255), font=font(44))
dr.text((40, 98), "light / dark / tinted, then 60 and 29 pt previews", fill=(120, 116, 112), font=font(22))
m = {s: squircle(s) for s in (card, 60, 29)}
for i, (slug, name, tag) in enumerate(NAMES):
    y = 150 + i * rowh; x = 40
    for suf in ("", "-dark", "-tinted"):
        im = Image.open(D + slug + suf + ".png").resize((card, card), Image.LANCZOS)
        sheet.paste(im, (x, y), m[card]); x += card + 30
    for s in (60, 29):
        im = Image.open(D + f"{slug}-{s}.png")
        sheet.paste(im, (x, y + card - s), m[s]); x += s + 24
    dr.text((40, y + card + 16), name, fill=(255, 255, 255), font=font(34))
    dr.text((40 + dr.textlength(name, font=font(34)) + 20, y + card + 24), f"{slug}  .  {tag}", fill=(190, 182, 176), font=font(24))
sheet.save(D + "sheet.png"); print(sheet.size)
