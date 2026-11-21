# How to export your flight history from Soma Flight

Soma Flight exports your whole flight history (Passport) as JSON or CSV from Settings, under Your Data: "Export History as JSON" or "Export History as CSV". The file is built on the device from your past flights and nothing is sent anywhere until you pick a destination in the share sheet. The CSV imports back into Soma Flight, and opens in Excel, Numbers or Google Sheets.

## Formats

### CSV

One flight per row, RFC 4180 (CRLF between records, quoted fields where needed), UTF-8 with a byte order mark so Excel reads non-ASCII airline names correctly. Columns:

```
date,flight,from,to,airline,aircraft,registration,seat,distance_km,block_minutes,delay_minutes,status,arrival_delay_minutes,departure_delay_minutes
```

| Column | Meaning |
|---|---|
| `date` | Departure, ISO 8601 in UTC (`2025-03-14T06:05:00Z`) |
| `flight` | Flight number as the app writes it (`AF84`) |
| `from`, `to` | ICAO airport codes (`LFPG`, `KSFO`) |
| `airline`, `aircraft`, `registration`, `seat` | As stored; empty when unknown |
| `distance_km` | Great circle distance |
| `block_minutes` | Gate to gate time, when known |
| `delay_minutes` | Arrival delay |
| `status` | `completed`, `canceled` or `diverted` |
| `arrival_delay_minutes`, `departure_delay_minutes` | Signed delays; negative means early |

A text cell that a spreadsheet would run as a formula (starting with `=`, `+`, `-`, `@`, a tab or CR) gets a leading single quote. Code: `Packages/FlightKit/Sources/FlightKit/Services/PastFlightExport.swift`.

### JSON

An array of past flights with snake_case keys like the backend, pretty printed with sorted keys, dates as whole-second ISO 8601 in UTC.

## Steps

1. Open **Settings** and go to **Your Data**.
2. Tap **Export History as JSON** or **Export History as CSV**.
3. Pick a destination in the share sheet: Files, Mail, AirDrop, another app.

Deleting your account offers "Export My History First" before anything is deleted.

## Re-importing

The CSV export reads back through Import > **From a CSV File**; rows already in the history are marked as duplicates (same day and route). See [How to import past flights](import-past-flights.md).

## Related

- [How to import past flights](import-past-flights.md)
- [Flight passport and lifetime stats](flight-passport-stats.md)
- [README](../../README.md)
