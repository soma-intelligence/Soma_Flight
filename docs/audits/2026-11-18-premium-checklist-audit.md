# Audit Soma Flight iOS contre la checklist premium (2026-11-18)

Grille appliquée : `Soma_Tools/penpot-lab/docs/ios-premium-checklist.md`, la même que pour OnePass RX. Elle couvre les sections 2 à 12 et la matrice de validation par écran. Les priorités suivent sa section 14 :

- **P0, fiabilité** : perte de saisie, action sans retour, doublon, erreur sans issue.
- **P1, cohérence** : les mêmes décisions donnent le même résultat partout.
- **P2, adaptation** : grandes polices, VoiceOver, contraste, localisation.
- **P3, signature** : détails de marque.

Base auditée : `main` au commit `4d5bcf4`, la refonte « Flight refined ».

Méthode :

- Quatre lectures du code, en parallèle, une par famille de sections :
  - les états et le réseau ;
  - les boutons, la navigation et les formulaires ;
  - l'accessibilité, le mouvement et le verre ;
  - les fondations, les listes, les textes et le catalogue.
- Une passe sur le simulateur « Flight Parity » (iPhone 17 Pro Max, `-useFakes`) avec :
  - la plus grande taille d'accessibilité ;
  - le français ;
  - le contraste augmenté.
- Les constats P0 ont été relus dans le code avant d'être retenus.

Les chemins sont relatifs à `Packages/FlightKit/Sources/FlightKit/`, sauf mention contraire.

## Résumé

| Priorité | Nombre | Thèmes |
|---|---|---|
| P0 | 11 | Cache non lu au démarrage, hors ligne qui ne se lève pas, session expirée sans issue, doubles envois, suppressions sans confirmation ni annulation, formulaires fermables sans garde, résultats de recherche périmés, message système brut |
| P1 | 30 | Retry qui relance la mauvaise action, panne serveur affichée comme « hors ligne », fraîcheur invisible, vocabulaire, tokens, éditeurs et clavier, tests visuels sans assertion |
| P2 | 14 | Français incomplet, contraste des couleurs de retard, Augmenter le contraste, Réduire les animations, grandes polices |
| P3 | 4 | Splash, haptique de succès, état pressé, détails |

Ce que l'app fait déjà bien :

- **Recherche** : elle écarte les suggestions périmées (compteur de génération, test de course).
- **Fiche vol** :
  - cache et pack hors ligne ;
  - carte « Couldn't refresh » qui garde les données ;
  - retour en arrière si l'enregistrement des alertes ou des détails échoue.
- **Aéroport** : squelette ASCII et âge de chaque section.
- **Passeport** : il lit le cache d'abord.
- **Estimé ou mesuré** : toujours étiqueté (position en pointillés, « Airline estimate », « Estimate, offline », source METAR).
- **Permissions** : calendrier et localisation demandés en contexte, avec une explication avant d'envoyer vers Réglages.
- **Confirmations** : déconnexion et suppression de compte.
- **Formulaire Profil** : exemplaire (type de contenu, chaîne de focus, bouton stable avec spinner).
- **Dynamic Type** : `scaledFont` le suit, `MyFlightRow` a une mise en page pour les grandes tailles.
- **Taille des cibles** : 44 pt sur `CloseButton`, `RoundButton` et `MapControlCapsule`.
- **Reduce Motion** : respecté par huit composants.
- **Tutoiement** : cohérent dans les 153 chaînes françaises.
- **Catalogue de traductions** : 1429 clés, toutes traduites en français.
- **iPad et iPhone Duo** : chacun a sa mise en page.

## Statut des corrections (2026-11-18, même jour)

Les 59 constats ont été traités sur le checkout principal, non commité. Vérification :

- `swift test` sur FlightKit : 1540 tests dans 154 suites, tous verts.
- Build iOS `SomaFlight-iOS` réussi, installé sur « Flight Parity ».
- Nouvelle passe simulateur en AX5, en français et en contraste augmenté.

Nouveaux tests : `StoreAuditFixTests` (27), `HomeShellFixTests` (12), `SettingsAuditFixTests` (14), `SessionExpiryTests` (5), et `RefinedSnapshotTests` (27 cas, 52 références, swift-snapshot-testing 1.19.7).

Corrigés en entier : tous les constats sauf les cinq ci-dessous.

Corrigés en partie :

