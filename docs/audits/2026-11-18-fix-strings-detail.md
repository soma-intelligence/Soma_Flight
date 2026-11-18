# New strings from the detail, airport, radar, pass, import and weather fixes (2026-11-18)

Keys to add to `Apps/Shared/Localizable.xcstrings`. That file was not edited by this wave. The French uses "tu", like the rest of the catalog. Keys that are already in the catalog (Retry, Sign In, Cancel, Done, Close, Discard changes?, Discard Changes, Keep Editing, Your edits haven't been saved., Try Again, OK, Couldn't finish that, Updated %@, Last update %@, Open Settings, Stop Following, Booking Details, Booking Code, Seat, Could Not Stop Sharing, Could Not Follow, Boarding Pass) are not repeated here.

Paths are relative to `Packages/FlightKit/Sources/FlightKit/`.

## Flight sheet (`UI/Screens/FlightDetailView.swift`)

| English key | French | Where |
|---|---|---|
| Stop following %@? | Ne plus suivre %@ ? | Confirmation title when no Undo is on offer |
| Its booking code, seat and notes will be removed. | Son code de réservation, ton siège et tes notes seront supprimés. | Confirmation message |
| Couldn't Stop Following | Impossible d'arrêter de suivre ce vol | Failure alert title (I6) |
| Couldn't Change Alerts | Impossible de modifier les alertes | Alerts switch failure (I4) |
| Notifications Are Off | Les notifications sont coupées | Bell while the system drops alerts (E5) |
| Soma Flight can't alert you about this flight. Turn notifications on in Settings. | Soma Flight ne peut pas t'alerter pour ce vol. Active les notifications dans Réglages. | Same alert |
| Notifications are off in Settings | Les notifications sont coupées dans Réglages | VoiceOver hint on the bell |
| This flight is no longer available | Ce vol n'est plus disponible | Gone state (I7); also in the store note |
| The airline may have removed or renumbered it. Search for it again to follow the new one. | La compagnie l'a peut-être supprimé ou renuméroté. Cherche-le à nouveau pour suivre le nouveau. | Gone state |
| Some airport details couldn't load. They'll come back on the next refresh. | Certains détails de l'aéroport n'ont pas pu se charger. Ils reviendront à la prochaine actualisation. | Section note (E10) |
| This flight's updates couldn't load. They'll come back on the next refresh. | Les mises à jour de ce vol n'ont pas pu se charger. Elles reviendront à la prochaine actualisation. | Section note (E10) |
| FlightAware | FlightAware | Source at the foot of the sheet (D4), not translated |

## Detail editors (`UI/Detail/DetailTiles.swift`, `UI/Detail/BookingDetails.swift`)

| English key | French | Where |
|---|---|---|
| Notes | Notes | Notes sheet title and field label (listed missing in A2) |
| %lld of %lld | %lld sur %lld | Notes character count under the field |

## Sharing, connections, boarding pass

| English key | French | Where |
|---|---|---|
| The link still works. %@ | Le lien fonctionne toujours. %@ | `UI/Detail/FlightSharing.swift`, Stop Sharing failure |
| Choose Screenshot | Choisir une capture d'écran | `UI/BoardingPass/PassScannerSheet.swift`, camera refused (E17) |

## Import (`UI/Screens/Import/ImportView.swift`)

| English key | French | Where |
|---|---|---|
| The file couldn't be opened. Choose it again, or save it to Files first. | Impossible d'ouvrir le fichier. Choisis-le à nouveau, ou enregistre-le d'abord dans Fichiers. | File picker failure (D2) |
| The pasted text hasn't been read yet. | Le texte collé n'a pas encore été lu. | Close with unread pasted text (I2) |

## Formatted, no key needed

- Weather temperature and wind symbols (`°C`, `°F`, `km/h`, `mph`) and the spoken temperature come from `Measurement` in `FlightActivityDisplay.uiLocale`.
- The progress percent (`FlightProgressBar.spokenProgress`) and the Import dates (`ImportDates.day`) use `FormatStyle` in the same locale.
