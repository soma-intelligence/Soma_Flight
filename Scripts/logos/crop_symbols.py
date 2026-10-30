#!/usr/bin/env python3
"""Airline symbols cropped out of the Commons logos (Task 8d).

    python3 -I Scripts/logos/crop_symbols.py            build every crop in crops.json
    python3 -I Scripts/logos/crop_symbols.py --inspect AFR
                                                        list the drawn elements of AFR's logo: index path,
                                                        tag, fill, bounding box (to write a crop spec)

Many airlines only have their symbol inside the full logo on Commons (Air France's stripe left of the name,
Air Canada's roundel, the Swiss flag...). This script takes those files from assets/logos/commons (already
licence-checked by fetch_commons.py) and keeps only the symbol, as spelled out per airline in
assets/logos/commons/crops.json:

    SVG  "keep": the index paths of the elements that draw the symbol (child positions from the root,
         "1/0/3" = 4th child of the 1st child of the 2nd child). Every other drawn element is removed; defs,
         styles, gradients, clip paths and masks stay. The viewBox is then set tight around what is left
         (exact Bezier extrema, every transform, clip paths, half the stroke width). Path data, colours and
         transforms are not touched: nothing is redrawn, recoloured or scaled.
    PNG  "box": [x, y, w, h] in source pixels. Cropped as is, never scaled up: refused when the crop is
         under 192 px on its long side.

Every spec carries the source's sha256: a source that changed is refused until someone looks again.
Airlines whose symbol cannot be cleanly separated are listed under "skipped" with the reason.

Output, beside the Commons symbols of Task 8c (an airline that already has one is never overridden):
    symbol/<ICAO>.svg|png    the cropped symbol
    symbol/png/<ICAO>.png    192 px on the longest side, transparent (headless Chromium through <img>)
    manifest.json            "symbols"[ICAO]: kind "symbol", method "crop", derived_from (the source file),
                             licence, author and attribution inherited from the source logo
    Packages/FlightKit/Sources/FlightKit/Resources/Licenses/airline-logos.json
                             the app's credit list, rewritten from the manifest (crops credit their source)

The files are parsed as XML data only: nothing in them is run, no external entity is loaded. Deterministic:
the same sources and spec give the same SVG bytes. Run after fetch_commons.py (which runs this at its end).
"""
from __future__ import annotations

import argparse
import hashlib
import io
import json
import math
import re
import struct
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
COMMONS = ROOT / "assets/logos/commons"
SPEC = COMMONS / "crops.json"
APP_ATTRIBUTION = ROOT / "Packages/FlightKit/Sources/FlightKit/Resources/Licenses/airline-logos.json"
CHROME_GLOB = "chromium_headless_shell-*/chrome-headless-shell-mac-arm64/chrome-headless-shell"
PX = 192

SVG_NS = "http://www.w3.org/2000/svg"
XLINK_NS = "http://www.w3.org/1999/xlink"
SHAPES = {"path", "rect", "circle", "ellipse", "line", "polyline", "polygon", "use", "image", "text"}
CONTAINERS = {"svg", "g", "a", "switch"}
# Never drawn directly: kept whatever the spec says (they only matter through references).
NON_RENDERING = {"defs", "style", "title", "desc", "metadata", "namedview", "clipPath", "mask",
                 "linearGradient", "radialGradient", "pattern", "filter", "marker", "symbol", "font",
                 "font-face", "script"}


def local(tag) -> str:
    return tag.split("}")[-1] if isinstance(tag, str) else ""


# ---------------------------------------------------------------- geometry

Matrix = tuple  # (a, b, c, d, e, f): x' = a x + c y + e, y' = b x + d y + f
IDENTITY = (1.0, 0.0, 0.0, 1.0, 0.0, 0.0)
NUM = r"[-+]?(?:\d*\.\d+|\d+\.?)(?:[eE][-+]?\d+)?"


def mul(m: Matrix, n: Matrix) -> Matrix:
    """The matrix of applying n first, then m."""
    a, b, c, d, e, f = m
    A, B, C, D, E, F = n
    return (a * A + c * B, b * A + d * B, a * C + c * D, b * C + d * D, a * E + c * F + e, b * E + d * F + f)


def apply(m: Matrix, x: float, y: float):
    return m[0] * x + m[2] * y + m[4], m[1] * x + m[3] * y + m[5]


