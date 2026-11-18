# New strings from the home, search and shell fixes (2026-11-18)

Strings the home, search and shell screens now show or speak that are not in `Apps/Shared/Localizable.xcstrings` yet. The catalog is edited by another agent: add these keys there. French uses "tu". Keys with `%@` are format keys built with `String(localized:)`.

## My Flights

| English key | French |
|---|---|
| `Stop Following %@` | `Ne plus suivre %@` |
| `Remove this planned flight?` | `Retirer ce vol prévu ?` |
| `Remove Planned Flight` | `Retirer le vol prévu` |
| `%@ on %@ leaves My Flights. This can't be undone.` | `%1$@ du %2$@ quitte Mes vols. Tu ne pourras pas l'annuler.` |
| `Shows the options for this planned flight` | `Affiche les options de ce vol prévu` |
| `Planned` | `Prévu` |
| `PLANNED` | `PRÉVU` |
| `est.` | `est.` |

`Stop Following` itself is already in the catalog (`Ne plus suivre`).

The countdown words under the big figure of a row are drawn through the catalog (`Text(ui:)`) and are now also spoken through it, but have no entry yet:

| English key | French |
|---|---|
| `DAY` | `JOUR` |
| `DAYS` | `JOURS` |
| `HR` | `H` |
| `HRS` | `H` |
| `MIN` | `MIN` |
| `LEFT` | `RESTANT` |
| `LANDED` | `ATTERRI` |
| `CANCELED` | `ANNULÉ` |
| `DIVERTED` | `DÉROUTÉ` |
| `ARRIVING` | `À L'ARRIVÉE` |
| `DEPARTING` | `AU DÉPART` |
| `SCHEDULED` | `PRÉVU` |

## Search: no result (D6)

| English key | French |
|---|---|
| `No flight with this number` | `Aucun vol avec ce numéro` |
| `No flights on this route` | `Aucun vol sur ce trajet` |
| `No flights at this airport` | `Aucun vol dans cet aéroport` |
| `No flights for this airline` | `Aucun vol pour cette compagnie` |
| `No flights found` | `Aucun vol trouvé` |
| `Check the number, or try another day.` | `Vérifie le numéro, ou essaie un autre jour.` |
| `Try another day, or search one of the airports for all its flights.` | `Essaie un autre jour, ou cherche un des aéroports pour voir tous ses vols.` |
| `Try another day, or add where you're flying to.` | `Essaie un autre jour, ou ajoute ta destination.` |
| `Add the flight number, or where it flies.` | `Ajoute le numéro du vol, ou sa destination.` |
| `Try a flight number like AF 84, or two cities like Paris Rome.` | `Essaie un numéro de vol comme AF 84, ou deux villes comme Paris Rome.` |

## Reused keys (already in the catalog)

- `Offline · last updated %@`: the offline pill with the list's age (E2).
- `Updated %@`, `Last update %@`: `StaleBadge` under the My Flights header (E1, E2).
- `%@ to %@`: the spoken route of a row (A1).
- `Loading`: the launch spinner (E16).
- `Sign In`: the banners' pill for an expired session (E3).
