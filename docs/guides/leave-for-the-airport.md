# When to leave for the airport

Soma Flight shows a "Leave by" time on the flight sheet. When every part is known it is computed backwards from the boarding call: the walk to the gate, the security queue, a bag drop margin and the drive from where you are. When a part is missing it falls back to a fixed rule: 3 hours before an international flight, 2 hours before a domestic one. The breakdown says which parts were used and why a fixed rule was used instead.

## How the computed time is built

Working backwards from the scheduled departure (`Packages/FlightKit/Sources/FlightKit/Reminders/LeaveTime.swift`):

| Part | Rule |
|---|---|
| Boarding call | 40 minutes before departure for a wide-body, 30 for a narrow-body (from the aircraft type) |
| Walk to the gate | Typical minutes from the main checkpoint to the gate's concourse, from the [gate walk table](../gate-walk-times.md); 10, 6 or 3 minutes at a large, medium or small airport outside the table |
| Security queue | The shortest queue for the flight's terminal from `security-wait` (US airports). Uses the PreCheck lane when you turn on "I have TSA PreCheck" in Settings |
| Bag drop margin | 45 minutes international, 30 domestic. Always counted, since a boarding pass does not say whether you check a bag |
| Drive | MapKit driving time from your current location to the departure airport |

## When it falls back to the fixed rule

The breakdown's last line gives the reason:

- location is not allowed;
- the flight leaves more than 12 hours from now (where you are now says little about the drive on the day);
- the aircraft type is not known, so neither is the boarding call;
- the departure airport has no security figure (outside the US, or the call failed);
- MapKit found no route or had no network;
- the departure airport is not in the app's list.

## Privacy

Location is asked only for this feature. The drive and the queue are measured in the foreground, only while the flight sheet is open, and re-measured after 10 minutes. The location never leaves the device; only the airport code goes to `security-wait`.

## Where the security wait comes from

`security-wait` answers per checkpoint for US airports. No public live feed may be reused, so the figure is an estimate from TSA's published checkpoint throughput (passengers screened per airport, checkpoint and hour, from the TSA FOIA Reading Room), marked as an estimate in the app. Sources and the reasoning are in [Data sources, Security wait times](../data-sources.md#security-wait-times).

## Related

- [How to track a flight](track-a-flight.md)
- [Will I make my connection?](connection-at-risk.md)
- [Gate walk times](../gate-walk-times.md)
- [README](../../README.md)