def parse_transform(s: str | None) -> Matrix:
    m = IDENTITY
    for name, args in re.findall(r"(matrix|translate|scale|rotate|skewX|skewY)\s*\(([^)]*)\)", s or ""):
        v = [float(x) for x in re.findall(NUM, args)]
        if name == "matrix" and len(v) == 6:
            t = tuple(v)
        elif name == "translate":
            t = (1, 0, 0, 1, v[0], v[1] if len(v) > 1 else 0)
        elif name == "scale":
            t = (v[0], 0, 0, v[1] if len(v) > 1 else v[0], 0, 0)
        elif name == "rotate":
            r = math.radians(v[0])
            t = (math.cos(r), math.sin(r), -math.sin(r), math.cos(r), 0, 0)
            if len(v) == 3:
                t = mul(mul((1, 0, 0, 1, v[1], v[2]), t), (1, 0, 0, 1, -v[1], -v[2]))
        elif name == "skewX":
            t = (1, 0, math.tan(math.radians(v[0])), 1, 0, 0)
        elif name == "skewY":
            t = (1, math.tan(math.radians(v[0])), 0, 1, 0, 0)
        else:
            raise ValueError(f"bad transform {name}({args})")
        m = mul(m, t)
    return m


class Box:
    def __init__(self):
        self.x0 = self.y0 = math.inf
        self.x1 = self.y1 = -math.inf

    def add(self, x, y):
        self.x0, self.y0 = min(self.x0, x), min(self.y0, y)
        self.x1, self.y1 = max(self.x1, x), max(self.y1, y)

    def merge(self, o: "Box"):
        if not o.empty():
            self.add(o.x0, o.y0)
            self.add(o.x1, o.y1)

    def empty(self):
        return self.x0 > self.x1

    def grow(self, d):
        if not self.empty():
            self.x0, self.y0, self.x1, self.y1 = self.x0 - d, self.y0 - d, self.x1 + d, self.y1 + d

    def clip(self, o: "Box"):
        if o.empty() or self.empty():
            return
        self.x0, self.y0 = max(self.x0, o.x0), max(self.y0, o.y0)
        self.x1, self.y1 = min(self.x1, o.x1), min(self.y1, o.y1)

    def tup(self):
        return (self.x0, self.y0, self.x1, self.y1)


def _roots(a, b, c):
    """Real roots in (0, 1) of a t^2 + b t + c."""
    if abs(a) < 1e-12:
        return [-c / b] if abs(b) > 1e-12 and 0 < -c / b < 1 else []
    disc = b * b - 4 * a * c
    if disc < 0:
        return []
    s = math.sqrt(disc)
    return [t for t in ((-b + s) / (2 * a), (-b - s) / (2 * a)) if 0 < t < 1]


def cubic_box(box: Box, m: Matrix, p0, p1, p2, p3):
    """Exact: an affine map of a Bezier is the Bezier of the mapped control points."""
    q = [apply(m, *p) for p in (p0, p1, p2, p3)]
    box.add(*q[0])
    box.add(*q[3])
    for k in (0, 1):
        a0, a1, a2, a3 = (p[k] for p in q)
        ts = _roots(3 * (-a0 + 3 * a1 - 3 * a2 + a3), 6 * (a0 - 2 * a1 + a2), 3 * (a1 - a0))
        for t in ts:
            u = 1 - t
            x = u ** 3 * q[0][0] + 3 * u * u * t * q[1][0] + 3 * u * t * t * q[2][0] + t ** 3 * q[3][0]
            y = u ** 3 * q[0][1] + 3 * u * u * t * q[1][1] + 3 * u * t * t * q[2][1] + t ** 3 * q[3][1]
            box.add(x, y)


def arc_points(p0, rx, ry, phi, large, sweep, p1, n=96):
    """Endpoint arc (SVG F.6.5) sampled into points."""
    x1, y1 = p0
    x2, y2 = p1
    if (x1, y1) == (x2, y2):
        return []
    rx, ry = abs(rx), abs(ry)
    if rx == 0 or ry == 0:
        return [p1]
    cp, sp = math.cos(math.radians(phi)), math.sin(math.radians(phi))
    dx, dy = (x1 - x2) / 2, (y1 - y2) / 2
    xp, yp = cp * dx + sp * dy, -sp * dx + cp * dy
    lam = xp * xp / (rx * rx) + yp * yp / (ry * ry)
    if lam > 1:
        rx, ry = rx * math.sqrt(lam), ry * math.sqrt(lam)
    num = rx * rx * ry * ry - rx * rx * yp * yp - ry * ry * xp * xp
    den = rx * rx * yp * yp + ry * ry * xp * xp
    co = math.sqrt(max(0.0, num / den)) if den else 0.0
    if large == sweep:
        co = -co
    cxp, cyp = co * rx * yp / ry, -co * ry * xp / rx
    cx, cy = cp * cxp - sp * cyp + (x1 + x2) / 2, sp * cxp + cp * cyp + (y1 + y2) / 2

    def ang(ux, uy, vx, vy):
        a = math.atan2(ux * vy - uy * vx, ux * vx + uy * vy)
        return a

    t1 = ang(1, 0, (xp - cxp) / rx, (yp - cyp) / ry)
    dt = ang((xp - cxp) / rx, (yp - cyp) / ry, (-xp - cxp) / rx, (-yp - cyp) / ry)
    if not sweep and dt > 0:
        dt -= 2 * math.pi
    elif sweep and dt < 0:
        dt += 2 * math.pi
    out = []
    for i in range(1, n + 1):
        t = t1 + dt * i / n
        out.append((cx + rx * math.cos(t) * cp - ry * math.sin(t) * sp,
                    cy + rx * math.cos(t) * sp + ry * math.sin(t) * cp))
    return out


