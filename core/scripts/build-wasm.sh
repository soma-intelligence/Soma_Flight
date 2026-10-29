#!/usr/bin/env bash
# Rebuild the Deno WASM package used by the Supabase edge functions.
# Built with wasm-pack 0.15.0 (wasm-bindgen 0.2.129, pinned by core/Cargo.lock).
set -euo pipefail
cd "$(dirname "$0")/.."
wasm-pack build flightcore-wasm --target deno --release \
  --out-dir ../../supabase/functions/_shared/flightcore/pkg \
  -- --locked
# wasm-pack drops a .gitignore ("*") in the out dir; the package is committed.
rm -f ../supabase/functions/_shared/flightcore/pkg/.gitignore
ls -l ../supabase/functions/_shared/flightcore/pkg/*.wasm
