# Alerts by text message (design, OFF)

Status 2026-10-31: plumbing only, disabled. Nothing sends a text. Turning it on is the owner's call (GOAL.md: no paid call, no deploy without a yes).

## What it is

Opt-in: a traveller adds a phone number in Settings, proves it with a six digit code, and from then on the alerts that change what they do next also arrive as an iMessage or SMS from the Soma Linq line, next to the push. Same alert, same copy, same per-category switches. Push stays the main channel; texts are for people who keep notifications off or travel with a second phone.

## What is built

- `supabase/migrations/20261031000024_sms_alerts.sql`: one row per account (`sms_alerts`): E.164 number, code hash and expiry, tries, `verified_at`, `enabled`, `opted_out_at`. Checks: E.164 only; a code has its expiry; `enabled` needs a verified number and no STOP; a number is verified for one account only. RLS: owners read their own row (never the hash) and may delete it; every other write is service role. Account deletion cascades. Checked on a scratch Postgres 17; pgTAP file `supabase/tests/sms_alerts_test.sql`.
- `supabase/functions/_shared/sms_alerts.ts` (tests beside it, 12): the `SMS_ALERTS_ENABLED` flag (only the exact string "true" is on), `normalisePhone`, `newCode` (CSPRNG), `hashCode` (SHA-256 of number, code and a server secret), `checkCode` (10 minutes, 5 tries), `canText`, `wantsSms` (departure delay of 30 minutes or more, gate change, cancel, diversion, connection at risk), `smsText` ("Soma Flight: ... Reply STOP to stop.", under 300 characters), `planSms` (pure), the `SmsSender` interface and `smsHook`.
- `push-sender/handler.ts`: `deliver` calls `smsHook(ctx.sms, alert, text, users, muted)` for each alert it won. `index.ts` passes no `sms` deps, so the hook returns `disabled` before reading a row. With the flag on but no sender it returns `no_sender`. No Linq client exists in the repo.

## What turning it on needs

1. Owner's yes on cost and on Linq's terms for app alerts (the line is shared with the Soma companion; 20 contacts on the free plan today, so a paid plan first).
2. A `LinqSender implements SmsSender` against Linq's API, with its key as a secret, retried once, never logging the number or the text.
3. An `sms-verify` function (signed in): `start` normalises the number, refuses one verified elsewhere, writes a fresh hash and expiry, resets tries and sends the code through the sender; `check` runs `checkCode`, counts a wrong try, sets `verified_at` and `enabled` on success. Rate limit per account and per number (3 codes an hour).
4. A Linq inbound webhook for STOP, STOPALL, UNSUBSCRIBE, CANCEL, END, QUIT: sets `opted_out_at`, `enabled = false`, replies once. HELP replies with the support link. START only through a new verification in the app.
5. App: Settings > Notifications > "Text Me Too" (number field, code field, switch, "Forget My Number" which deletes the row). Copy says the number is used for alerts only.
6. Privacy: App Store label adds Phone Number (App Functionality, linked to the user); privacy policy names Linq as the processor. US A2P rules for the line (10DLC registration or toll-free verification) if Linq routes over SMS.
7. Set `SMS_ALERTS_ENABLED=true` and pass `sms: { db, sender: new LinqSender(...) }` in `push-sender/index.ts`.

## Out of scope

Answering questions by text ("is my flight on time?"), which would route through the companion with AeroAPI cache reads: possible later, not part of alerts.