ARGS = {"M": 2, "L": 2, "H": 1, "V": 1, "C": 6, "S": 4, "Q": 4, "T": 2, "A": 7, "Z": 0}


def path_tokens(d: str):
    i, n = 0, len(d)
    num = re.compile(NUM)
    while i < n:
        ch = d[i]
        if ch.isspace() or ch == ",":
            i += 1
        elif ch.isalpha():
            yield ch
            i += 1
        else:
            m = num.match(d, i)
            if not m:
                raise ValueError(f"bad path data near {d[i:i + 20]!r}")
            yield m.group(0)
            i = m.end()


def path_box(d: str, m: Matrix) -> Box:
    box = Box()
    toks = list(path_tokens(d))
    i = 0
    cur = start = (0.0, 0.0)
    last_c = last_q = None
    cmd = None

    def flag_split():
        # Arc flags can be written run together ("011"): split a numeric token into single digits.
        nonlocal toks, i
        t = toks[i]
        if len(t) > 1 and t[0] in "01" and not t.startswith(("0.", "1.")):
            toks[i:i + 1] = [t[0], t[1:]]

    while i < len(toks):
        t = toks[i]
        if t.isalpha():
            cmd = t
            i += 1
            if cmd in "Zz":
                cur = start
                last_c = last_q = None
                continue
        elif cmd is None:
            raise ValueError("path data does not start with a command")
        up = cmd.upper()
        rel = cmd.islower()
        k = ARGS[up]
        if up == "A":
            vals = []
            for j in range(7):
                if j in (3, 4):
                    flag_split()
                vals.append(float(toks[i]))
                i += 1
        else:
            vals = [float(x) for x in toks[i:i + k]]
            i += k
        if len(vals) < k:
            raise ValueError("truncated path data")
        ox, oy = cur if rel else (0.0, 0.0)
        if up == "M":
            cur = (vals[0] + ox, vals[1] + oy)
            start = cur
            box.add(*apply(m, *cur))
            cmd = "l" if rel else "L"
            last_c = last_q = None
        elif up == "L":
            cur = (vals[0] + ox, vals[1] + oy)
            box.add(*apply(m, *cur))
            last_c = last_q = None
        elif up == "H":
            cur = (vals[0] + ox, cur[1])
            box.add(*apply(m, *cur))
            last_c = last_q = None
        elif up == "V":
            cur = (cur[0], vals[0] + (cur[1] if rel else 0.0))
            box.add(*apply(m, *cur))
            last_c = last_q = None
        elif up == "C":
            p1 = (vals[0] + ox, vals[1] + oy)
            p2 = (vals[2] + ox, vals[3] + oy)
            p3 = (vals[4] + ox, vals[5] + oy)
            cubic_box(box, m, cur, p1, p2, p3)
            last_c, last_q, cur = p2, None, p3
        elif up == "S":
            p1 = (2 * cur[0] - last_c[0], 2 * cur[1] - last_c[1]) if last_c else cur
            p2 = (vals[0] + ox, vals[1] + oy)
            p3 = (vals[2] + ox, vals[3] + oy)
            cubic_box(box, m, cur, p1, p2, p3)
            last_c, last_q, cur = p2, None, p3
        elif up in "QT":
            if up == "Q":
                q1 = (vals[0] + ox, vals[1] + oy)
                p3 = (vals[2] + ox, vals[3] + oy)
            else:
                q1 = (2 * cur[0] - last_q[0], 2 * cur[1] - last_q[1]) if last_q else cur
                p3 = (vals[0] + ox, vals[1] + oy)
            c1 = (cur[0] + 2 / 3 * (q1[0] - cur[0]), cur[1] + 2 / 3 * (q1[1] - cur[1]))
            c2 = (p3[0] + 2 / 3 * (q1[0] - p3[0]), p3[1] + 2 / 3 * (q1[1] - p3[1]))
            cubic_box(box, m, cur, c1, c2, p3)
            last_q, last_c, cur = q1, None, p3
        elif up == "A":
            p3 = (vals[5] + ox, vals[6] + oy)
            for p in arc_points(cur, vals[0], vals[1], vals[2], int(vals[3]), int(vals[4]), p3):
                box.add(*apply(m, *p))
            cur = p3
            last_c = last_q = None
    return box


