# Soma Flight: global goal

Set 2026-10-31. Every plan, spec and session on this repo serves this goal. When a task does not move it forward, say so before doing it.

## The goal

**Ship Soma Flight to the public App Store (iPhone and Mac) as the most trustworthy flight tracker a traveller can carry: it tells you what is happening to your flight before the airline does, it keeps a beautiful record of every flight you take, and it never sells, reads or tracks anything about you.**

## What "done" means

The goal is reached when all of these are true at the same time:

1. **Live on the App Store.** Soma Flight for iOS and macOS passed App Review and is downloadable, built from `main`, signed with the Soma Labs team.
2. **Real data in production.** The Supabase project `soma-flight` runs the backend on FlightAware AeroAPI (Standard tier, B2C terms read and met); no screen in a Release build runs on fakes or fixtures.
3. **Proactive, not just reactive.** Gate, delay, cancel, boarding and inbound-plane alerts reach the phone as a push and a Live Activity update within about a minute of the provider alert, with no per-user polling.
4. **History people keep.** Landed flights move to Passport on their own; past flights can be added, edited, imported (CSV) and exported (JSON, CSV).
5. **Bounded cost.** AeroAPI spend stays under the daily cap with shared caching and per-user limits, and the owner gets an email before the cap is hit.
6. **Clean legally.** Privacy policy and support pages answer at `somalabs.me/privacy` and `somalabs.me/support`; account deletion revokes the Apple token; every logo, livery and side view shown is licensed, public domain or ours, and trademark use is cleared.

## Principles (hold on every task)

- **Privacy first.** No ads, no analytics SDK, no tracking, no mailbox access (email import reads only an email the user shares or forwards, on the phone), no contacts, no precise location unless a feature needs it and the user turns it on. Data collected = what the App Store privacy manifest already declares.
- **Our own product.** Inspired by the reference screenshots, never their name, copy, marks or artwork. We never draw an airline trademark ourselves.
- **Ask before money or deploys.** No paid key, licence, purchase, Supabase cloud change or deploy without the owner's explicit yes.
- **Fail closed.** Release builds refuse to run without real config; a missing licence shows a monogram, not a borrowed mark.
- **One codebase.** Rust `flightcore` for logic, `FlightKit` for the shared Swift layer; iOS, macOS, Watch and widgets are shells over it.

## Priority order

Work in this order. A lower line waits until the line above is done or blocked on the owner.

1. **Release blockers** in [docs/app-store-checklist.md](docs/app-store-checklist.md): Apple agreement and profiles, privacy and support pages, Apple token revocation, AeroAPI terms, review demo account, real-device checks.
2. **Production switch-on**: backend plan Task 10 (Supabase project, secrets, `db push`, `functions deploy`, AeroAPI webhook) and `INSIGHTS_ENABLED` in Release, on the owner's yes.
3. **Proactive layer** (audit P1): more push types, calendar sync, computed "leave now" time.
4. **Store presence**: real screenshots at the required sizes, metadata, age rating, review notes.
5. **Owner additions (2026-10-31)**: a Friends tab between My Flights and Passport; import from Flighty (its CSV export), from the calendar and from shared confirmation emails; ideas from the Soar comparison.
6. **After launch**: P2 and P3 items from [docs/audits/2026-10-30-flighty-pro-audit.md](docs/audits/2026-10-30-flighty-pro-audit.md) and [docs/audits/2026-10-30-soar-diff.md](docs/audits/2026-10-30-soar-diff.md).

## Out of scope until launch

Global radar, track replay, iPad and Vision Pro shells, TripIt import, paid tiers. They come back after the goal is reached.

## Owner actions

These sit with the owner and cannot be done by an agent:

- Apple Program License Agreement accepted by the account holder.
- AeroAPI Standard key and cost approval.
- Logo and side view licences (Airhex or another `LogoProvider`, a `SideViewProvider`), and counsel on airline trademarks.
- Publishing the privacy and support pages on the landing site.
- Every deploy and every purchase.
