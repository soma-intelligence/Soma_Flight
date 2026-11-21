# How to self-host the Soma Flight backend on Supabase

The Soma Flight backend is a Supabase project kept in `supabase/`: Postgres migrations with row level security, seed data for airports, airlines and aircraft, pgTAP tests and Deno Edge Functions. Run it locally with `supabase start`, or on your own hosted Supabase project with `supabase db push` and `supabase functions deploy`, then point the apps at it. Live flight data needs your own provider key (FlightAware AeroAPI by default); weather, FAA status and the flight log work without one.

## What you need

- The [Supabase CLI](https://supabase.com/docs/guides/local-development) and Docker (for the local stack and for bundling functions).
- For live flights: a FlightAware AeroAPI key. Its alert webhooks need the Standard tier; see [Flight data providers](flight-data-providers.md).
- For push alerts: an Apple Push Notifications key (`.p8`) for your app's bundle id.

## Run it locally

```bash
git clone https://github.com/soma-intelligence/Soma_Flight.git
cd Soma_Flight
supabase start        # API on http://127.0.0.1:58321, migrations and seed applied
supabase test db      # the pgTAP tests in supabase/tests
```

Debug builds of the apps already point at `http://127.0.0.1:58321` with the local stack's public demo anon key (`Apps/*/Config.Debug.xcconfig`). Functions run locally with `supabase functions serve`; their secrets go in `supabase/functions/.env.local`, which git ignores.

## Deploy to your own Supabase project

1. Create a project and link it: `supabase link --project-ref <ref>`.
2. Apply the schema: `supabase db push`. The migrations create the tables, row level security, pg_cron jobs, reference data and the functions' SQL helpers.
3. Deploy the functions: `supabase functions deploy`. Functions that run the Rust core ship its WASM as a static file (`static_files` in `supabase/config.toml`, the package in `supabase/functions/_shared/flightcore/pkg`); a function that imports it without that entry fails at boot.
4. Set the secrets the scheduled jobs read, once, in the SQL editor (never in a migration or a committed file):

   ```sql
   select vault.create_secret('https://<project-ref>.supabase.co/functions/v1', 'functions_base_url');
   select vault.create_secret('<service role key>', 'service_role_key');
   ```

5. Set the function secrets:

   ```bash
   supabase secrets set AEROAPI_KEY=... WEBHOOK_SECRET=<32+ random bytes> AEROAPI_DAILY_CAP_USD=50
   supabase secrets set APNS_TEAM_ID=... APNS_KEY_ID=... APNS_P8="$(cat AuthKey.p8)" APNS_BUNDLE_ID=<your bundle id>
   ```

   `APNS_SANDBOX` selects the APNs sandbox for development builds; a wrong value makes APNs refuse every token as `BadDeviceToken`.
6. Register the AeroAPI alert callback at FlightAware: `https://<project-ref>.supabase.co/functions/v1/aeroapi-webhook?secret=<WEBHOOK_SECRET>`. The callback has no signature, so the secret in the URL is the gate; rotate it with `WEBHOOK_SECRET_PREVIOUS` (see [provider check](../provider-check.md)).

## Point the apps at it

- **iOS, macOS, watchOS**: create `Apps/iOS/Config.local.xcconfig` (and `Apps/macOS/...`), git ignored, with your URL and anon key. Write the URL's slashes as `/$()/`, since xcconfig reads `//` as a comment:

  ```
  SUPABASE_URL = https:/$()/<project-ref>.supabase.co
  SUPABASE_ANON_KEY = <anon or publishable key>
  ```

  Release builds refuse to start without these, and refuse a plain http URL. Never put the service role key in an app config.
- **Web**: in `Apps/Web`, copy `.env.example` to `.env.local` and set `VITE_SUPABASE_URL` and `VITE_SUPABASE_PUBLISHABLE_KEY`. Add the web origin to the `WEB_ORIGINS` function secret for CORS.

## Optional features and their switches

| Feature | Backend switch | App switch |
|---|---|---|
| Arrival forecast, inbound plane, alternates | `AEROAPI_KEY` | `INSIGHTS_ENABLED` |
| Schedules days ahead | `flight-schedules` deployed | `SCHEDULES_ENABLED` |
| Nearby radar | `RADAR_ENABLED=true` and the radar migration | `RADAR_ENABLED` |
| FAA NOTAMs | `FAA_NOTAM_CLIENT_ID`, `FAA_NOTAM_CLIENT_SECRET` (free FAA key) | none |
| Airline logos | `LOGO_PROVIDER` and a licensed key | none |
| Web globe (MapKit JS) | `MAPKIT_KEY_ID`, `MAPKIT_TEAM_ID`, `MAPKIT_PRIVATE_KEY` | none |
| Favourite airport alerts | `FAVORITE_AIRPORT_ALERTS_ENABLED=true` | none |

All of these are off or answer "unavailable" until configured, and the apps hide what is not available. The full list of secrets is in [Backend operations](../operations.md#function-secrets).

## Keep it running

- pg_cron jobs archive landed flights every hour, prune caches nightly, sweep FAA programs every 5 minutes and, for a provider without webhooks, poll followed flights. List them with `select jobname, schedule from cron.job;`.
- `AEROAPI_DAILY_CAP_USD` stops provider calls for the rest of the UTC day once the estimated spend reaches it; cached answers keep being served.
- No function in `public` is callable by `anon` or `authenticated`; `supabase/tests/archive_test.sql` fails if one becomes so.

Details: [Backend operations](../operations.md) and the [API contract](../api-contract.md).

## License

The backend is AGPL-3.0 like the rest of the code. If you run a modified version as a network service for others, the AGPL asks you to offer them its source. Airline logos and marks are not covered; see [NOTICE](../../NOTICE).

## Related

- [Flight data providers and which are free](flight-data-providers.md)
- [Build Soma Flight from source](build-from-source.md)
- [README](../../README.md)