def num_attr(e, name, default=0.0) -> float:
    v = e.get(name)
    if v is None:
        return default
    m = re.match(NUM, v.strip())
    if not m:
        return default
    if v.strip().endswith("%"):
        raise ValueError(f"percentage {name} on <{local(e.tag)}> not supported")
    return float(m.group(0))


def points_attr(e):
    v = [float(x) for x in re.findall(NUM, e.get("points", ""))]
    return list(zip(v[0::2], v[1::2]))


# ---------------------------------------------------------------- style

class Styles:
    """Presentation attributes, inline style and simple class / id / tag rules from <style>."""

    PROPS = ("fill", "stroke", "stroke-width", "display", "visibility", "opacity", "clip-path", "mask")

    def __init__(self, root):
        self.rules = []
        for st in root.iter():
            if local(st.tag) == "style" and st.text:
                css = re.sub(r"/\*.*?\*/", "", st.text, flags=re.S)
                for sel, body in re.findall(r"([^{}]+)\{([^}]*)\}", css):
                    decl = self.decl(body)
                    for s in sel.split(","):
                        self.rules.append((s.strip(), decl))

    @staticmethod
    def decl(body):
        out = {}
        for part in body.split(";"):
            if ":" in part:
                k, v = part.split(":", 1)
                out[k.strip()] = v.strip()
        return out

    def own(self, e):
        out = {}
        for p in self.PROPS:
            if e.get(p) is not None:
                out[p] = e.get(p).strip()
        classes = (e.get("class") or "").split()
        for sel, decl in self.rules:
            if (sel.startswith(".") and sel[1:] in classes) or (sel.startswith("#") and sel[1:] == e.get("id")) \
                    or sel == local(e.tag):
                out.update({k: v for k, v in decl.items() if k in self.PROPS})
        out.update({k: v for k, v in self.decl(e.get("style") or "").items() if k in self.PROPS})
        return out


INHERITED = ("fill", "stroke", "stroke-width", "visibility")


# ---------------------------------------------------------------- tree walk

