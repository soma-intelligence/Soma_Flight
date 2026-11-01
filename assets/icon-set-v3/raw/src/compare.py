"""raw/compare.png: reference tile vs ours, plus silhouettes overlaid at the same size."""
import numpy as np
from PIL import Image, ImageDraw, ImageFont
D = "/Users/quentin/Desktop/Soma/Soma_Flight/assets/icon-set-v3/"
REF = "/private/tmp/claude-501/-Users-quentin-Desktop-Soma/0af5a008-9882-4886-a712-efb5c5b0783e/images/7.png"
f = lambda s: ImageFont.truetype("/System/Library/Fonts/SFNS.ttf", s)
ref = Image.open(REF).convert("RGB").crop((14, 30, 113, 129)).resize((480, 480), Image.LANCZOS)
ours = Image.open(D + "orbit-chrome.png").resize((480, 480), Image.LANCZOS)
def sil(im, thr):
    g = np.array(im.convert("L")).astype(float)
    return g > thr
rs, os_ = sil(ref, 120), sil(ours, 110)
ov = np.full((480, 480, 3), 18, "uint8")
ov[rs & ~os_] = (255, 120, 70); ov[os_ & ~rs] = (90, 180, 255); ov[rs & os_] = (230, 230, 230)
W = 40 + 3 * 520
out = Image.new("RGB", (W, 640), (8, 8, 9)); d = ImageDraw.Draw(out)
for i, (im, t) in enumerate(((ref, "Reference (competitor, upscaled from screenshot)"), (ours, "Soma Flight v3: orbit-chrome"),
                             (Image.fromarray(ov), "Silhouettes: orange = reference only, blue = ours only"))):
    out.paste(im, (40 + i * 520, 110)); d.text((40 + i * 520, 610 - 10), t, fill=(200, 196, 190), font=f(18))
d.text((40, 36), "Silhouette check: our widebody vs the reference", fill=(255, 255, 255), font=f(36))
out.save(D + "raw/compare.png"); print(out.size, "overlap IoU", round((rs & os_).sum() / (rs | os_).sum(), 3))
