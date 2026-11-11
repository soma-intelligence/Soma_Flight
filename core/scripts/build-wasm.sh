#!/usr/bin/env bash
# Rebuild the WASM package. Default: the Deno package used by the Supabase edge functions.
# With --web: the browser package used by Apps/Web (target web, committed under Apps/Web/src/core/pkg).
# Built with wasm-pack 0.15.0 (wasm-bindgen 0.2.129, pinned by core/Cargo.lock).
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "${1:-}" == "--web" ]]; then
  out=../../Apps/Web/src/core/pkg
  wasm-pack build flightcore-wasm --target web --release --out-dir "$out" -- --locked
  rm -f ../Apps/Web/src/core/pkg/.gitignore
  ls -l ../Apps/Web/src/core/pkg/*.wasm
  exit 0
fi
wasm-pack build flightcore-wasm --target deno --release \
  --out-dir ../../supabase/functions/_shared/flightcore/pkg \
  -- --locked
# wasm-pack drops a .gitignore ("*") in the out dir; the package is committed.
rm -f ../supabase/functions/_shared/flightcore/pkg/.gitignore
ls -l ../supabase/functions/_shared/flightcore/pkg/*.wasm
