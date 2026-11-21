# How to import past flights into Soma Flight

Open Import in Soma Flight and pick a source: the CSV file another tracker exports (Flighty's "Export Flights"), any CSV file with a date, a from and a to column, your calendar, or a confirmation email. The app reads the source on the device, shows every flight it found and why any row is skipped, then adds the past flights you tick to your Passport and follows the upcoming ones. Emails and calendar events are never uploaded; only the flights you add are saved to your account.

## Sources

| Source | What it reads | Code |
|---|---|---|
| Import from Flighty | The CSV from that app's settings, "Export Flights". Columns found by name in any order; `Date`, `Airline`, `Flight`, `From`, `To` are required. Times, gates, terminals, tail number, seat, cabin class, flight reason and notes are kept when present | `Packages/FlightKit/Sources/FlightKit/Imports/FlightyImport.swift` |
| From a CSV file | Any CSV with at least a date, a from and a to column, headers matched loosely (see below). Soma Flight's own CSV export reads back the same way | `Packages/FlightKit/Sources/FlightKit/Services/PastFlightImport.swift` |
| From your calendar | Events that name a flight: the ones airlines and booking sites add ("Flight to Paris (AF 84)") and ones you write ("AF 84", "SFO → CDG", "Vol AF84 CDG-SFO"). Two years back and a year ahead by default. The app's own synced events are skipped | `Imports/CalendarFlightMatcher.swift` |
| From a confirmation email | The email's schema.org `FlightReservation` markup (JSON-LD, then microdata), else its text and its PDF itinerary. Passenger names, prices and addresses are never read | `Packages/FlightKit/Sources/FlightImportKit/EmailFlightReader.swift` |

Soma Flight is not affiliated with Flighty; the importer only reads the file format its export writes.

## Steps

1. Open **Import flights**: the Import chip on Passport, or the "Import flights" row in Search.
2. Pick a source:
   - **Import from Flighty** or **From a CSV File**: the file picker opens. Files in iCloud Drive are downloaded first. Files up to 10 MB are read (a 5,000 flight export is about 3 MB).
   - **From Your Calendar**: grant calendar access when asked.
   - **From a Confirmation Email**: share the email to Soma Flight from Mail (Share > Soma Flight), or paste its text. A shared `.eml` or PDF also works.
3. Review the list. Each row says what it will do: go into the history, get followed, already present, or why it cannot be added. Values that did not read are listed ("Seat “aisle” left out").
4. Confirm. Past flights go into the history in batches of 50 (2,000 flights take 40 requests), with a progress bar. You can leave the app; a notification says when it is done.

## Generic CSV columns

Header names are compared in lower case with accents, spaces and punctuation removed, so "Departure Airport" matches `departureairport`.

| Field | Header names accepted |
|---|---|
| Date (required) | `date`, `flight date`, `departure date`, `dep date`, `date of flight`, `day`, `local date`, or any header containing "date" |
| From (required) | `from`, `origin`, `departure airport`, `dep airport`, `departure`, `dep`, `origin icao`, `origin iata`, ... |
| To (required) | `to`, `destination`, `arrival airport`, `arr airport`, `arrival`, `arr`, `dest`, ... |
| Time | `time`, `departure time`, `dep time`, `local time` |
| Flight number | `flight`, `flight number`, `flight no`, `ident`, `number` |
| Airline | `airline`, `carrier`, `operator`, `airline code` |
| Aircraft | `aircraft`, `aircraft type`, `type`, `plane`, `equipment`, `model` |
| Registration | `registration`, `reg`, `tail`, `tail number` |
| Seat, class, reason, notes | `seat`, `class`/`cabin`, `reason`/`purpose`, `notes`/`comments` |

Dates read as ISO 8601 with a zone (`2025-03-14T06:05:00Z`), year first (`2025-03-14`, `2025/03/14`) or year last (`14.03.2025`, `03/14/2025`), with an optional `HH:mm`. For `a/b/yyyy` the file decides day-first once any first number is above 12. A day without a zone is read in the origin airport's zone, at noon without a time. Airport cells may be a code (`SFO`, `lfpg`), a name with codes in brackets (`Paris / Charles de Gaulle (CDG/LFPG)`) or a code followed by a name.

## Duplicates and upcoming flights

- A row on the same day and route as a flight already in the history, or as an earlier row of the file, is shown as a duplicate and not added.
- Upcoming flights are followed. A flight lookup reaches two days ahead, so later flights wait on the device (listed under "Waiting to follow") and are followed automatically once in reach. Nothing is sent while they wait.

## Boarding passes

Opening a Wallet boarding pass (`.pkpass`) or a picture of a boarding pass barcode (IATA BCBP in PDF417, Aztec or QR) finds the flight, offers to follow it and keeps the pass with it on the device, never on the server. It works offline at the gate. Once flown, the flight moves to Passport like any other.

## Adding one flight by hand

Passport > **Add Past Flight** takes a day, two airports and optional flight number, airline, aircraft, seat and class. Mark a flight private to keep no flight number or airline.

## Related

- [How to export your flight history](export-flight-history.md)
- [Flight passport and lifetime stats](flight-passport-stats.md)
- [How to track a flight](track-a-flight.md)
- [README](../../README.md)
