#!/usr/bin/env bash
# Rebuild the Swift binding of flightcore: FlightCoreFFI.xcframework (static
# libraries for iOS device, iOS simulator and macOS universal), the generated
# Swift wrapper, and the fixtures the Swift tests replay.
# UniFFI bindgen comes from flightcore-ffi's own uniffi-bindgen binary, so its
# version is pinned by core/Cargo.lock.
set -euo pipefail
cd "$(dirname "$0")/.."

CORE="$PWD"
PKG="$CORE/../Packages/FlightCoreFFI"
LIB=libflightcore_ffi.a
TARGETS=(aarch64-apple-ios aarch64-apple-ios-sim aarch64-apple-darwin x86_64-apple-darwin)
export IPHONEOS_DEPLOYMENT_TARGET=26.0
export MACOSX_DEPLOYMENT_TARGET=26.0
# Reproducible archives: zero ar member dates, and no absolute local paths
# (registry sources, this checkout) in panic locations or symbols.
export ZERO_AR_DATE=1
CARGO_HOME_DIR="${CARGO_HOME:-$HOME/.cargo}"
export RUSTFLAGS="${RUSTFLAGS:-} --remap-path-prefix=$CARGO_HOME_DIR/registry/src=/cargo/registry/src --remap-path-prefix=$CORE=/flightcore"

for t in "${TARGETS[@]}"; do
  cargo build --locked --release -p flightcore-ffi --lib --target "$t"
done

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Strip debug info (the precompiled std carries it): about 24 MB down to
# about 5 MB per slice. Symbols stay, so the app's linker still resolves them.
for t in "${TARGETS[@]}"; do
  mkdir -p "$WORK/$t"
  strip -S "target/$t/release/$LIB" -o "$WORK/$t/$LIB"
done

# Universal macOS slice.
mkdir -p "$WORK/macos"
lipo -create \
  "$WORK/aarch64-apple-darwin/$LIB" \
  "$WORK/x86_64-apple-darwin/$LIB" \
  -output "$WORK/macos/$LIB"

# Swift wrapper, C header and modulemap (names set in flightcore-ffi/uniffi.toml).
cargo run --locked --release -p flightcore-ffi --features cli --bin uniffi-bindgen -- \
  generate --library "target/aarch64-apple-darwin/release/$LIB" \
  --language swift --no-format --out-dir "$WORK/gen"
mkdir -p "$WORK/headers"
cp "$WORK/gen/FlightCoreFFI.h" "$WORK/headers/"
cp "$WORK/gen/FlightCoreFFI.modulemap" "$WORK/headers/module.modulemap"

rm -rf "$PKG/FlightCoreFFI.xcframework"
xcodebuild -create-xcframework \
  -library "$WORK/aarch64-apple-ios/$LIB" -headers "$WORK/headers" \
  -library "$WORK/aarch64-apple-ios-sim/$LIB" -headers "$WORK/headers" \
  -library "$WORK/macos/$LIB" -headers "$WORK/headers" \
  -output "$PKG/FlightCoreFFI.xcframework"

mkdir -p "$PKG/Sources/FlightCore"
cp "$WORK/gen/FlightCore.swift" "$PKG/Sources/FlightCore/FlightCore.swift"
# The project never ships the em dash (U+2014); UniFFI's template has one in a comment.
perl -CSD -pi -e 's/[ \t]*\x{2014}/,/g' "$PKG/Sources/FlightCore/FlightCore.swift"

# Fixtures replayed by Tests/FlightCoreTests/FixtureTests.swift.
mkdir -p "$PKG/Tests/FlightCoreTests/Fixtures"
rm -f "$PKG/Tests/FlightCoreTests/Fixtures/"*.json
cp fixtures/*.json "$PKG/Tests/FlightCoreTests/Fixtures/"

du -sh "$PKG/FlightCoreFFI.xcframework"
