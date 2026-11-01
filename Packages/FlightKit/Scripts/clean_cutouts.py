#!/usr/bin/env python3
"""Cleans the cutout of a generated side view: no halo, no mist, no specks, edges on the real body.

The gpt-image side views in aircraft-art/ai come with a soft white mist around the aircraft
(semi-transparent white that rises to alpha ~240 right against the fuselage, sometimes a visible
cloud over the nose), a 1% see-through body (alpha ~252 instead of 255) and stray specks. On a
coloured or dark background that reads as a whitish halo. The fuselage itself is mostly white, so
colour alone can't tell paint from mist. The step works on the alpha channel as a two-layer matte:

1. Mist level. The mist is smooth, so its alpha at any pixel near the body is estimated from the
   pixels around it that are certainly not body (alpha under MIST_TOP and more than a pixel away from
   anything opaque), by normalised Gaussian averaging. Far from any mist this is ~0.
2. Body coverage. Seen through the model's eyes a pixel is body over mist: A = B + M (1 - B), scaled
   to the body's own level. So B = (A - M) / (level - M). Mist alone gives B ~ 0, the body gives 1,
   and the drawn edge keeps its antialiasing, now without the mist added on top.
3. The body is B >= 1/2, with small enclosed holes filled. Thin parts (antennas, blade tips) and
   dark or coloured parts drawn semi-transparent (wipers, beacons, gear doors) that touch it are kept
   with their own coverage: they are narrow ridges or not pale, which the mist never is.
4. Only the main aircraft and parts near it survive: components far from it and smaller than a real
   part are dropped (specks, the noise left in the mist).
5. The edge is rebuilt at 4x from the coverage field, its staircase smoothed and lightly feathered,
   and averaged back; inside the body alpha is 255.
6. Edge colour is decontaminated: rim pixels take the colour of the nearest body pixel a pixel
   inside, so no white from the mist bleeds into the rim.

Usage as a module: clean(rgba uint8 HxWx4) -> rgba uint8. As a script:
  python3 clean_cutouts.py in.png out.png
Needs numpy, scipy and Pillow.
"""
import sys
import numpy as np
from PIL import Image
from scipy import ndimage as ndi

OPAQUE = 240        # alpha that only the body reaches (body ~252, mist mostly under ~235)
MIST_TOP = 235      # pixels under this, a pixel or more away from OPAQUE, sample the mist
MIST_SIGMA = 2.5    # mist sampling radius, in pixels
NOTCH = 5           # notches up to this radius are closed again
STEEP = 100         # alpha drop within 3 px that marks a drawn edge rather than mist
DARK_MIN = 0.43     # a dark or coloured semi-transparent part must reach this coverage
DARK_LUM = 190      # "dark": luminance under this (the mist is ~240 grey-white)
DARK_SAT = 0.25     # "coloured": saturation over this
THIN_MIN = 0.28     # a thin part must reach this coverage
THIN_TOPHAT = 0.22  # and stand this much above its 5 px opening
SS = 4              # edge supersampling
TUFT_RADIUS = 6     # pale bumps of dense mist narrower than twice this are taken off
TUFT_LUM = 225      # a tuft is this pale on average
GLOW_LUM = 238      # dense mist is this bright, the paint at the body's edge darker
PEEL = 6            # at most this many pixels of it are peeled off the rim
SMOOTH = 1.0        # contour smoothing radius, in pixels
FEATHER = 0.5       # edge feather, in pixels


def _components(mask):
    lab, n = ndi.label(mask, structure=np.ones((3, 3), bool))
    if n == 0:
        return mask
    areas = ndi.sum(mask, lab, index=np.arange(1, n + 1))
    main = int(np.argmax(areas)) + 1
    main_area = areas[main - 1]
    near = ndi.binary_dilation(lab == main, iterations=4)
    keep = np.zeros(n + 1, bool)
    keep[main] = True
    touching = np.unique(lab[near & (lab > 0)])
    for i in range(1, n + 1):
        a = areas[i - 1]
        if a >= 0.01 * main_area:
            keep[i] = True          # a real part on its own (engine, separate blade)
        elif i in touching and a >= 6:
            keep[i] = True          # a small part right next to the body
    return keep[lab]