- **E14** : la Live Activity porte une date de péremption posée par l'app. Les pushes du backend n'en portent pas encore. Il faut l'ajouter côté serveur.
- **A1** : les statuts, dates, routes et phrases de l'app sont en français. Trois textes restent en anglais : le flux NOTAM, les phrases météo écrites par le cœur Rust, et les exemples de recherche (gardés exprès, ce sont des requêtes).
- **D10** : les snapshots tournent sur macOS. Le verre Liquid Glass n'y est pas rendu, donc les références ne le couvrent pas.
- **A12** : en plus du code ami, trois troncatures AX5 vues au deuxième passage sont corrigées : le badge de l'aéroport, le titre de la carte Passeport et les heures de Mes vols (l'heure prévue barrée passe à la ligne).
- Aucun contrôle sur un vrai appareil ni avec Accessibility Inspector.

Décisions de Quentin (2026-11-18) :

- **E2** : gardé. Une liste périmée affiche son âge, même en ligne. Cela remplace le choix du 2026-11-08.
- **E3** : gardé. Après une expiration de session, les données du compte restent sur l'appareil tant que la reconnexion est en attente. Elles partent si on abandonne ou si un autre compte se connecte.
- **Vol annulé** : gris partout (app, Amis, correspondances, widget, Watch), plus rouge. Le rouge reste réservé aux gros retards.
- **Seuil « Calme »** : une direction passe à « Modéré » dès 10 min de retard moyen, ou dès que plus de 25 % des vols ont 15 min de retard. La règle est dans le cœur Rust (`compute_stats`) et dans `AirportPerformance.delayStats`. Le xcframework et les deux paquets WASM sont recompilés. Rien n'est déployé sur Supabase.
- **Ajouter un ami** : un bouton « + » en verre revient dans l'en-tête des Amis, à côté de l'avatar. Le menu « … » de la carte du code garde l'entrée.

Notes de corrections par zone : `2026-11-18-fix-api-stores.md`, `2026-11-18-fix-api-kit.md`, `2026-11-18-fix-strings-home.md`, `2026-11-18-fix-strings-detail.md`, `2026-11-18-fix-strings-settings.md`.

## Matrice de validation par écran

O = conforme, P = partiel, X = manquant, n/a = sans objet. Une lettre entre parenthèses renvoie au constat.

| Écran | Première ouverture | Données normales | Aucun contenu | Contenu long | Réseau lent | Erreur réseau | Hors ligne | Retour après interruption | Mode sombre | Grandes polices | VoiceOver | Clavier | FR / EN |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| Mes vols | P (E1) | O | O | X (A13) | X (E1) | P (E6, E8) | P (E2) | P (E2) | O | P (A12) | P (A10) | n/a | X (A1) |
| Recherche | O | O | P (D8) | P | P | P (E6) | P (E8) | X (I11) | O | P (A12) | O | P | P (A1) |
| Fiche vol | O | O | n/a | P (A12) | O | P (E10, I4) | O | O | O | X (A12) | P | n/a | X (A1) |
| Aéroport | O | O | O | P | O | O | P (E18) | O | O | X (A9, A12) | P (A8) | n/a | X (A1) |
| Amis | O | O | O | X (A12) | P | P (E4, E6) | P (E18) | O | O | X (A12) | P (I8) | P | P |
| Passeport | O | O | O | P | O | O | P (E12) | O | O | P | O | P (I12) | P |
| Réglages, Notifications | P (E11) | O | n/a | P | P | P (E11) | P | O | O | P (A12) | O | n/a | P |
| Documents de voyage | O | O | O | P | n/a | P (I3) | P (E13) | X (I2) | O | ? | P | X (I5) | P |
| Éditeurs (notes, réservation, vol passé) | O | O | n/a | P | P | O | P | X (I2) | O | ? | P | X (I12) | P |

Le mode sombre est conforme sur les 13 écrans capturés le 17 novembre. Les cases « ? » n'ont pas été testées.

## Constats

Les identifiants suivent la famille du constat :

- **E** : états et réseau (sections 3 et 7).
- **I** : interactions, navigation et formulaires (sections 4 à 6).
- **A** : accessibilité, mouvement et verre (sections 9 et 10).
- **D** : fondations, listes, textes et catalogue (sections 2, 8, 11 et 12).

Les doublons entre familles ont été fusionnés.

### P0, fiabilité

**E1. L'accueil n'affiche pas les vols enregistrés avant la réponse du réseau.**
- **Aujourd'hui** : `MyFlightsStore.load()` ne lit le cache qu'après un échec `.offline`, et seulement si la liste est vide (`Stores/MyFlightsStore.swift:98-111`).
- **Conséquence** : un lancement à froid sur un Wi-Fi d'aéroport lent montre un `ProgressView` nu (`UI/Screens/MyFlightsView.swift:148-152`) pendant jusqu'à 60 s. Une panne `.providerUnavailable` n'ouvre jamais le cache.
- **Correctif** : lire le cache d'abord, comme `PassportStore.load()` (`Stores/PassportStore.swift:146-148`), puis rafraîchir. Se replier sur le cache pour toute erreur.

