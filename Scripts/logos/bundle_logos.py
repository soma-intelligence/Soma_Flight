#!/usr/bin/env python3
"""Copies the whole Commons logo library into the app as lossless WebP, for use offline.

    python3 -I Scripts/logos/bundle_logos.py

Source: assets/logos/commons/png/<ICAO>.png (wordmarks) and symbol/png/<ICAO>.png (symbols), both already
192 px on the longest side, transparent (written by fetch_commons.py and crop_symbols.py). 192 px is about
3x the largest square the app draws a mark in (AirlineLogo at 48 pt; 34 pt rows), and the size the backend
stores as its small rendition.

Writes Packages/FlightKit/Sources/FlightKit/Resources/Logos/:
    commons-wordmark-<ICAO>.webp, commons-symbol-<ICAO>.webp   pixels unchanged (cwebp -lossless)
    commons-logos.json   {"version", "wordmarks": [ICAO...], "symbols": [ICAO...]}, read by BundledLogos.swift
SwiftPM flattens resource folders, so the names carry a prefix no other resource uses.

Refuses to write when a file has no credit in Resources/Licenses/airline-logos.json (the list Settings >
Acknowledgements shows), or a credit has no file: what ships and what is credited stay the same set.
Needs cwebp.
"""
import json
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
LIB = ROOT / "assets/logos/commons"
RES = ROOT / "Packages/FlightKit/Sources/FlightKit/Resources"
OUT = RES / "Logos"


def icaos(folder: pathlib.Path) -> list[str]:
    return sorted(p.stem for p in folder.glob("*.png") if len(p.stem) == 3 and p.stem.isalnum())


def main() -> int:
    manifest = json.loads((LIB / "manifest.json").read_text())
    credits = json.loads((RES / "Licenses/airline-logos.json").read_text())
    words, symbols = icaos(LIB / "png"), icaos(LIB / "symbol/png")
    credited = {c["icao"] for c in credits}
    credited_symbols = {c["icao"] for c in credits if c.get("symbol")}
    problems = []
    if set(words) != credited:
        problems.append(f"wordmarks without credit {sorted(set(words) - credited)}, "
                        f"credits without file {sorted(credited - set(words))}")
    if set(symbols) != credited_symbols:
        problems.append(f"symbols without credit {sorted(set(symbols) - credited_symbols)}, "
                        f"symbol credits without file {sorted(credited_symbols - set(symbols))}")
    if problems:
        print("\n".join(problems), file=sys.stderr)
        return 1

    OUT.mkdir(parents=True, exist_ok=True)
    for old in OUT.glob("commons-*.webp"):
        old.unlink()
    for kind, folder, names in (("wordmark", LIB / "png", words), ("symbol", LIB / "symbol/png", symbols)):
        for icao in names:
            subprocess.run(["cwebp", "-quiet", "-lossless", "-z", "9", "-exact", str(folder / f"{icao}.png"),
                            "-o", str(OUT / f"commons-{kind}-{icao}.webp")], check=True)
    index = {"version": f"commons-{manifest['retrieved']}", "wordmarks": words, "symbols": symbols}
    (OUT / "commons-logos.json").write_text(json.dumps(index, indent=0) + "\n")
    size = sum(p.stat().st_size for p in OUT.iterdir())
    print(f"{len(words)} wordmarks, {len(symbols)} symbols, {size / 1e6:.2f} MB")
    return 0


if __name__ == "__main__":
    sys.exit(main())
