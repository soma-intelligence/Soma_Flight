"""Blueprint app icons: the icon's jet as a technical line drawing on blueprint blue.

    python3 assets/app-icon/blueprint.py raw/icon-climb-1.png out.png [--rotate 8 --scale 0.89 --nudge 0,6] [--tint]

The lines are traced from the render (outline and the panel, engine and window edges, as vector polylines
simplified with Douglas-Peucker) and stroked at 4x with antialiasing, then scaled down, so they stay crisp at
29 pt. Around them: a fine grid, the fuselage centre line in dash-dot, a dimension line with slash ticks under
the aircraft (nose to tail) and its extension lines, in the colours of the Aircraft Stats blueprint (BlueprintPlan.swift).
--tint draws the same lines on black for the tinted icon.
"""
import math, pathlib, sys
import cv2
import numpy as np
from PIL import Image

import build as B

HERE = pathlib.Path(__file__).resolve().parent
S, K = 1024, 4  # icon size, supersampling
TOP, BOTTOM = (0x35, 0x74, 0xC6), (0x24, 0x5A, 0xA6)  # around Theme.blueprint #2F6BBA
INK = (0xF4, 0xF8, 0xFC)


def arg(name, default):
    return sys.argv[sys.argv.index(name) + 1] if name in sys.argv else default


def place(sprite, scale, nudge):
    """The sprite at its icon size and position (the same geometry as the photographic icon)."""
    w = int(S * scale)
    k = w / max(sprite.size)
    sp = sprite.resize((round(sprite.width * k), round(sprite.height * k)), Image.LANCZOS)
    pos = (int(S / 2 - sp.width / 2 + nudge[0]), int(S / 2 - sp.height / 2 + nudge[1]))
    full = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    full.alpha_composite(sp, pos)
    return full


