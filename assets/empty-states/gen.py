"""Empty-state jets for Passport and My Flights, made with Azure gpt-image-2.5 (images/edits).

The v4 app-icon jet (assets/icon-set-v4/plane-white.png, seen from above) is the style reference.
One call at a time: the deployment rate-limits. Usage, from the repo root:

    python3 assets/empty-states/gen.py profile 1     # -> assets/empty-states/raw/profile-1.png
    python3 assets/empty-states/gen.py climb 2

Then: python3 assets/empty-states/post.py <raw png> <asset name>  (trim, resize, write the imageset).
"""
import base64, json, pathlib, subprocess, sys, time, urllib.error, urllib.request, uuid

ROOT = pathlib.Path(__file__).resolve().parents[2]
OUT = pathlib.Path(__file__).resolve().parent / "raw"
REF = ROOT / "assets" / "icon-set-v4" / "plane-white.png"
EP = ("https://temple-ai-provider.cognitiveservices.azure.com/openai/deployments/gpt-image-2.5-flare/"
      "images/edits?api-version=2025-04-01-preview")

BASE = (
    "The reference image shows our brand's private business jet from above: a large modern long-range business "
    "jet in the Dassault Falcon 6X class, glossy pure white paint with soft silver shading, two rear-mounted "
    "engines on the aft fuselage, swept wings with small upturned winglets, T-less cruciform-free conventional "
    "tail with a swept fin and a horizontal stabiliser low on the fin, oval cabin windows, dark cockpit glass. "
    "Draw THE SAME aircraft, same paint and same rendering style: a realistic but slightly stylised premium "
    "product illustration, like an Apple product render, clean studio lighting, smooth gloss, crisp edges, "
    "very few panel lines. Absolutely no livery, no stripes, no logo, no text, no registration, no flag. "
    "Exactly two engines, both on the rear fuselage. Landing gear retracted, in flight. "
    "Isolated on a fully transparent background: no sky, no ground, no clouds, no shadow, no reflection, "
    "no frame, no watermark. The whole aircraft fits in the frame with generous equal margins, centred. "
)
VIEWS = {
    "profile": "View: pure side profile, nose pointing RIGHT, camera exactly level with the fuselage, "
               "level flight, no roll, no pitch. Only the near engine is visible on the rear fuselage.",
    "climb": "View: three-quarter view from slightly below and in front, nose pointing to the upper RIGHT, "
             "the jet climbing gently at about 12 degrees, a little of the underside of the near wing visible, "
             "both wings and both engines visible, elegant and dynamic.",
    # climb-1 came back as a top view again; v2 pins the camera to the side.
    "climb2": "View: almost a pure side profile, nose pointing RIGHT, the camera only about 15 degrees in front of "
              "the side and slightly below the aircraft. The jet is climbing: the whole aircraft is pitched nose-up "
              "by about 12 degrees, so the nose is higher than the tail. The near wing is seen almost edge-on, "
              "attached low on the fuselage under the cabin windows, its tip just behind the engine. Only the near "
              "engine is clearly visible on the rear fuselage.",
    # climb2-1 bent the fuselage like a banana; v3 asks for a rigid, straight fuselage at a three-quarter angle.
    "climb3": "View: three-quarter front view, camera level with the aircraft and about 35 degrees ahead of its "
              "right side, so we see the nose, the right side of the fuselage and both wings receding in "
              "perspective. Nose pointing to the RIGHT and toward the viewer, the jet climbing gently with the "
              "nose about 8 degrees up. The fuselage is a rigid perfectly straight tube, correct perspective, "
              "two engines on the rear fuselage, one on each side, swept wings with small winglets.",
    # profile-1: good, but the wing read as a plank under the belly with its tip under the fin.
    "profile2": "View: pure side profile, nose pointing RIGHT, camera exactly level with the fuselage, level flight. "
                "The near wing is seen almost edge-on, attached low on the fuselage below the cabin windows; its "
                "swept tip with a small upturned winglet ends just below and behind the engine, well ahead of the "
                "fin. Only the near engine is visible on the rear fuselage.",
}


def key():
    return subprocess.check_output(["az", "cognitiveservices", "account", "keys", "list", "-n", "temple-ai-provider",
                                    "-g", "temple-ai-rg", "--query", "key1", "-o", "tsv"], text=True).strip()


def run(view, tag, k):
    b = uuid.uuid4().hex
    fields = {"prompt": BASE + VIEWS[view], "size": "1536x1024", "quality": "high",
              "background": "transparent", "output_format": "png", "n": "1"}
    body = b"".join(f"--{b}\r\nContent-Disposition: form-data; name=\"{f}\"\r\n\r\n{v}\r\n".encode()
                    for f, v in fields.items())
    body += (f"--{b}\r\nContent-Disposition: form-data; name=\"image[]\"; filename=\"{REF.name}\"\r\n"
             "Content-Type: image/png\r\n\r\n").encode() + REF.read_bytes() + b"\r\n"
    body += f"--{b}--\r\n".encode()
    req = urllib.request.Request(EP, data=body, method="POST",
                                 headers={"api-key": k, "Content-Type": f"multipart/form-data; boundary={b}"})
    for attempt in range(6):
        try:
            r = json.load(urllib.request.urlopen(req, timeout=600))
            break
        except urllib.error.HTTPError as e:
            if e.code == 429:
                time.sleep(40 + 10 * attempt)
                continue
            sys.exit(f"HTTP {e.code} {e.read()[:300]!r}")
    else:
        sys.exit("gave up after 429s")
    OUT.mkdir(exist_ok=True)
    out = OUT / f"{view}-{tag}.png"
    out.write_bytes(base64.b64decode(r["data"][0]["b64_json"]))
    print(out)


if __name__ == "__main__":
    run(sys.argv[1], sys.argv[2], key())