**E2. « Offline » ne disparaît pas quand le réseau revient.**
- **Aujourd'hui** : `isOffline` n'est remis à zéro que par un `load()` réussi (`Stores/MyFlightsStore.swift:93`). Rien n'écoute le retour de `Connectivity.isOnline`. Hors ligne, `SectionFreshness` n'est pas monté (`UI/Screens/MyFlightsView.swift:129-136`).
- **Conséquence** : la pastille « Offline · positions estimated » et les « est. » restent affichés jusqu'à un geste manuel.
- **Correctif** : recharger quand la connexion revient et quand la scène redevient active. Remettre `isOffline` à faux sur une mise à jour poussée.

**E3. Session expirée : Retry tourne en rond et la reconnexion perd la saisie.**
- **Aujourd'hui** : `.unauthorized` affiche « Please sign in again. » (`UI/DelayColor.swift:24`), mais le bouton est un Retry qui refait la même requête (`MyFlightsView.swift:139`, `FriendsView.swift:98`, `PassportView.swift:140`). Quand la session tombe vraiment, `SignInGate` remplace tout l'arbre (`UI/Shell/ShellChrome.swift:363`) et les éditeurs ouverts perdent leur contenu.
- **Correctif** :
  - Tenter un rafraîchissement de session.
  - S'il échoue, présenter la connexion en feuille, par-dessus l'état courant.
  - Donner à `ErrorBanner` une action « Se connecter » au lieu de Retry.

**E4. Amis : double envoi possible.**
- **Aujourd'hui** : Accepter, Refuser, Annuler et Retirer lancent une `Task` sans état « en cours » ni `.disabled` (`UI/Screens/Friends/FriendsView.swift:66, 201-206, 223`, `FriendPageView.swift:44`). Les méthodes de `FriendsStore` n'ont pas de garde (`Stores/FriendsStore.swift:231-306`).
- **Conséquence** : un double tap sur Accepter finit sur une bannière d'erreur alors que l'acceptation a réussi.
- **Correctif** : un ensemble d'ids en cours, comme `SearchView.follow` (`SearchView.swift:396-408`), et le `LoadingButtonStyle` de I14.

**E5. Notifications refusées : l'app dit qu'elles sont actives.**
- **Aujourd'hui** : `PushCoordinator.didFollow` ignore `.denied` (`Push/PushCoordinator.swift:81`). La cloche du détail affiche « On » (`UI/Detail/DetailHeader.swift:176-181`), et les interrupteurs de l'écran Notifications restent tous actifs (`NotificationSettingsView.swift:80-83`).
- **Conséquence** : l'utilisateur croit qu'il sera prévenu d'un changement de porte.
- **Correctif** : exposer l'autorisation au store. Quand elle est refusée :
  - montrer la cloche éteinte ;
  - afficher une carte « Les notifications sont coupées » avec un bouton vers Réglages, comme celle du calendrier ;
  - griser les interrupteurs.

**I1. Supprimer un vol : pas de confirmation, pas d'annulation, et les détails sont perdus.**
- **Aujourd'hui** :
  - Un glissement complet supprime tout de suite (`UI/Screens/Shared/SwipeToDelete.swift:29-31, 93-101`).
  - Le menu contextuel aussi (`MyFlightsView.swift:189-195, 203-206`).
  - More, puis Delete Flight, appelle `stopTracking()` sans dialogue (`FlightDetailView.swift:452, 462-466`). Vérifié dans le code.
- **Perte de données** : le désabonnement efface le code de réservation, le siège et les notes (`Stores/FlightDetailStore.swift:405-407`).
- **Même absence de confirmation** : « Forget My Number » (`TextMeTooSection.swift:129-130`) et la suppression d'un numéro de fidélité (`TravelDocumentsView.swift:265`).
- **Correctif partagé** :
  - un toast avec action, `showToast(_:action:)` ;
  - l'appel `unfollow` retardé d'environ 5 s pour proposer « Annuler » ;
  - un modificateur `.confirmDestructive(...)` pour ce qui ne peut pas s'annuler.

