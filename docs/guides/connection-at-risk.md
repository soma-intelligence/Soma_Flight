# Will I make my connection?

When you follow two flights where the first lands at the airport the second leaves from (within 24 hours), Soma Flight pairs them and shows a Connection card on the flight sheet: the time on the ground from the first flight's best arrival to the second's best departure, compared with the usual minimum connection time at that airport. If the layover falls under that minimum ("At risk") or under 15 minutes ("Missed"), you also get a "connection at risk" push.

## How a connection is judged

- **Pairing.** Two followed flights connect when the first lands where the second leaves from and the second is scheduled to leave after the first lands, within 24 hours. A flight back to where the first came from counts as a return trip.
- **Best times.** Actual times when known, else estimates, else the schedule, so the verdict moves with delays.
- **Minimum connection time.** Typical figures for the 40 busiest airports by passengers, by kind of connection: domestic to domestic, domestic to international, international to domestic, international to international. Flights within the Schengen area count as domestic. Other airports use defaults. The table is `Packages/FlightKit/Sources/FlightKit/Resources/Reference/connection_rules.json`.
- **Transfer steps.** The card lists what you do between the gates, each with typical minutes: deplaning, immigration, customs and bag recheck, exit passport control, a transfer to another terminal, security screening again and the walk to the gate.

These are typical planning figures. Your airline's official minimum connection time and rules decide whether a booked connection is protected.

## The alert

`connection_at_risk` is sent once per pair, only to people who follow both flights. It is not sent when the first flight is canceled or diverted, or when the onward flight is canceled or already left, since those have their own alerts. The backend reads a copy of the same rules file (`supabase/functions/_shared/connection_rules.json`), and a test fails when the two copies differ, so the card and the push never disagree.

## Tips

- Follow both legs. A connection is only seen between flights you follow.
- Importing a confirmation email follows each upcoming leg it finds (legs more than two days ahead wait on the device until they are in reach), so the connection is paired for you. See [How to import past flights](import-past-flights.md).

## Related

- [Which flight alerts Soma Flight sends](flight-alerts.md)
- [When to leave for the airport](leave-for-the-airport.md)
- [How to track a flight](track-a-flight.md)
- [README](../../README.md)