def _fill_small_holes(mask, max_area):
    holes = ndi.binary_fill_holes(mask) & ~mask
    lab, n = ndi.label(holes)
    if n == 0:
        return mask
    areas = ndi.sum(holes, lab, index=np.arange(1, n + 1))
    small = np.zeros(n + 1, bool)
    small[1:] = areas <= max_area
    return mask | small[lab]


def coverage(A):
    """Body coverage 0..1 with the mist taken out, and the body's own alpha level."""
    hist = np.bincount(A[A >= 200].astype(np.int64), minlength=256)
    level = float(np.argmax(hist)) if hist.any() else 255.0
    # Mist fades out slowly; a pixel within 3 px of a steep drop to transparency is the edge of a
    # part the model drew semi-transparent (a fin cap, a fairing), not mist, and is not sampled.
    steep = (A - ndi.minimum_filter(A, size=7)) > STEEP
    sample = (A < MIST_TOP) & ~steep & ~ndi.binary_dilation(A >= OPAQUE, iterations=1)
    # and mist always fades out to nothing somewhere: a patch that never does (walled in by the
    # body and a drawn edge) is part of the aircraft.
    lab, n = ndi.label(sample, structure=np.ones((3, 3), bool))
    if n:
        fades = np.zeros(n + 1, bool)
        fades[np.unique(lab[sample & (A < 20)])] = True
        fades[0] = False
        sample &= fades[lab]
    sample = sample.astype(np.float32)
    num = ndi.gaussian_filter(A * sample, MIST_SIGMA)
    den = ndi.gaussian_filter(sample, MIST_SIGMA)
    M = np.where(den > 0.05, num / np.maximum(den, 1e-6), 0.0)
    M = np.minimum(M, level - 8)
    B = np.clip((A - M) / (level - M), 0.0, 1.0)
    return B.astype(np.float32), level