**I2. Formulaires modifiés fermables sans protection.**
- **Aujourd'hui** :
  - `interactiveDismissDisabled` ne joue que pendant l'enregistrement, dans les notes (`UI/Detail/DetailTiles.swift:313`), la réservation (`BookingDetails.swift:108`) et le vol passé (`PastFlightEditor.swift:232`).
  - Aucune garde dans l'éditeur de documents (`TravelDocumentsView.swift:56-61`), le profil (`AccountProfileView.swift:64`) ni le texte collé dans Import (`ImportView.swift:317`).
  - Cancel jette les changements sans demander.
  - La feuille de réservation n'a que Done : un glissement vers le bas perd tout.
- **Correctif** : `.guardsUnsavedChanges(isDirty:)`, qui combine `interactiveDismissDisabled(isDirty || isSaving)` et un dialogue « Abandonner les modifications ? ».

**I3. Documents de voyage : suppression silencieuse et échec mal nommé.**
- **Aujourd'hui** :
  - Vider le champ supprime le numéro sans confirmation (`TravelDocumentsView.swift:312`, `TravelDocumentsStore.swift:162`).
  - Un échec du trousseau s'affiche comme une erreur de format (`TravelDocumentsView.swift:375`).
  - L'erreur n'est jamais effacée pendant la saisie.
  - La normalisation (majuscules, espaces retirés) est invisible, puisque seuls les 4 derniers caractères s'affichent.
  - Le pays est du texte libre.
- **Correctif** :
  - distinguer `.invalid` et `.failed` ;
  - confirmer avant de supprimer ;
  - montrer la valeur normalisée avant de valider ;
  - proposer un sélecteur de pays.

**I4. Échec du bouton Alerts présenté comme un échec de rafraîchissement.**
- **Aujourd'hui** : `setNotify` écrit dans `store.error` (`FlightDetailStore.swift:336-338`). La fiche affiche alors « Couldn't refresh », avec un Retry qui recharge la page sans retenter l'alerte (`FlightDetailView.swift:200-201`).
- **Correctif** : une erreur `notifyError` propre, avec un toast d'erreur dont le Retry rappelle `setNotify`.

**D1. Recherche : un ancien résultat peut s'afficher sous un nouveau texte.**
- **Aujourd'hui** : `textChanged()` annule `suggestTask` et `liveTask`, mais ni `searchTask` ni `searchGeneration` (`Stores/SearchStore.swift:169-205`). Vérifié dans le code.
- **Scénario** : on valide « AF84 », puis on tape un texte qui ne relance pas de recherche. La réponse AF84 passe la garde `gen == searchGeneration` (`:529`) et s'affiche sous le nouveau texte. `remember(text)` (`:538`) enregistre ensuite le nouveau texte dans les récents avec les anciens résultats.
- **Correctif** : dans `textChanged()`, quand la clé de route change, annuler `searchTask`, incrémenter `searchGeneration` et remettre `isSearching` à faux. Ajouter un test pour ce scénario.

**D2. Message système brut affiché à l'utilisateur.**
- **Aujourd'hui** : `ImportView.swift:91` affiche `"The file couldn't be opened: \(error.localizedDescription)"`. Ce texte n'est pas dans le catalogue, donc il reste en anglais en français. Les libellés VoiceOver préfixent un « Error: » en dur (`PastFlightEditor.swift:268, 424`, `DetailTiles.swift:380`, `BookingDetails.swift:244`, `PastFlightImportSheet.swift:107`).
- **Correctif** : une phrase localisée qui dit quoi faire, l'erreur technique dans le journal, et `accessibilityLabel(Text(ui: error))`.

### P1, cohérence

**E6. Retry relance la mauvaise action.** Une erreur d'action (ne plus suivre, suivre depuis la recherche, actions Amis) va dans la même `error` que le chargement, donc Retry recharge la liste (`MyFlightsStore.swift:153`, `SearchView.swift:296-297`). Correctif : une erreur d'action séparée, comme `FlightDetailStore.trackingError`.

**E7. Une panne serveur est affichée comme « You're offline ».** `.timedOut`, `.cannotConnectToHost` et `.cannotFindHost` comptent comme hors ligne (`Services/Supabase/SupabaseBackend.swift:134-136`). Correctif : hors ligne seulement si `Connectivity.isOnline == false`, sinon `.providerUnavailable`.

**E8. « Showing the last update » sans rien à montrer.** Le texte apparaît même sur la recherche, sur un aéroport sans cache et sur un accueil vide (`UI/DelayColor.swift:19, 25`). Hors ligne, un accueil vide dit « showing your saved flights » (`OfflineBanner.swift:13`). Correctif : `message(hasContent:)`.

