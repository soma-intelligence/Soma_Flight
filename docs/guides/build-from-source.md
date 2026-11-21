# How to build Soma Flight from source

Install Xcode 27 and XcodeGen, clone the repository, run `xcodegen generate` and open `SomaFlight.xcodeproj`. Debug builds run on built-in fakes with the launch argument `-useFakes YES`, so the iPhone, iPad, Mac and Watch apps run on a simulator with no account, key or server. The Rust core ships prebuilt; you need Rust only to change it.

## Requirements

| For | You need |
|---|---|
| The apps | Xcode 27, [XcodeGen](https://github.com/yonaskolb/XcodeGen). Deployment targets: iOS, macOS and watchOS 26.0 |
| A real backend | The Supabase CLI and Docker. See [Self-host the backend](self-host-supabase-backend.md) |
| Changing the Rust core | A Rust toolchain (pinned in `core/rust-toolchain.toml`); `wasm-pack` 0.15.0 for the WASM builds |
| The web app | Node.js and npm |

## Build the apps

```bash
git clone https://github.com/soma-intelligence/Soma_Flight.git
cd Soma_Flight
xcodegen generate
open SomaFlight.xcodeproj
```

`project.yml` defines the targets: `SomaFlight-iOS` (iPhone and iPad, with the widgets, the share extension and the Watch app embedded), `SomaFlight-macOS`, `SomaFlightWidgets`, `SomaFlightShare`, `SomaFlightWatch` and `SomaFlightComplications`. The `.xcodeproj` is generated and git ignored.

### Run on fakes

Edit the iOS scheme, add the launch argument `-useFakes YES`, run on a simulator. Every screen fills with demo data, including a demo boarding pass. `-fakeNoProvider` shows the state with no paid data plan.

### Run against a backend

Run `supabase start` in the repository; Debug configs already point at `http://127.0.0.1:58321`. For a hosted project, put `SUPABASE_URL` and `SUPABASE_ANON_KEY` in a git-ignored `Config.local.xcconfig` next to `Apps/iOS/Config.Release.xcconfig`. Release builds refuse to start without it.

Sign in with Apple needs a provisioning profile with that capability. The Mac Debug build leaves the capability out, so only email sign-in works there.

## Tests

```bash
swift test --package-path Packages/FlightKit          # FlightKit unit and snapshot tests
cd core && cargo test                                  # Rust core, rules pinned in core/fixtures
deno test -A supabase/functions                        # Edge Functions
supabase test db                                       # pgTAP tests in supabase/tests (local stack running)
cd Apps/Web && npm install && npm test                 # web app (Vitest)
```

UI tests (`SomaFlight-iOSUITests`) run on the iPhone simulator with the fakes. `Scripts/check-strings.py` checks the app's strings.

## Change the Rust core

`core/flightcore` holds the logic shared by every platform (passport stats, predictions, weather impact, geo). After a change:

```bash
core/scripts/build-xcframework.sh   # Swift binding in Packages/FlightCoreFFI
core/scripts/build-wasm.sh          # Deno package for the Edge Functions
core/scripts/build-wasm.sh --web    # browser package for Apps/Web
```

The generated packages are committed.

## Build the web app

```bash
cd Apps/Web
cp .env.example .env.local   # Supabase URL and publishable key
npm install
npm run dev                  # http://localhost:5173
npm run build
```

The web app is a first cut of the same app in the browser (Vite, React 19, TypeScript, Tailwind 4, shadcn/ui). See [its README](../../Apps/Web/README.md).

## Related

- [Self-host the backend on Supabase](self-host-supabase-backend.md)
- [Flight data providers](flight-data-providers.md)
- [AGENTS.md](../../AGENTS.md) for coding agents
- [README](../../README.md)
