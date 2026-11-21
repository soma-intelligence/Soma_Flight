# AGENTS.md

Notes for coding agents working on Soma Flight. Read [CLAUDE.md](CLAUDE.md) and the owner's goal and principles it points to before starting; they take precedence over this file.

## Layout

| Path | What |
|---|---|
| `project.yml` | XcodeGen spec for every Apple target. The `.xcodeproj` is generated and git ignored |
| `Apps/iOS`, `Apps/macOS`, `Apps/Watch`, `Apps/WatchWidgets`, `Apps/Widgets`, `Apps/Share`, `Apps/Intents` | Thin app and extension shells |
| `Packages/FlightKit` | The shared Swift package: `FlightKit` (app, stores, services, UI), `FlightActivityKit`, `FlightWatchKit`, `FlightImportKit`, and the tests |
| `Packages/FlightCoreFFI` | Prebuilt Swift binding of the Rust core (generated, committed) |
| `core/` | Rust workspace: `flightcore` (pure logic), `flightcore-ffi` (UniFFI), `flightcore-wasm`; rules pinned in `core/fixtures` |
| `supabase/` | Migrations, seed data, pgTAP tests (`tests/`), Deno Edge Functions (`functions/`) |
| `Apps/Web` | Web app, Vite + React 19 + TypeScript (first cut) |
| `docs/` | API contract, operations, data sources, method notes, user guides (`docs/guides/`) |
| `Scripts/` | Data and asset build scripts (logos, flags, world map, licences, string check) |

## Build

```bash
xcodegen generate && open SomaFlight.xcodeproj
```

Run Debug with the launch argument `-useFakes YES` to use the fakes (no backend, no key). `supabase start` brings up the local backend on port 58321, which Debug configs point at.

## Test

```bash
swift test --package-path Packages/FlightKit
(cd core && cargo test)
deno test -A supabase/functions
supabase test db
(cd Apps/Web && npm test)
```

Contract files under `supabase/functions/*/contract/` are written by the functions' tests (`UPDATE_CONTRACT=1`) and decoded by the app's tests; change both sides together.

## Conventions

- Logic shared by platforms goes in `core/flightcore` (pure: no I/O, no network, no clock reads; pass time in). After a change, rebuild the bindings with `core/scripts/build-xcframework.sh`, `core/scripts/build-wasm.sh` and `core/scripts/build-wasm.sh --web`, and commit the generated packages.
- Copies that must agree have tests that fail when they drift: `connection_rules.json` (app and functions), the web theme and `Theme.swift`.
- Every new function in the `public` schema needs `revoke execute ... from public, anon, authenticated`; `supabase/tests/archive_test.sql` enforces it.
- Release builds fail closed without real config. Never add a default backend URL, and never put a service role key in an app or web config.
- Pinned dependencies (Supabase Swift, swift-snapshot-testing, npm packages) are bumped on purpose, after reading the changelog.

## Do not

- Commit `Config.local.xcconfig`, `supabase/functions/.env.local`, `Apps/Web/.env*.local` or any key.
- Draw or add airline logos, liveries or marks; they come only from licensed or public domain sources listed in `docs/data-sources.md` and the licence JSON files ([NOTICE](NOTICE)).
- Turn on a paid provider, deploy, or change the hosted Supabase project without the owner's explicit yes.
- Add analytics, tracking or any SDK that sends usage data.
- Hand-edit generated files: `Packages/FlightCoreFFI`, the WASM packages, the seed migrations built from `supabase/seed/*.csv`.
