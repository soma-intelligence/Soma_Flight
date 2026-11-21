# Which flight alerts Soma Flight sends

Soma Flight sends push alerts for a followed flight when its delay, gate, terminal, baggage belt or status changes, when it leaves, takes off, lands and arrives, when the inbound plane is late, when a delay is predicted, when a connection gets tight and when the FAA holds a US airport. Alerts come from provider events on the server (no polling by the phone), each one is sent once, and every category has its own switch in Settings > Notifications.

## The alerts

| Alert | Category | When it fires | Example text |
|---|---|---|---|
| Departure delay | Delays | Before gate out, the departure estimate is 15 min late, moves 15 min from the last one sent, or comes back on time | "AF 84 is now 25m late" |
| Arrival delay | Delays | After gate out, the same rule on the arrival estimate | "AF 84 now arrives 1h 20m late" |
| Schedule change | Delays | The scheduled departure or arrival moved | "AF 84 schedule changed" |
| Inbound late | Delays | The inbound plane arrives less than 30 min before this flight's scheduled departure | "AF 84 inbound plane is late" |
| Predicted delay | Delays | Before any delay alert, the Rust core's `predict_delay` gives a medium or high confidence delay from data the backend already holds | "AF 84 likely 25 min late" |
| Connection at risk | Delays | You follow both legs and the layover falls under the airport's usual minimum, or under 15 min | "AF 84 connection at risk" |
| Airport program | Delays | A ground stop, ground delay program or closure at either US airport holds the flight | "Ground delay program at SFO" |
| Early departure | Delays | Left the gate 10 min or more early | "AF 84 left 15m early" |
| Long taxi | Delays | Took off 30 min or more after leaving the gate | "AF 84 taxied 34m before take-off" |
| Gate assigned, gate change | Gates | First gate, or a move | "Gate changed to G91" |
| Terminal change | Gates | A terminal moved | "Terminal changed to 2F" |
| Baggage belt | Baggage | First belt, or a move | "Bags on belt 4" |
| Departed, takeoff, landing, arrived | Takeoff and landing | Each actual time, once | "AF 84 landed" |
| Cancel, reinstated | Cancellations | Status became or left canceled | "AF 84 canceled" |
| Diversion | Cancellations | Status became diverted, or the diversion airport moved | "AF 84 diverted to KOAK" |
| Aircraft change | Aircraft | Type or registration changed before gate out | "AF 84 has a different aircraft type" |

Boarding alerts exist in code but stay dormant: no provider in use sends a boarding time.

## How they are delivered

- `push-sender` turns each flight event into alerts (`supabase/functions/_shared/alerts.ts`, words in `_shared/alert_copy.ts`), claims each one in `alert_log` so a retry never sends it twice, and sends it over APNs to the followers who have alerts on for that flight and that category.
- The same event updates the Live Activity.
- Pushes for one flight are grouped by `thread-id` (the flight id), and repeated updates of the same alert collapse (`apns-collapse-id`).
- FAA programs come from a pg_cron sweep (`faa-status?mode=sweep`, every 5 minutes) of the FAA's free NAS status feed.

Favourite airports can also get a push for an FAA program at that airport. That sweep is off on the server unless the function secret `FAVORITE_AIRPORT_ALERTS_ENABLED` is `true`; see the [API contract](../api-contract.md#favorite-airports).

The full rules, keys and edge cases are in the [API contract, Push alerts](../api-contract.md#push-alerts).

## Related

- [How to track a flight](track-a-flight.md)
- [Will I make my connection?](connection-at-risk.md)
- [Airport weather, METAR and FAA status](airport-weather-metar.md)
- [README](../../README.md)
