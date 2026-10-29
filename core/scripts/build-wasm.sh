#!/usr/bin/env bash
# Rebuild the Deno WASM package used by the Supabase edge functions.
set -euo pipefail
cd "$(dirname "$0")/.."
wasm-pack build flightcore-wasm --target deno --release \
  --out-dir ../../supabase/functions/_shared/flightcore/pkg
# wasm-pack drops a .gitignore ("*") in the out dir; the package is committed.
rm -f ../supabase/functions/_shared/flightcore/pkg/.gitignore
ls -l ../supabase/functions/_shared/flightcore/pkg/*.wasm