**E9 + D4. Fraîcheur invisible.**
- `SectionFreshness` recharge mais n'affiche rien.
- `StaleBadge` n'est utilisé nulle part (code mort).
- La pastille hors ligne ne donne pas d'âge.
- `PassportStore.lastUpdated` n'est jamais lu.
- Sur la fiche vol, l'âge n'apparaît qu'en cas d'erreur (`FlightDetailView.swift:210`).
- La source du statut de vol n'est jamais nommée.

Correctif : « Mis à jour il y a X min » dès que le TTL est dépassé, et une ligne de source en pied de fiche.

**E10. Données partielles affichées comme un échec total.** `FlightDetailStore.load()` garde la première sous-erreur (événements, aéroports) même quand le vol s'est bien rafraîchi (`Stores/FlightDetailStore.swift:197-213`). Correctif : `error` seulement si le vol lui-même échoue.

**E11. Notifications : un chargement raté affiche les valeurs par défaut comme réelles.** `hasLoaded = true` après un échec (`NotificationSettingsStore.swift:52-56`), et la bannière n'a pas de Retry.

**E12. Passeport : hors ligne affiché comme une erreur ambre** (`PassportView.swift:136-137`). L'accueil utilise la pastille calme. Même composant attendu.

**E13. Documents : « sur tous tes appareils » même quand la synchro a échoué.** `pushToCloud` avale l'échec (`TravelDocumentsStore.swift:229-231`). Correctif : afficher « Pas encore synchronisé ».

**E14. Live Activity : une donnée figée a l'air vivante.** `staleDate` est réglé à l'arrivée + 1 h (`FlightActivityAttributes.swift:97`), et `context.isStale` n'est jamais lu (`Apps/Widgets/FlightLiveActivity.swift`).

**E15. Glisser pour supprimer : la ligne revient après 1,5 s quoi qu'il arrive** (`SwipeToDelete.swift:95-103`), sans garde contre le double appel. Correctif : garder la ligne masquée pendant l'appel et ne la rendre qu'en cas d'échec.

**E16. Premier lancement : écran noir sans issue** pendant `profile.gate == .unknown` (`ShellChrome.swift:366-367`, `Apps/iOS/SomaFlightApp.swift:39`). Correctif : un indicateur après 1 s et une attente plafonnée à 5 s.

**I5. Éditeur de documents : champs mal configurés** (`TravelDocumentsView.swift:325-334`).
- Libellés seulement en placeholder.
- `.textContentType(.oneTimeCode)` sur passeport, KTN et Redress, donc le clavier propose des codes SMS.
- Majuscules forcées sur « Airline code or name ».
- Pas de clavier numérique pour Redress.
- Pas de `submitLabel` ni de focus.
- Le X est en haut à droite, contre la règle des modales.

**I6. Alertes d'erreur limitées à « OK », sans Réessayer.** Sept endroits : `SettingsView.swift:374`, `PassportView.swift:113, 120`, `FlightDetailView.swift:103`, `ConnectionCard.swift:82`, `FlightSharing.swift:101`, `BoardingPassSection.swift:52`. Correctif : `.failureAlert(_:retry:)`.

**I7. Contenu supprimé : pas de destination de repli.** Une notification vers un vol introuvable est ignorée en silence (`HomeModel.swift:667`). La fiche affiche le texte pensé pour la recherche, « Check the number and date », avec un Retry inutile.

**I8. Cibles sous 44 pt.**

| Élément | Fichier | Taille |
|---|---|---|
| Refuser | `FriendsView.swift:201-203` | 32 pt |
| Accepter | `FriendsView.swift:208-209` | 31 pt de haut |
| Annuler (demande envoyée) | `FriendsView.swift:223` | taille du texte |
| « + » | `PassportCards.swift:410-413` | 34 pt |
| « … » du code ami | `FriendCodeRow.swift:79` | 28 pt de large |
| Send Code, Change, Verify | `TextMeTooSection.swift:64, 82, 93` | taille du texte |

Correctif : un modificateur partagé `.minTapTarget()`.

**I9. Un vol planifié ne se supprime que par un geste caché** : glissement ou appui long (`MyFlightsView.swift:198-207`).

**I10. Onglets et retour.**
- Retoucher l'onglet actif ne fait rien (`ShellChrome.swift:210-211`).
- `.id(tab)` reconstruit l'écran, donc la position de défilement est perdue (`HomeSheetBody.swift:33`).
- Le glissement depuis le bord gauche ne ferme que les vols passés (`CardStack.swift:69-71`).

**I11. Recherche perdue au retour.** Un nouveau store est créé à chaque ouverture, et ouvrir un résultat ferme la recherche (`Apps/iOS/RootTabView.swift:178-190, 239-243`).

