"""Side-view app icon jets and the Friends empty-state art, made with Azure gpt-image-2.5 (images/edits).

Same family as assets/empty-states: the reference is the My Flights climbing jet (empty-states/raw/climb3-1.png),
same paint, same studio render, transparent background. One call at a time: the deployment rate-limits.
Usage, from the repo root:

    python3 assets/app-icon/gen.py icon-climb 1      # -> assets/app-icon/raw/icon-climb-1.png
    python3 assets/app-icon/gen.py friends-pair 1

Then: python3 assets/app-icon/build.py (icon) or assets/empty-states/post.py (Friends art).
"""
import base64, json, pathlib, subprocess, sys, time, urllib.error, urllib.request, uuid

ROOT = pathlib.Path(__file__).resolve().parents[2]
OUT = pathlib.Path(__file__).resolve().parent / "raw"
REF = ROOT / "assets" / "empty-states" / "raw" / "climb3-1.png"
EP = ("https://temple-ai-provider.cognitiveservices.azure.com/openai/deployments/gpt-image-2.5-flare/"
      "images/edits?api-version=2025-04-01-preview")

JET = (
    "The reference image shows our brand's private business jet: a large modern long-range business jet in the "
    "Dassault Falcon 6X class, glossy pure white paint with soft silver shading, two engines mounted on the rear "
    "fuselage, swept wings with small upturned winglets, a swept fin with the horizontal stabiliser low on it, oval "
    "cabin windows, dark cockpit glass. Draw THE SAME aircraft, same paint and EXACTLY the same rendering style as the "
    "reference: a realistic but slightly stylised premium product illustration, like an Apple product render, clean "
    "studio lighting from the upper left, smooth gloss, crisp edges, very few panel lines. Absolutely no livery, no "
    "stripes, no logo, no text, no registration, no flag. Exactly two engines per aircraft, on the rear fuselage. "
    "Landing gear retracted, in flight. Rigid perfectly straight fuselage, correct perspective. "
    "Isolated on a fully transparent background: no sky, no ground, no clouds, no shadow, no reflection, no contrails, "
    "no frame, no watermark. "
)
ICON = ("This is for an app icon, so the silhouette must stay bold and readable when tiny: a compact, chunky, "
        "confident aircraft, slightly shorter wings than real, thick fuselage. The whole aircraft fits in the frame "
        "with generous equal margins, centred. ")
VIEWS = {
    # three-quarter climb like the My Flights empty state, more compact for a square tile
    "icon-climb": (ICON + "View: three-quarter front view, camera slightly below and about 35 degrees ahead of the "
                   "right side, nose pointing to the upper RIGHT and a little toward the viewer, the jet climbing "
                   "at about 15 degrees. Both wings visible receding in perspective, both rear engines visible.", "1024x1024"),
    # side profile climbing, nose up-right
    "icon-profile": (ICON + "View: side profile seen from slightly below, nose pointing RIGHT, the jet climbing "
                     "steeply with the nose about 25 degrees up, so the aircraft runs diagonally from lower left to "
                     "upper right. The near wing seen almost edge-on, low under the cabin windows, with its winglet. "
                     "Only the near engine visible.", "1024x1024"),
    # head-on-ish three-quarter, banking toward the viewer
    "icon-bank": (ICON + "View: dramatic three-quarter front view from slightly above, nose pointing to the RIGHT and "
                  "toward the viewer, the jet banking gently into a turn with the near wing lowered about 15 degrees, "
                  "showing the top of the far wing and the cockpit windows clearly. Both rear engines visible.", "1024x1024"),
    # Friends empty state: two of the same jets flying together
    "friends-pair": ("Draw TWO of these identical jets flying together in loose formation, side by side, both in "
                     "three-quarter front view climbing gently to the upper RIGHT like the reference, one slightly "
                     "ahead, higher and nearer, the other a little behind, lower and smaller in the distance, their "
                     "paths converging, a friendly companionable pair. Both aircraft entirely inside the frame with "
                     "generous margins, not overlapping each other.", "1536x1024"),
    "friends-cross": ("Draw TWO of these identical jets in side profile flying toward each other and passing at "
                      "different heights: the upper one heading RIGHT, the lower one heading LEFT, slightly offset, "
                      "like two friends crossing paths in the sky, both in level flight, both fully inside the frame "
                      "with generous margins, not overlapping each other.", "1536x1024"),
    "friends-meet": ("Draw TWO of these identical jets: the left one climbing gently to the upper RIGHT in "
                     "three-quarter view, the right one climbing gently to the upper LEFT in mirrored three-quarter "
                     "view, both heading toward the same point above the centre, as if meeting up, symmetrical "
                     "composition, both fully inside the frame with generous margins, not touching.", "1536x1024"),
}


def key():
    return subprocess.check_output(["az", "cognitiveservices", "account", "keys", "list", "-n", "temple-ai-provider",
                                    "-g", "temple-ai-rg", "--query", "key1", "-o", "tsv"], text=True).strip()


def run(view, tag, k):
    text, size = VIEWS[view]
    b = uuid.uuid4().hex
    fields = {"prompt": JET + text, "size": size, "quality": "high",
              "background": "transparent", "output_format": "png", "n": "1"}
    body = b"".join(f"--{b}\r\nContent-Disposition: form-data; name=\"{f}\"\r\n\r\n{v}\r\n".encode()
                    for f, v in fields.items())
    body += (f"--{b}\r\nContent-Disposition: form-data; name=\"image[]\"; filename=\"{REF.name}\"\r\n"
             "Content-Type: image/png\r\n\r\n").encode() + REF.read_bytes() + b"\r\n"
    body += f"--{b}--\r\n".encode()
    req = urllib.request.Request(EP, data=body, method="POST",
                                 headers={"api-key": k, "Content-Type": f"multipart/form-data; boundary={b}"})
    for attempt in range(8):
        try:
            r = json.load(urllib.request.urlopen(req, timeout=600))
            break
        except urllib.error.HTTPError as e:
            if e.code == 429:
                time.sleep(40 + 15 * attempt)
                continue
            sys.exit(f"HTTP {e.code} {e.read()[:300]!r}")
    else:
        sys.exit("gave up after 429s")
    OUT.mkdir(exist_ok=True)
    out = OUT / f"{view}-{tag}.png"
    out.write_bytes(base64.b64decode(r["data"][0]["b64_json"]))
    print(out)


if __name__ == "__main__":
    k = key()
    for view in sys.argv[2:] if sys.argv[1] == "--all" else [sys.argv[1]]:
        run(view, "1" if sys.argv[1] == "--all" else sys.argv[2], k)
