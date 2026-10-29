resvg_bg.wasm is index_bg.wasm of npm @resvg/resvg-wasm 2.6.2 (MPL-2.0), copied
unchanged. The edge runtime cannot fetch it from a CDN or read the npm cache, so
it ships as a static file (see config.toml, [functions.brand-assets-sync]
static_files). Keep the version in `validate.ts` (RESVG_VERSION) equal to this
one.
