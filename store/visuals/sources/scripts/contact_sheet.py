"""One PNG with every slide, row by set, for review."""
import glob, pathlib
from PIL import Image, ImageDraw, ImageFont
OUT = pathlib.Path(__file__).resolve().parent.parent.parent
rows = [("iPhone 6.9 (1320 x 2868)", "iphone-69", 700), ("iPhone 6.3 (1206 x 2622)", "iphone-63", 700),
        ("iPad 13 (2064 x 2752)", "ipad-13", 700), ("Mac (2880 x 1800)", "mac", 560), ("README hero (2400 x 1200)", "hero", 560)]
font = ImageFont.truetype("/System/Library/Fonts/SFNS.ttf", 34)
pad, label = 40, 60
built = []
for title, d, h in rows:
    files = [OUT / "readme-hero.png"] if d == "hero" else sorted((OUT / d).glob("*.png"))
    ims = [Image.open(f).convert("RGB") for f in files]
    ims = [i.resize((round(i.width * h / i.height), h), Image.LANCZOS) for i in ims]
    built.append((title, ims, h))
W = max(sum(i.width for i in ims) + pad * (len(ims) + 1) for _, ims, _ in built)
H = sum(h + label + pad for _, _, h in built) + pad
sheet = Image.new("RGB", (W, H), (245, 245, 247)); dr = ImageDraw.Draw(sheet); y = pad
for title, ims, h in built:
    dr.text((pad, y), title, fill=(29, 29, 31), font=font); y += label; x = pad
    for i in ims:
        sheet.paste(i, (x, y)); x += i.width + pad
    y += h + pad
sheet.save(OUT / "contact-sheet.png", optimize=True); print(sheet.size)
