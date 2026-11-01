#!/usr/bin/env python3
"""Measures and straightens the fuselage of the generated side views in aircraft-art/ai.

The image model draws from photos, so some aircraft come out pitched or bowed: the crown line climbs or
falls along the cabin, or bends at the wing, and on a phone the aircraft reads as a banana. Our own
vector blueprint of the same type (aircraft-art/blueprint/<TYPE>.png, same 3200x1400 template, built
from published dimensions) is taken as the truth for the crown.

Crown: the top edge of the body (alpha > 200, after clean_cutouts.clean) in two windows of the length,
16-40% (forward barrel) and 50-72% (aft barrel, before the fin). Wings, winglets and the fin only ever
rise above the crown, so each window keeps its lower envelope. A quadratic in x/length goes through both
windows, for the side view and for the blueprint; their difference, once its mean is taken off, is the
bow. Reported per image:
  dev   largest bow over the whole length (the difference continued linearly beyond the windows),
        in % of the length
  tilt  pitch of the crown against the blueprint's, degrees (+ = nose up)
  bend  change of the crown's slope from the forward to the aft window against the blueprint's, degrees

Straightening shifts each column of pixels vertically by minus the bow, so the crown takes the
blueprint's line; wings, engines and the fin move with their columns and stay attached (at a degree or
two the shear on the fin is invisible). The original goes to aircraft-art/ai/bent/ (the bundler skips
subfolders), the fixed image takes its place.

Usage:
  straighten_side_views.py measure OUT.json [art]         measure every side view
  straighten_side_views.py fix LIST [art]                 straighten the pairs in LIST (one AAA-TYPE per line)
Needs numpy, scipy, Pillow; imports clean_cutouts.py next to this script.
"""
import json, os, re, shutil, sys
from multiprocessing import Pool
import numpy as np
from PIL import Image

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from clean_cutouts import clean  # noqa: E402

here = os.path.dirname(os.path.abspath(__file__))
ART = os.path.join(here, "../../../aircraft-art")
NAME = re.compile(r"^([A-Z0-9]{3})-([A-Z0-9]{2,4})\.png$")
WINDOWS = ((0.16, 0.40), (0.50, 0.72))


def crown(alpha):
    """Normalised crown samples (u = x/length from the nose, v = y/length) and the body's x extent."""
    m = alpha > 200
    has = m.any(0)
    cols = np.where(has)[0]
    x0, x1 = int(cols[0]), int(cols[-1])
    L = float(x1 - x0)
    top = np.where(has, m.argmax(0), 10**6).astype(float)
    us, vs = [], []
    for lo, hi in WINDOWS:
        xs = np.arange(int(x0 + lo * L), int(x0 + hi * L))
        ys = top[xs]
        for _ in range(12):  # lower envelope
            p = np.polyfit(xs, ys, 1)
            k = ys - np.polyval(p, xs) >= -1.5 * L / 3000
            if k.all() or k.sum() < 20:
                break
            xs, ys = xs[k], ys[k]
        p = np.polyfit(xs, ys, 1)
        k = np.abs(ys - np.polyval(p, xs)) < 3 * L / 3000
        us.append((xs[k] - x0) / L)
        vs.append(ys[k] / L)
    return x0, L, us, vs


def fit(us, vs):
    u, v = np.concatenate(us), np.concatenate(vs)
    return np.polyfit(u, v, 2), float(u.min()), float(u.max()), [np.polyfit(a, b, 1)[0] for a, b in zip(us, vs)]


def extend(p, lo, hi, u):
    """The quadratic inside [lo, hi], continued along its tangent outside."""
    d = np.polyder(p)
    c = np.clip(u, lo, hi)
    return np.polyval(p, c) + np.where(u < lo, (u - lo) * np.polyval(d, lo), 0) + np.where(u > hi, (u - hi) * np.polyval(d, hi), 0)


_truth = {}


def truth(art, typ):
    if typ not in _truth:
        a = np.asarray(Image.open(os.path.join(art, "blueprint", f"{typ}.png")).convert("RGBA"))[:, :, 3]
        _truth[typ] = fit(*crown(a)[2:])
    return _truth[typ]