**I12. Quatre façons d'éditer, et un clavier non géré.**
- Façons d'éditer :
  - Cancel et Save ;
  - Done seul ;
  - X et Save en ligne ;
  - un bouton en bas du profil.
- Clavier :
  - aucune barre clavier ;
  - pavés numériques sans Terminé (`PassportTools.swift:113-116`) ;
  - `phonePad` avec `.submitLabel(.send)`, donc `onSubmit` ne se déclenche jamais (`TextMeTooSection.swift:56-63`) ;
  - pas de chaîne de focus dans les éditeurs.
- Correctif :
  - un seul `SheetHeader.modal(leading: .cancel, onDone:, doneDisabled: !isDirty)` ;
  - un composant `FormField` dans `UI/Refined`.

**I13. Erreur de validation hors écran** : elle s'affiche en haut de `PastFlightEditor` (`:268-274`) sans faire défiler jusqu'au champ fautif.

**I14. Boutons sans état « en cours »** : Send Code, Verify, Accepter, Refuser. Correctif : `LoadingButtonStyle`, à largeur stable.

**D3. Vocabulaire.**
- « Delete Flight » désigne à la fois un désabonnement réversible (Mes vols, fiche vol) et une suppression définitive (Passeport).
- La carte radar dit « Stop Following ».
- « Remove Photo » et « Delete Photo » désignent le même objet.
- « trip » est traduit tantôt « trajet », tantôt « voyage ».
- Correctif : un glossaire. Suivre / Ne plus suivre, Supprimer pour le Passeport seulement, Retirer pour les liens.

**D5. Suppression du compte : conséquences incomplètes** (`SettingsView.swift:67-68`). Le texte ne cite ni les amis, ni les documents synchronisés, ni la photo. Il ne propose pas l'export qui existe déjà.

**D6. « Aucun résultat » affiché comme une erreur** : triangle ambre et « Check the number and date », même pour une route (`SearchStore.swift:536`, `SearchView.swift:218`). Correctif : un état vide neutre, adapté à ce qui a été cherché.

**D7. Rôles typographiques peu suivis.** 8 rôles `FontRole` sont utilisés 46 fois, contre 761 `scaledFont(taille)` avec 38 tailles différentes, et 71 `.font(.system(size:))` fixes. Correctif : étendre `FontRole`, migrer, et ajouter une règle de lint.

**D8. Espacements, rayons et ombres sans tokens.**
- Espacements : 38 valeurs de padding différentes.
- Rayons : environ 22, dont 4, 10, 14, 18 et 26 pour des cartes. `OfflineBanner` (18) et `ErrorBanner` (14) peuvent s'empiler.
- Ombres : 12, en 9 styles.
- Correctif : `Theme.Space`, `Theme.Radius`, deux tokens d'ombre, et `RefinedCard` partout.

**D9. Couleurs codées dans les écrans.**
- 109 littéraux hors `Theme`, la plupart des palettes locales assumées.
- Doublons de tokens : le jaune de porte redéfini (`DepartArrive.swift:309`), un « late » dupliqué (`DelayReportParts.swift:16`).
- `Color.red` brut au lieu de `Theme.veryLate` (`SwipeToDelete.swift:60`, `PassportTravelRules.swift:53`).

**D10. Les tests « snapshot » ne protègent de rien.**
- Le harnais maison `ImageRenderer` ne tourne que sur macOS, est coupé par défaut (`SNAPSHOTS == "1"`, `Tests/ComponentSnapshotTests.swift:19`) et écrit des PNG sans comparaison.
- Aucun composant de `Refined/` n'est rendu seul.
- Aucun cas grande police ni contenu extrême.
- Pas de galerie de composants.
- Correctif :
  - `swift-snapshot-testing` avec références commitées en CI ;
  - une `ComponentGallery` en Debug ;
  - des variantes `.accessibility3`, noms longs et emoji.

**A9. Deux barres d'actions en double.** `GlassActionBar` du kit ne sert que dans sa preview. Les écrans utilisent `DetailActionBar` (`FlightDetailView.swift:385`, `AirportView.swift:97`).

**A14. Le français reste approximatif, vu sur le simulateur.**
- « Du Paris au San Francisco » : l'article ne colle pas aux villes.
- Dates en anglais : « Wed, Nov 18 ».
- `DIVERTED` et `CANCELED` en capitales anglaises.
- « All-Time », « Distance and Time », « ALL-TIME SOMA FLIGHT PASSPORT » et « Tap to edit » non traduits.
- Correctif : un format de route sans article (« Paris → San Francisco » ou « De Paris à San Francisco »), dates par `Date.FormatStyle`, compléter le catalogue.