def trace(full):
    """Vector polylines in icon pixels: the outline, the inner edges and the windows."""
    big = full.resize((S * 2, S * 2), Image.LANCZOS)
    a = np.array(big)
    alpha = a[..., 3]
    lum = cv2.cvtColor(a[..., :3], cv2.COLOR_RGB2GRAY)
    mask = (alpha > 128).astype(np.uint8) * 255
    outline, _ = cv2.findContours(mask, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_NONE)
    outline = [cv2.approxPolyDP(c, 1.2, True) for c in outline if cv2.arcLength(c, True) > 200]
    inner = cv2.erode(mask, np.ones((9, 9), np.uint8))
    blur = cv2.GaussianBlur(lum, (5, 5), 1.4)
    edges = cv2.Canny(blur, 40, 110)
    edges[inner == 0] = 0
    edges = cv2.dilate(edges, np.ones((2, 2), np.uint8))
    cs, _ = cv2.findContours(edges, cv2.RETR_LIST, cv2.CHAIN_APPROX_NONE)
    details = [cv2.approxPolyDP(c, 2.2, False) for c in cs if cv2.arcLength(c, False) > 90]
    dark = ((lum < 90) & (inner > 0)).astype(np.uint8) * 255
    ws, _ = cv2.findContours(dark, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
    windows = [c for c in ws if 12 < cv2.contourArea(c) < 2500]
    half = lambda cs: [c.astype(np.float32) / 2 for c in cs]
    return half(outline), half(details), half(windows), mask


def axis(mask):
    """The aircraft's long axis (principal component of its pixels) and its extent along it, in icon pixels."""
    ys, xs = np.nonzero(mask)
    pts = np.stack([xs, ys], 1).astype(float) / 2
    c = pts.mean(0)
    q = pts - c
    cov = np.array([[np.mean(q[:, 0] * q[:, 0]), np.mean(q[:, 0] * q[:, 1])],
                    [np.mean(q[:, 0] * q[:, 1]), np.mean(q[:, 1] * q[:, 1])]])
    w, v = np.linalg.eigh(cov)
    d = v[:, 1] if v[0, 1] > 0 else -v[:, 1]
    t = q[:, 0] * d[0] + q[:, 1] * d[1]
    n = np.array([-d[1], d[0]])
    if n[1] < 0:
        n = -n
    u = q[:, 0] * n[0] + q[:, 1] * n[1]
    return c, d, n, t.min(), t.max(), u.max()


def draw(full, tint=False):
    outline, details, windows, mask = trace(full)
    W = S * K
    if tint:
        img = np.zeros((W, W, 3), np.uint8)
    else:
        img = np.array(B.ground(TOP, BOTTOM).resize((W, W), Image.BICUBIC))
    ink = (255, 255, 255) if tint else INK
    lay = np.zeros_like(img)

    def blend(layer, alpha):
        nonlocal img
        m = (layer.max(2, keepdims=True) > 0)
        img = np.where(m, (img * (1 - alpha) + layer * alpha).astype(np.uint8), img)

    def line(p, q, w, alpha=1.0):
        layer = np.zeros_like(img)
        cv2.line(layer, tuple(int(v * K) for v in p), tuple(int(v * K) for v in q), ink, int(w * K), cv2.LINE_AA)
        blend(layer, alpha)

    # grid: minor every 32 px, major every 128
    for step, w, al in ((32, 1.2, 0.10), (128, 2.0, 0.20)):
        layer = np.zeros_like(img)
        for v in range(0, S + 1, step):
            cv2.line(layer, (v * K, 0), (v * K, W), ink, int(w * K), cv2.LINE_AA)
            cv2.line(layer, (0, v * K), (W, v * K), ink, int(w * K), cv2.LINE_AA)
        blend(layer, al)

    c, d, n, t0, t1, u1 = axis(mask)
    # centre line, dash-dot, past nose and tail
    seg = [(18, 1), (6, 0), (4, 1), (6, 0)]
    t, i = t0 - 60, 0
    layer = np.zeros_like(img)
    while t < t1 + 60:
        ln, on = seg[i % 4]
        if on:
            p, q = c + d * t, c + d * min(t + ln, t1 + 60)
            cv2.line(layer, tuple((p * K).astype(int)), tuple((q * K).astype(int)), ink, int(2 * K), cv2.LINE_AA)
        t += ln; i += 1
    blend(layer, 0.45)
    # dimension line under the aircraft (its overall length, nose to tail), with extension lines and slash ticks
    ys, xs = np.nonzero(mask)
    x0, x1, y1 = xs.min() / 2, xs.max() / 2, ys.max() / 2
    yd = min(y1 + 44, S - 70)
    line((x0, yd), (x1, yd), 2.2, 0.75)
    for x in (x0, x1):
        col = mask[:, int(x * 2)]
        top = np.nonzero(col)[0]
        y_from = (top.max() / 2 + 14) if len(top) else yd - 60
        line((x, y_from), (x, yd + 16), 1.6, 0.45)
        line((x - 12, yd + 12), (x + 12, yd - 12), 2.6, 0.9)
    # the aircraft: a faint fill, the outline, the inner edges and the windows
    fill = np.zeros_like(img)
    cv2.fillPoly(fill, [(o * K).astype(np.int32) for o in outline], ink, cv2.LINE_AA)
    blend(fill, 0.13)
    layer = np.zeros_like(img)
    cv2.polylines(layer, [(o * K).astype(np.int32) for o in details], False, ink, int(3.0 * K), cv2.LINE_AA)
    blend(layer, 0.7)
    layer = np.zeros_like(img)
    cv2.polylines(layer, [(o * K).astype(np.int32) for o in windows], True, ink, int(2.6 * K), cv2.LINE_AA)
    blend(layer, 0.85)
    layer = np.zeros_like(img)
    cv2.polylines(layer, [(o * K).astype(np.int32) for o in outline], True, ink, int(6.5 * K), cv2.LINE_AA)
    blend(layer, 1.0)
    return Image.fromarray(img).resize((S, S), Image.LANCZOS)


def blueprint(sprite, scale, nudge, tint=False):
    return draw(place(sprite, scale, nudge), tint)


if __name__ == "__main__":
    src = HERE / sys.argv[1]
    sp = B.clean(Image.open(src))
    rot = float(arg("--rotate", "0"))
    if rot:
        sp = sp.rotate(rot, expand=True, resample=Image.BICUBIC)
        sp = sp.crop(sp.getbbox())
    nudge = tuple(int(v) for v in arg("--nudge", "0,0").split(","))
    im = blueprint(sp, float(arg("--scale", "0.89")), nudge, "--tint" in sys.argv)
    im.save(sys.argv[2])
    print(sys.argv[2])