class Doc:
    def __init__(self, data: bytes):
        if re.search(rb"<!ENTITY[^>]*\b(SYSTEM|PUBLIC)\b", data[:65536]):
            raise ValueError("external entity declared: refused")
        self.namespaces = []
        for _, (prefix, uri) in ET.iterparse(io.BytesIO(data), events=("start-ns",)):
            self.namespaces.append((prefix, uri))
        self.root = ET.fromstring(data)
        if local(self.root.tag) != "svg":
            raise ValueError("root element is not <svg>")
        self.styles = Styles(self.root)
        self.ids = {e.get("id"): e for e in self.root.iter() if e.get("id")}

    def walk(self, e=None, path="", m=IDENTITY, inh=None, in_defs=False):
        """Yields (path, element, matrix to root user space, computed style, clip boxes) for every element."""
        e = self.root if e is None else e
        inh = inh or {"fill": "#000", "stroke": "none", "stroke-width": "1", "visibility": "visible"}
        for i, c in enumerate(list(e)):
            tag = local(c.tag)
            if not tag:
                continue
            p = f"{path}/{i}" if path else str(i)
            own = self.styles.own(c)
            st = {**{k: v for k, v in inh.items() if k in INHERITED}, **own}
            cm = mul(m, parse_transform(c.get("transform")))
            if tag == "svg":
                cm = mul(cm, (1, 0, 0, 1, num_attr(c, "x"), num_attr(c, "y")))
            yield p, c, cm, st, in_defs or tag in NON_RENDERING
            if tag in CONTAINERS or tag in NON_RENDERING:
                yield from self.walk(c, p, cm, st, in_defs or tag in NON_RENDERING)

    def at(self, path: str):
        e = self.root
        for i in path.split("/"):
            e = list(e)[int(i)]
        return e

    def ref(self, value):
        m = re.match(r"\s*url\(\s*['\"]?#([^)'\"]+)['\"]?\s*\)", value or "")
        return self.ids.get(m.group(1)) if m else None

    def shape_box(self, e, m: Matrix, st, depth=0) -> Box:
        tag = local(e.tag)
        box = Box()
        if tag == "path":
            box = path_box(e.get("d", ""), m)
        elif tag == "rect":
            x, y, w, h = (num_attr(e, k) for k in ("x", "y", "width", "height"))
            for px, py in ((x, y), (x + w, y), (x, y + h), (x + w, y + h)):
                box.add(*apply(m, px, py))
        elif tag in ("circle", "ellipse"):
            cx, cy = num_attr(e, "cx"), num_attr(e, "cy")
            rx = num_attr(e, "r") if tag == "circle" else num_attr(e, "rx")
            ry = num_attr(e, "r") if tag == "circle" else num_attr(e, "ry")
            k = 0.5522847498
            d = (f"M{cx + rx},{cy} C{cx + rx},{cy + k * ry} {cx + k * rx},{cy + ry} {cx},{cy + ry} "
                 f"C{cx - k * rx},{cy + ry} {cx - rx},{cy + k * ry} {cx - rx},{cy} "
                 f"C{cx - rx},{cy - k * ry} {cx - k * rx},{cy - ry} {cx},{cy - ry} "
                 f"C{cx + k * rx},{cy - ry} {cx + rx},{cy - k * ry} {cx + rx},{cy}")
            box = path_box(d, m)  # the 4-arc Bezier circle touches the true extremes exactly
        elif tag == "line":
            box.add(*apply(m, num_attr(e, "x1"), num_attr(e, "y1")))
            box.add(*apply(m, num_attr(e, "x2"), num_attr(e, "y2")))
        elif tag in ("polyline", "polygon"):
            for p in points_attr(e):
                box.add(*apply(m, *p))
        elif tag == "use":
            target = self.ref(f"url({e.get('href') or e.get(f'{{{XLINK_NS}}}href')})")
            if target is None or depth > 8:
                raise ValueError("<use> without a local target")
            um = mul(m, (1, 0, 0, 1, num_attr(e, "x"), num_attr(e, "y")))
            box = self.subtree_box(target, um, st, depth + 1)
        elif tag == "image":
            x, y, w, h = (num_attr(e, k) for k in ("x", "y", "width", "height"))
            for px, py in ((x, y), (x + w, y), (x, y + h), (x + w, y + h)):
                box.add(*apply(m, px, py))
        elif tag == "text":
            raise ValueError("<text> cannot be measured without fonts")
        if tag not in ("use", "image") and st.get("stroke", "none") not in ("none", "") and not box.empty():
            sw = num_attr(_Attr(st), "stroke-width", 1.0)
            scale = math.sqrt(abs(m[0] * m[3] - m[1] * m[2]))
            box.grow(sw * scale / 2)
        return box

    def subtree_box(self, e, m: Matrix, inh, depth=0) -> Box:
        """Box of an element and its drawn descendants, in the space m maps to."""
        own = self.styles.own(e)
        st = {**{k: v for k, v in inh.items() if k in INHERITED}, **own}
        m = mul(m, parse_transform(e.get("transform")))
        if self.hidden(st):
            return Box()
        tag = local(e.tag)
        if tag in SHAPES:
            box = self.shape_box(e, m, st, depth) if self.painted(e, st) else Box()
        else:
            box = Box()
            for c in e:
                if local(c.tag) and local(c.tag) not in NON_RENDERING:
                    box.merge(self.subtree_box(c, m, st, depth))
        return self.clipped(box, e, m, st)

    def clipped(self, box: Box, e, m, st):
        clip = self.ref(st.get("clip-path"))
        if clip is not None:
            cb = Box()
            cm = mul(m, parse_transform(clip.get("transform")))
            for c in clip:
                if local(c.tag) in SHAPES:
                    cb.merge(self.shape_box(c, mul(cm, parse_transform(c.get("transform"))), {"stroke": "none"}))
            box.clip(cb)
        return box

    @staticmethod
    def hidden(st):
        return st.get("display") == "none" or st.get("visibility") in ("hidden", "collapse") \
            or st.get("opacity") in ("0", "0.0")

    @staticmethod
    def painted(e, st):
        if local(e.tag) in ("use", "image"):
            return True
        return st.get("fill", "#000") not in ("none", "") or st.get("stroke", "none") not in ("none", "")


class _Attr:
    """A computed style seen through num_attr's element interface."""

    tag = "style"

    def __init__(self, d):
        self.d = d

    def get(self, k, default=None):
        return self.d.get(k, default)