### P2, adaptation

**A1. Statuts composés en anglais en français.** C'est le défaut le plus visible : « Landing 11m late », « Departed 16m late · lands 14:46 », « 12m late · departs 11:49 · gate F11 », « Moderate », « Calm », « updated 07:55 ».
- Cause : `FlightStatusSummary` (`UI/Refined/FlightStatusSummary.swift:48-83`) et `BoardRow.statusText` (`UI/BoardRow.swift:37-50`) assemblent des chaînes anglaises, que `Text(ui:)` cherche ensuite entières dans le catalogue.
- `Format.ago` (« min ago ») et `FlightActivityDisplay.duration` ont le même défaut.
- Le libellé VoiceOver des lignes en hérite.
- Correctif : des clés à format, `Date.RelativeFormatStyle` et `Duration.formatted`, tout dans les trois helpers partagés.

**A2. Clés absentes du catalogue.** Exemples :
- « Retry » de la bannière d'erreur (`ErrorBanner.swift:81`) ;
- « Notes », « Examples », « Operations report », « Performance », « NOW », « or » ;
- les formats « Updated %@ », « Last update %@ » et « Importing %@ of %@ ».

Correctif : un script en CI qui échoue si un littéral `Text`, `Label` ou `Button` n'a pas de clé.

**A3. Couleurs de retard trop pâles en texte, en mode clair.** `StatusLine` et `BoardRow` écrivent le statut dans la couleur du retard. Contraste WCAG mesuré à partir de `Theme.swift` :

| Jeton | Sur carte claire #FFF | Sur fond clair #F2F2F7 | Sur carte sombre #202023 |
|---|---|---|---|
| late (ambre) | 2,35 | 2,10 | 8,83 |
| canceled | 3,26 | 2,92 | 16,25 |
| friend | 3,32 | 2,98 | 9,02 |
| onTime (vert) | 3,43 | 3,07 | 6,20 |
| accent | 4,02 | 3,60 | 4,46 |
| veryLate | 4,27 | 3,83 | 4,77 |
| secondary | 5,22 | 4,67 | 5,53 |

Seuil : 4,5. Correctif : des jetons « texte » plus foncés en mode clair (`lateText` vers `#9A6700`, `onTimeText` vers `#0B7A45`). Les teintes actuelles restent pour les points, les barres et les tracés.

**A4. Augmenter le contraste n'a aucun effet.** `colorSchemeContrast` n'est lu nulle part, et `Color(light:dark:)` ignore `accessibilityContrast` (`Theme.swift:175-177`). Confirmé sur le simulateur : l'ambre reste identique. Correctif : des variantes à fort contraste dans ce seul init.

**A5. Réduire les animations ignoré sur les grandes transitions.**
- Ouverture des cartes : `CardMotion.transition` (`UI/Shell/CardStack.swift:8-10`).
- Barre d'actions (`DetailActionBar.swift:58`) et changement d'onglet (`HomeSheetBody.swift:34`).
- Vols de caméra du globe de 0,8 à 0,9 s (`Map/GlobeMap.swift:431, 443, 545, 559`).
- Pictogramme d'import qui pulse en boucle (`ImportFlowViews.swift:131`).
- Correctif : `.opacity` à la place, et pas d'animation de caméra quand Reduce Motion est actif.

**A6. Barre d'onglets et boutons ronds à taille fixe, sans grand aperçu** (`ShellChrome.swift:193, 215, 218, 258`, `MapControlCapsule.swift:77-79`). Correctif : `.accessibilityShowsLargeContentViewer()`.

**A7. Radar : verre sur du contenu et verre dans du verre.**
- Cartes de contenu en verre (`Map/RadarView.swift:129, 205`).
- En-tête vitré qui contient des boutons vitrés (`RadarView.swift:76, 80, 105`).
- Aucun `GlassEffectContainer` dans tout le dépôt.
- Le X fait 32 pt.

**A8. Partager désactivé annoncé comme actif.** Il a seulement une opacité de 0,4, sans `.disabled` (`AirportView.swift:122-125`, `AirportDetailParts.swift:479`).

**A10. VoiceOver ne dit pas quelle heure est barrée.** `BoardRow` lit « 18:25 18:41 » sans distinguer prévu et réel (`BoardRow.swift:94, 101`).

**A11. Unités sans lien avec la langue de l'appareil.**
- Km et 24 h pour tout le monde (`HomeModel.swift:772-773`).
- « °C » et « KM/H » en dur (`WeatherBlock.swift:45, 238`).
- AM/PM en dur (`FlightActivityDisplay.swift:105`).
- « 45 percent » non formaté (`FlightProgressBar.swift:46`).

