import numpy as np
from PIL import Image, ImageFilter
S = 1024
def spectrum_icon(bg, rib, j, pos, tail):
    from build import shadow, put
    a = np.array(rib).astype(float)
    rgb = a[..., :3] / 255
    sat = rgb.max(2) - rgb.min(2)
    al = a[..., 3] / 255
    # drop the soft white halo: keep opaque or coloured pixels only
    keep = np.clip((al - 0.75) / 0.2, 0, 1) * np.clip((sat - 0.05) / 0.15 + (al > 0.97), 0, 1)
    a[..., 3] = np.array(Image.fromarray((keep * 255).astype("uint8")).filter(ImageFilter.GaussianBlur(0.8)))
    rib = Image.fromarray(a.astype("uint8"))
    rib = rib.crop(rib.getbbox())
    # ribbon end points up; the jet's tail trails toward the lower left (heading 45 deg) -> rotate 45 deg clockwise
    rib = rib.rotate(-22, expand=True, resample=Image.BICUBIC)
    k = 0.62 * S / max(rib.size)
    rib = rib.resize((int(rib.width * k), int(rib.height * k)), Image.LANCZOS)
    ra = np.array(rib)[..., 3]
    ys, xs = np.nonzero(ra > 128)
    # the free end is the point furthest up-right
    i = np.argmax(xs - ys)
    ex, ey = xs[i], ys[i]
    rx, ry = int(tail[0] - ex + 10), int(tail[1] - ey - 10)
    bg = shadow(bg, rib, (rx, ry), off=(10, 22), blur=20, alpha=0.5)
    bg = put(bg, rib, (rx, ry))
    bg = shadow(bg, j, pos, off=(18, 34), blur=26, alpha=0.6)
    return put(bg, j, pos)