def element_boxes(doc: Doc):
    """(path, tag, fill, box in root user space) for every drawn shape outside defs, ancestors' clips applied."""
    out = []
    parents = {}
    for p, e, m, st, in_defs in doc.walk():
        parents[p] = (e, m, st)
        if in_defs or local(e.tag) not in SHAPES:
            continue
        chain = [p.rsplit("/", k)[0] for k in range(p.count("/"), 0, -1)]
        if any(Doc.hidden(parents[a][2]) for a in chain) or Doc.hidden(st):
            continue
        box = doc.shape_box(e, m, st) if Doc.painted(e, st) else Box()
        box = doc.clipped(box, e, m, st)
        for a in chain:
            ae, am, ast = parents[a]
            box = doc.clipped(box, ae, am, ast)
        out.append((p, local(e.tag), st.get("fill"), box))
    return out


# ---------------------------------------------------------------- crop

def fmt(v: float) -> str:
    s = f"{v:.4f}".rstrip("0").rstrip(".")
    return "0" if s in ("-0", "") else s


def crop_svg(data: bytes, keep: list, source_page: str) -> tuple[bytes, tuple]:
    doc = Doc(data)
    keep = [k.strip("/") for k in keep]
    shapes = element_boxes(doc)
    known = {p for p, _, _, _ in shapes}
    allpaths = {p for p, *_ in doc.walk()}
    for k in keep:
        if k not in allpaths:
            raise ValueError(f"keep path {k} is not an element")

    def kept(p):
        return any(p == k or p.startswith(k + "/") for k in keep)

    def ancestor_of_kept(p):
        return any(k.startswith(p + "/") for k in keep)

    # Remove every drawn element that is neither kept, inside a kept one, nor on the way to one.
    doomed = []
    for p, e, m, st, in_defs in doc.walk():
        tag = local(e.tag)
        if in_defs or tag in NON_RENDERING:
            continue
        if kept(p) or ancestor_of_kept(p):
            continue
        if tag in SHAPES or tag in CONTAINERS:
            doomed.append(p)
    # Deepest first so earlier index paths stay valid; skip those inside an already removed container.
    doomed = [p for p in doomed if not any(p.startswith(q + "/") for q in doomed)]
    box = Box()
    for p, tag, fill, b in shapes:
        if kept(p):
            box.merge(b)
    if box.empty():
        raise ValueError("nothing drawn is kept")
    for p in sorted(doomed, key=lambda p: [int(x) for x in p.split("/")], reverse=True):
        parent = doc.root if "/" not in p else doc.at(p.rsplit("/", 1)[0])
        parent.remove(list(parent)[int(p.rsplit("/", 1)[-1])])
    x0, y0, x1, y1 = box.tup()
    root = doc.root
    root.set("viewBox", f"{fmt(x0)} {fmt(y0)} {fmt(x1 - x0)} {fmt(y1 - y0)}")
    root.set("width", fmt(x1 - x0))
    root.set("height", fmt(y1 - y0))
    root.insert(0, ET.Comment(
        f" Symbol cropped from {source_page} by Scripts/logos/crop_symbols.py: wordmark elements removed, "
        f"viewBox tightened; path data and colours as published. "))
    for prefix, uri in doc.namespaces:
        ET.register_namespace(prefix, uri)
    ET.register_namespace("", SVG_NS)
    out = b'<?xml version="1.0" encoding="UTF-8"?>\n' + ET.tostring(root, encoding="utf-8", xml_declaration=False) + b"\n"
    return out, (x1 - x0) / (y1 - y0)


# ---------------------------------------------------------------- PNG (stdlib)