**A12. Grandes polices : textes critiques tronqués, vu sur le simulateur.**
- Le code ami devient « K7… · X… » : il n'est plus lisible, donc plus partageable.
- Les titres « San Fran… » et « Paris to S… » sont coupés.
- Les libellés de la barre aéroport deviennent « De… Arri… Fav… ».
- « Accept » se coupe en « Acce / pt ».
- Les noms d'icônes se coupent en « Aut / o ».
- Correctif :
  - le code ami et les titres passent sur plusieurs lignes ;
  - aux tailles d'accessibilité, la barre n'affiche que des icônes avec le grand aperçu ;
  - le bouton Accepter grandit en hauteur.

**A13. Contenus extrêmes non testés.** Aucun rendu avec un aéroport au nom très long, une compagnie sans nom ou un ami au nom fait d'emoji.

**E17. Scan de carte d'embarquement, caméra refusée** : le texte cite Réglages et la capture d'écran, mais ne propose aucun des deux boutons (`PassScannerSheet.swift:30-36`).

**E18. Amis et Aéroport sans cache hors ligne.** C'est acceptable une fois E8 corrigé.

### P3, signature

- **A15. Splash.** Il bloque les taps environ 1 s à chaque lancement à froid (`FlightSplash.swift:33, 64-70`). Le montrer seulement au premier lancement de la session.
- **I15. État pressé incohérent.** `CardPressStyle` (échelle 0,98) n'existe que dans le Passeport. L'appliquer à `RefinedCard` et à la barre d'actions.
- **I16. Pas de retour haptique au follow réussi.** Ajouter `.sensoryFeedback(.success)` à cet endroit seulement.
- **A16.** Le glyphe (i) de `SectionHeader` a une taille fixe. Plusieurs composants plafonnent à `accessibility2` : c'est défendable, mais à tester.

## Plan de correction

La règle de la grille : corriger les composants partagés avant les écrans. Huit lots, dans l'ordre.

1. **Données d'abord** (E1, E2, E7, E8, E10). Fichiers : `MyFlightsStore`, `SupabaseBackend`, `DelayColor`.
   - Cache lu avant le réseau.
   - Rechargement au retour du réseau et au retour au premier plan.
   - Panne serveur distinguée du hors ligne.
   - Messages qui dépendent de ce qui est affiché.
2. **Actions sûres** (I1, I2, I3, I4, E4, E6, E15, I14). Fichiers : `UI/Refined/`.
   - Toast avec Annuler et `.confirmDestructive`.
   - `.guardsUnsavedChanges`.
   - `LoadingButtonStyle` et ids en cours.
   - Erreur d'action séparée de l'erreur de chargement.
3. **Session et permissions** (E3, E5, E11, E17).
   - Bannière « Se connecter » et connexion en feuille.
   - État des notifications refusé, rendu visible.
4. **Recherche** (D1, D6, I11).
   - Annuler la recherche en vol quand le texte change, avec un test.
   - État « aucun résultat » neutre.
   - Requête conservée au retour.
5. **Français** (A1, A2, A11, A14, D2, D3).
   - Formats localisés dans `FlightStatusSummary`, `Format` et `BoardRow`.
   - Glossaire.
   - Script de clés manquantes en CI.
6. **Contraste et mouvement** (A3, A4, A5, A6).
   - Jetons texte des retards.
   - Variantes fort contraste dans `Color(light:dark:)`.
   - `CardMotion` et `GlobeMap` sensibles à Reduce Motion.
7. **Formulaires** (I5, I12, I13, I8).
   - `FormField` et `SheetHeader.modal` pour tous les éditeurs.
   - Barre clavier.
   - `.minTapTarget()`.
8. **Système** (D7 à D10, A9, A12).
   - Tokens d'espacement, de rayon et d'ombre.
   - Une seule barre d'actions.
   - `swift-snapshot-testing` et une galerie de composants avec grandes polices et contenus extrêmes.

## Non vérifié

- **Appareil réel et Accessibility Inspector** : non utilisés.
- **États sur le simulateur** : la session expirée, le refus de notifications, le réseau lent et le retour après interruption n'ont pas été reproduits. Ils sont établis par la lecture du code.
- **Éditeurs** : ni la visibilité du champ actif au-dessus du clavier, ni les grandes polices n'ont été testées.
- **Téléphone de « Text me too »** : il part brut, sans format E.164 côté client (`Stores/TextAlertsStore.swift:50-54`). Le comportement avec un numéro français dépend du serveur.
- **Panneau Mac et iPhone Duo** : pas repassés.
