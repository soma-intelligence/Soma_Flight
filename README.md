# Soma Flight

A flight tracker for iPhone and Mac by Soma Labs. It tells you what is happening to your flight before the airline does, keeps a record of every flight you take, and never sells, reads or tracks anything about you.

See [GOAL.md](GOAL.md) for where the project is heading.

## Layout

- `Apps/`: the iOS and macOS app targets (generate the Xcode project with `xcodegen` from `project.yml`).
- `Packages/FlightKit`: the shared SwiftUI app, services and tests.
- `core/` and `Packages/FlightCoreFFI`: the Rust core and its Swift bindings.
- `supabase/`: migrations, seed data and Deno Edge Functions for the backend.
- `docs/`: API contract, operations, data sources and design notes.

## Running it

Debug builds run on fakes and need no account or key. To use a backend, run `supabase start` in this folder and point `Apps/*/Config.Debug.xcconfig` at it. Release builds refuse to start without real configuration.

## Licence

The code is released under the GNU Affero General Public License v3.0, see [LICENSE](LICENSE). Airline names, logos and other third-party marks are not covered by that licence: see [NOTICE](NOTICE).