def png_read(data: bytes):
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("not a PNG")
    pos, ihdr, idat, plte, trns = 8, None, b"", None, None
    while pos < len(data):
        n = struct.unpack(">I", data[pos:pos + 4])[0]
        kind = data[pos + 4:pos + 8]
        body = data[pos + 8:pos + 8 + n]
        pos += 12 + n
        if kind == b"IHDR":
            ihdr = struct.unpack(">IIBBBBB", body)
        elif kind == b"IDAT":
            idat += body
        elif kind == b"PLTE":
            plte = body
        elif kind == b"tRNS":
            trns = body
        elif kind == b"IEND":
            break
    w, h, depth, ctype, _, _, interlace = ihdr
    if depth != 8 or interlace:
        raise ValueError("only 8-bit non-interlaced PNG is cropped")
    bpp = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}[ctype]
    raw = zlib.decompress(idat)
    rows, prev, stride, i = [], bytearray(w * bpp), w * bpp, 0
    for _ in range(h):
        f, line = raw[i], bytearray(raw[i + 1:i + 1 + stride])
        i += 1 + stride
        for x in range(stride):
            a = line[x - bpp] if x >= bpp else 0
            b = prev[x]
            c = prev[x - bpp] if x >= bpp else 0
            if f == 1:
                line[x] = (line[x] + a) & 255
            elif f == 2:
                line[x] = (line[x] + b) & 255
            elif f == 3:
                line[x] = (line[x] + (a + b) // 2) & 255
            elif f == 4:
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                line[x] = (line[x] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
        rows.append(bytes(line))
        prev = line
    return {"w": w, "h": h, "ctype": ctype, "bpp": bpp, "rows": rows, "plte": plte, "trns": trns}


def png_write(img, rows, w, h) -> bytes:
    def chunk(kind, body):
        return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body) & 0xFFFFFFFF)
    out = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, img["ctype"], 0, 0, 0))
    if img["plte"]:
        out += chunk(b"PLTE", img["plte"])
    if img["trns"]:
        out += chunk(b"tRNS", img["trns"])
    out += chunk(b"IDAT", zlib.compress(b"".join(b"\x00" + r for r in rows), 9))
    return out + chunk(b"IEND", b"")


def crop_png(data: bytes, box) -> bytes:
    x, y, w, h = box
    if max(w, h) < PX:
        raise ValueError(f"crop is {w}x{h} px, under {PX} px on its long side (no upscaling)")
    img = png_read(data)
    if x < 0 or y < 0 or x + w > img["w"] or y + h > img["h"]:
        raise ValueError("crop box outside the image")
    b = img["bpp"]
    return png_write(img, [r[x * b:(x + w) * b] for r in img["rows"][y:y + h]], w, h)


# ---------------------------------------------------------------- render, manifest, credits

def chrome() -> str:
    found = sorted((Path.home() / "Library/Caches/ms-playwright").glob(CHROME_GLOB))
    if not found:
        raise RuntimeError("no Playwright headless Chromium in ~/Library/Caches/ms-playwright")
    return str(found[-1])


def fit(aspect: float):
    if aspect >= 1:
        return PX, max(1, round(PX / aspect))
    return max(1, round(PX * aspect)), PX


def render_svg(svg: Path, out: Path, aspect: float):
    """192 px on the longest side, transparent, through an <img> with JavaScript off."""
    w, h = fit(aspect)
    with tempfile.TemporaryDirectory() as tmp:
        page = Path(tmp) / "render.html"
        page.write_text(
            "<!doctype html><meta charset=utf-8><style>html,body{margin:0;background:transparent}"
            f"img{{display:block;width:{w}px;height:{h}px;object-fit:contain}}</style>"
            f'<img src="{svg.resolve().as_uri()}">')
        subprocess.run([
            chrome(), "--headless", "--disable-gpu", "--hide-scrollbars", "--disable-javascript",
            "--force-device-scale-factor=1", "--default-background-color=00000000",
            f"--user-data-dir={tmp}/profile", f"--window-size={w},{h}", f"--screenshot={out}", page.as_uri(),
        ], check=True, capture_output=True, timeout=60)


def png_size(data: bytes):
    return int.from_bytes(data[16:20], "big"), int.from_bytes(data[20:24], "big")


def write_credits(manifest):
    """The app's credit list: one entry per airline for its wordmark, a nested symbol credit when a
    symbol ships (a crop credits the file it was cut from)."""
    logos, symbols = manifest["logos"], manifest.get("symbols", {})

    def credit(v):
        c = {"author": v["author"] or "Unknown author", "license": v["license"],
             "license_url": v["license_url"], "source": v["source_page"], "attribution": v["attribution"]}
        # A modified file (a share-alike one must say so) carries what was changed.
        if v.get("changes"):
            c["changes"] = v["changes"]
        return c

    def symbol_credit(s):
        c = {"kind": "symbol", **credit(s)}
        if s.get("method") == "crop":
            c.update({"method": "crop", "derived_from": s["source_file"]})
        return c

    credits = []
    for k, v in sorted(logos.items()):
        c = {"icao": k, "name": v["name"], "kind": "wordmark", **credit(v)}
        if k in symbols:
            s = symbols[k]
            c["symbol"] = symbol_credit(s)
            if s.get("method") == "crop":
                c["attribution"] = f"{v['attribution']}; symbol cropped from the same file"
            else:
                c["attribution"] = f"Wordmark: {v['attribution']}; symbol: {s['attribution']}"
        credits.append(c)
    for k, s in sorted(symbols.items()):
        if k not in logos:
            credits.append({"icao": k, "name": s["name"], **symbol_credit(s)})
    credits.sort(key=lambda c: c["icao"])
    APP_ATTRIBUTION.write_text(dump(credits))