def clean(rgba):
    rgba = np.asarray(rgba)
    H, W = rgba.shape[:2]
    a = rgba[..., 3].astype(np.float32)

    # Work inside the box of anything visible, with a margin.
    ys, xs = np.nonzero(a > 0)
    if len(ys) == 0:
        return rgba.copy()
    pad = 8
    y0, y1 = max(0, ys.min() - pad), min(H, ys.max() + pad + 1)
    x0, x1 = max(0, xs.min() - pad), min(W, xs.max() + pad + 1)
    A = a[y0:y1, x0:x1]
    C = rgba[y0:y1, x0:x1, :3]

    B, level = coverage(A)
    rgbf = C.astype(np.float32)
    lum = 0.2126 * rgbf[..., 0] + 0.7152 * rgbf[..., 1] + 0.0722 * rgbf[..., 2]
    mx, mn = rgbf.max(axis=2), rgbf.min(axis=2)
    sat = (mx - mn) / np.maximum(mx, 1)

    core = _fill_small_holes(B >= 0.5, 400)
    # Bites: where a semi-transparent part touches real mist, the mist estimate can take a small
    # notch out of it. Close notches up to NOTCH px, only with pixels the model drew fairly opaque.
    nd = np.hypot(*np.mgrid[-NOTCH:NOTCH + 1, -NOTCH:NOTCH + 1]) <= NOTCH
    q = NOTCH + 1
    core |= ndi.binary_closing(np.pad(core, q), structure=nd)[q:-q, q:-q] & (A >= 150)

    # Dense mist that reached the cut sits on the body as a band brighter than the paint under
    # it: the renders shade the fuselage towards its edge and draw a darker outline, while the mist
    # is near pure white. Peel such pixels off the rim where there is mist around, then close the
    # dents the peel may leave (closing fills dents, never bumps, only with pixels that were body).
    outside = (~core).astype(np.float32)
    around = ndi.uniform_filter(A * outside, 13) / np.maximum(ndi.uniform_filter(outside, 13), 1e-3)
    glow = (lum >= GLOW_LUM) & (sat < 0.06) & (A < level - 1) & (around > 60)
    before = core.copy()
    for _ in range(PEEL):
        drop = core & ~ndi.binary_erosion(core) & glow
        if not drop.any():
            break
        core &= ~drop
    cdisk = np.hypot(*np.mgrid[-3:4, -3:4]) <= 3.0
    core |= ndi.binary_closing(np.pad(core, 4), structure=cdisk)[4:-4, 4:-4] & before

    # Tufts: where the mist is so dense it reaches the cut (alpha ~240-250, so there is no mist
    # left around it to sample) it stays on the body as a pale bump. A bump narrower than
    # TUFT_RADIUS * 2 that is pale and not drawn at the body's own level is mist; real bumps
    # (antennas, winglets, fin tips, a beacon) are opaque or not pale.
    disk = np.hypot(*np.mgrid[-TUFT_RADIUS:TUFT_RADIUS + 1, -TUFT_RADIUS:TUFT_RADIUS + 1]) <= TUFT_RADIUS
    p = TUFT_RADIUS + 1
    opened = ndi.binary_opening(np.pad(core, p), structure=disk)[p:-p, p:-p]
    bumps, nb = ndi.label(core & ~opened, structure=np.ones((3, 3), bool))
    if nb:
        idx = np.arange(1, nb + 1)
        med_a = ndi.median(A, bumps, idx)
        mean_l = ndi.mean(lum, bumps, idx)
        mean_s = ndi.mean(sat, bumps, idx)
        drop = np.zeros(nb + 1, bool)
        drop[1:] = (med_a < level - 1.5) & (mean_l > TUFT_LUM) & (mean_s < 0.10)
        core &= ~drop[bumps]
        core = ndi.binary_opening(core, structure=np.ones((2, 2), bool)) | (core & opened)

    # Thin parts: narrow coverage ridges; dark or coloured semi-transparent parts. Both must touch
    # the body.
    tophat = B - ndi.grey_opening(B, size=(5, 5))
    thin = (B >= THIN_MIN) & (tophat >= THIN_TOPHAT) & ~core
    thin |= (B >= DARK_MIN) & ((lum < DARK_LUM) | (sat > DARK_SAT)) & ~core
    tl, tn = ndi.label(thin, structure=np.ones((3, 3), bool))
    if tn:
        touch = np.unique(tl[ndi.binary_dilation(core, iterations=1) & (tl > 0)])
        thin = np.isin(tl, touch[touch > 0])

    body = _components(core | thin)
    core &= body
    thin &= body

    # Edge: the coverage next to the body (nothing further out), at 4x, cut at half, staircase
    # smoothed, lightly feathered, averaged back to pixels.
    size = (A.shape[1] * SS, A.shape[0] * SS)
    near = ndi.binary_dilation(core, iterations=2)
    F = np.where(core, 1.0, np.where(near, B, 0.0)).astype(np.float32)
    hi = np.array(Image.fromarray(F).resize(size, Image.BICUBIC)) >= 0.5
    hi = ndi.gaussian_filter(hi.astype(np.float32), SMOOTH * SS) >= 0.5
    hi = ndi.gaussian_filter(hi.astype(np.float32), FEATHER * SS)
    soft = hi.reshape(A.shape[0], SS, A.shape[1], SS).mean(axis=(1, 3))
    alpha = soft * 255.0
    alpha[ndi.binary_erosion(core, iterations=2)] = 255.0
    alpha = np.where(thin, np.maximum(alpha, B * 255.0), alpha)
    alpha = np.clip(np.round(alpha), 0, 255).astype(np.uint8)

    # Colour: rim pixels take the nearest inner body colour.
    inner = ndi.binary_erosion(core, iterations=1)
    if not inner.any():
        inner = core
    _, (iy, ix) = ndi.distance_transform_edt(~inner, return_indices=True)
    out_rgb = C[iy, ix]
    own = inner | thin
    out_rgb = np.where(own[..., None], C, out_rgb)
    out_rgb[alpha == 0] = 0

    out = np.zeros_like(rgba)
    out[y0:y1, x0:x1, :3] = out_rgb
    out[y0:y1, x0:x1, 3] = alpha
    return out


def clean_image(im):
    return Image.fromarray(clean(np.array(im.convert("RGBA"))))


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    clean_image(Image.open(sys.argv[1])).save(sys.argv[2])