def bow(art, typ, alpha):
    """Bow function over u (normalised, mean over [0, 1] removed) and the summary numbers."""
    x0, L, us, vs = crown(alpha)
    pa, lo, hi, (sf, sa) = fit(us, vs)
    pb, blo, bhi, (bf, ba) = truth(art, typ)
    lo, hi = max(lo, blo), min(hi, bhi)
    grid = np.linspace(0, 1, 201)
    diff = extend(pa, lo, hi, grid) - extend(pb, lo, hi, grid)
    diff -= diff.mean()
    slope_a = np.polyval(np.polyder(pa), (lo + hi) / 2)
    slope_b = np.polyval(np.polyder(pb), (lo + hi) / 2)
    stats = dict(dev=float(100 * np.abs(diff).max()),
                 tilt=float(np.degrees(np.arctan(slope_a) - np.arctan(slope_b))),
                 bend=float(np.degrees((np.arctan(sa) - np.arctan(sf)) - (np.arctan(ba) - np.arctan(bf)))))
    return (pa, pb, lo, hi, x0, L), stats


def measure(args):
    art, f = args
    typ = NAME.match(f)[2]
    try:
        rgba = clean(np.array(Image.open(os.path.join(art, "ai", f)).convert("RGBA")))
        return f, bow(art, typ, rgba[:, :, 3])[1]
    except Exception as e:  # noqa: BLE001
        return f, {"error": str(e)}


def shift_columns(rgba, shift):
    """Moves column c down by shift[c] pixels (premultiplied, linear interpolation), canvas kept."""
    H, W = rgba.shape[:2]
    pad = int(np.ceil(np.abs(shift).max())) + 2
    src = np.zeros((H + 2 * pad, W, 4), np.float32)
    src[pad:pad + H] = rgba
    src[:, :, :3] *= src[:, :, 3:4] / 255.0
    out = np.zeros_like(src)
    yy = np.arange(H + 2 * pad, dtype=np.float32)
    for c in np.where(rgba[:, :, 3].any(0))[0]:
        for ch in range(4):
            out[:, c, ch] = np.interp(yy - shift[c], yy, src[:, c, ch], left=0, right=0)
    a = out[:, :, 3:4]
    rgb = np.where(a > 0, out[:, :, :3] * 255.0 / np.maximum(a, 1e-3), 0)
    res = np.concatenate([np.clip(rgb + 0.5, 0, 255), np.clip(a + 0.5, 0, 255)], 2).astype(np.uint8)
    return res[pad:pad + H]  # the template's canvas; the nose is pinned, so nothing leaves it


def straighten(art, f):
    typ = NAME.match(f)[2]
    path = os.path.join(art, "ai", f)
    im = np.array(Image.open(path).convert("RGBA"))
    (pa, pb, lo, hi, x0, L), before = bow(art, typ, clean(im.copy())[:, :, 3])
    u = (np.arange(im.shape[1]) - x0) / L
    grid = np.linspace(0, 1, 201)
    mean = (extend(pa, lo, hi, grid) - extend(pb, lo, hi, grid)).mean()
    diff = extend(pa, lo, hi, u) - extend(pb, lo, hi, u) - mean
    # Pin the nose: the template puts the nose tip at y = 1000, keep it there.
    diff -= diff[min(max(x0, 0), len(diff) - 1)]
    fixed = shift_columns(im, -diff * L)
    after = bow(art, typ, clean(fixed.copy())[:, :, 3])[1]
    bent = os.path.join(art, "ai", "bent")
    os.makedirs(bent, exist_ok=True)
    if not os.path.exists(os.path.join(bent, f)):
        shutil.copy2(path, os.path.join(bent, f))
    Image.fromarray(fixed).save(path)
    return f, before, after


def _straighten(args):
    try:
        return straighten(*args)
    except Exception as e:  # noqa: BLE001
        return args[1], {"error": str(e)}, None


if __name__ == "__main__":
    if len(sys.argv) < 3 or sys.argv[1] not in ("measure", "fix"):
        sys.exit(__doc__)
    art = os.path.abspath(sys.argv[3] if len(sys.argv) > 3 else ART)
    if sys.argv[1] == "measure":
        files = sorted(f for f in os.listdir(os.path.join(art, "ai")) if NAME.match(f))
        with Pool() as pool:
            res = dict(pool.map(measure, [(art, f) for f in files], chunksize=4))
        with open(sys.argv[2], "w") as fh:
            json.dump(res, fh, indent=0)
        print(len(res), "measured")
    else:
        pairs = [p.strip() for p in open(sys.argv[2]) if p.strip()]
        with Pool() as pool:
            for f, before, after in pool.imap_unordered(_straighten, [(art, p + ".png") for p in pairs]):
                print(f, json.dumps(before), "->", json.dumps(after), flush=True)
