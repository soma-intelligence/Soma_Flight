#!/usr/bin/env python3
"""Builds Flags.xcassets from a circle-flags checkout (MIT, HatScripts/circle-flags).

    python3 Scripts/flags/build_flags.py <circle-flags clone> <Flags.xcassets dir>

The clone must be at the commit in Scripts/flags/PIN. Copies flags/<iso2>.svg for every code in
countries.json plus xx.svg (the fallback) into flag-<iso2>.imageset/ with a vector-preserving
Contents.json. Only SVG files are read from the clone; nothing in it is run.
"""
import json
import shutil
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
COUNTRIES = ROOT / "Packages/FlightKit/Sources/FlightKit/Resources/Reference/countries.json"


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__)
        return 2
    clone, out = Path(sys.argv[1]), Path(sys.argv[2])
    codes = sorted({c["iso2"].lower() for c in json.loads(COUNTRIES.read_text())} | {"xx"})
    missing = [c for c in codes if not (clone / "flags" / f"{c}.svg").is_file()]
    if missing:
        print("missing in clone:", ", ".join(missing))
        return 1
    if out.exists():
        shutil.rmtree(out)
    out.mkdir(parents=True)
    (out / "Contents.json").write_text(json.dumps({"info": {"author": "xcode", "version": 1}}, indent=2) + "\n")
    for code in codes:
        d = out / f"flag-{code}.imageset"
        d.mkdir()
        shutil.copyfile(clone / "flags" / f"{code}.svg", d / f"{code}.svg")
        contents = {
            "images": [{"filename": f"{code}.svg", "idiom": "universal"}],
            "info": {"author": "xcode", "version": 1},
            "properties": {"preserves-vector-representation": True},
        }
        (d / "Contents.json").write_text(json.dumps(contents, indent=2) + "\n")
    print(f"{len(codes)} flags written to {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