def dump(obj) -> str:
    return json.dumps(obj, indent=2, sort_keys=True, ensure_ascii=False) + "\n"


def build() -> int:
    spec = json.loads(SPEC.read_text())
    manifest = json.loads((COMMONS / "manifest.json").read_text())
    logos = manifest["logos"]
    symbols = manifest.setdefault("symbols", {})
    sym_dir = COMMONS / "symbol"
    (sym_dir / "png").mkdir(parents=True, exist_ok=True)
    # Drop the previous crops so a removed spec leaves nothing behind.
    for icao in [k for k, v in symbols.items() if v.get("method") == "crop"]:
        v = symbols.pop(icao)
        for f in (COMMONS / v["file"], COMMONS / v["png"]):
            if f.is_file():
                f.unlink()
    done, refused = [], []
    for icao, c in sorted(spec["crops"].items()):
        try:
            if icao in symbols:
                raise ValueError("already has a Commons symbol (not overridden)")
            src = logos.get(icao)
            if not src or src["file"] != c["source"]:
                raise ValueError(f"source {c['source']} is not {icao}'s logo in the manifest")
            if src["license_kind"] not in ("public-domain", "cc0", "cc-by", "cc-by-sa"):
                raise ValueError(f"licence {src['license']} not accepted")
            data = (COMMONS / c["source"]).read_bytes()
            if hashlib.sha256(data).hexdigest() != c["source_sha256"] or src["sha256"] != c["source_sha256"]:
                raise ValueError("source changed since the crop was specified: look again")
            fmt_ = src["format"]
            out = sym_dir / f"{icao}.{fmt_}"
            small = sym_dir / "png" / f"{icao}.png"
            if fmt_ == "svg":
                body, aspect = crop_svg(data, c["keep"], src["source_page"])
                out.write_bytes(body)
                render_svg(out, small, aspect)
            else:
                body = crop_png(data, c["box"])
                out.write_bytes(body)
                small.write_bytes(body)  # already at least 192 px; the 192 px copy is not scaled here
            stored = out.read_bytes()
            pw, ph = png_size(small.read_bytes())
            inherit = {k: src[k] for k in (
                "name", "iata", "wikidata", "source_file", "source_page", "source_sha1", "license_kind", "license",
                "license_url", "attribution_required", "author", "credit", "trademarked", "retrieved")}
            symbols[icao] = {
                **inherit,
                "kind": "symbol",
                "method": "crop",
                "derived_from": c["source"],
                "crop": {"keep": c["keep"]} if fmt_ == "svg" else {"box": c["box"]},
                "symbol_source": f"crop of the Commons logo ({c['source']})",
                "file": f"symbol/{icao}.{fmt_}",
                "format": fmt_,
                "sha256": hashlib.sha256(stored).hexdigest(),
                "bytes": len(stored),
                "png": f"symbol/png/{icao}.png",
                "png_sha256": hashlib.sha256(small.read_bytes()).hexdigest(),
                "png_size": [pw, ph],
                "resized_from_source": False,
                "attribution": f"{src['attribution']}, cropped to the symbol",
            }
            done.append(icao)
        except (ValueError, KeyError, ET.ParseError) as e:
            refused.append((icao, str(e)))
    (COMMONS / "manifest.json").write_text(dump(manifest))
    write_credits(manifest)
    print(f"cropped {len(done)}: {' '.join(done)}")
    for icao, why in refused:
        print(f"refused {icao}: {why}")
    print(f"skipped by spec {len(spec.get('skipped', {}))}: {' '.join(sorted(spec.get('skipped', {})))}")
    return 1 if refused else 0


def inspect(icao: str) -> int:
    manifest = json.loads((COMMONS / "manifest.json").read_text())
    src = manifest["logos"][icao]
    data = (COMMONS / src["file"]).read_bytes()
    print(f"{icao} {src['file']} sha256 {src['sha256']}")
    if src["format"] != "svg":
        print("PNG", png_size(data))
        return 0
    doc = Doc(data)
    print("viewBox", doc.root.get("viewBox"), "width", doc.root.get("width"), "height", doc.root.get("height"))
    for p, tag, fill, b in element_boxes(doc):
        bb = "empty" if b.empty() else " ".join(f"{v:9.2f}" for v in b.tup())
        print(f"{p:12} {tag:9} {str(fill)[:24]:24} {bb}")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--inspect", metavar="ICAO")
    args = ap.parse_args()
    if args.inspect:
        return inspect(args.inspect)
    return build()


if __name__ == "__main__":
    sys.exit(main())
