# Features constructibles dès aujourd'hui (2026-11-08)

Tri des 40 idées de [GOAL.md](../GOAL.md#feature-ideas-2026-11-08). Critère : la feature tourne avec ce que l'app a déjà (données de vol déjà reçues, historique Passport, Rust `flightcore`), des frameworks Apple (HealthKit, MapKit, PhotosUI, WatchKit, ImageRenderer) et des tables statiques embarquées. Pas de nouveau fournisseur, pas d'appel payant, pas de modèle ML (Foundation Models compris).

Rappel GOAL.md : ces idées sont en priorité 6, derrière les bloqueurs App Store. Rien ici ne fait avancer la mise en ligne.

## Déjà fait (ne pas refaire)

| # | Feature | Où | Reste à faire |
|---|---|---|---|
| 1 | Connection at risk | `Models/Connection.swift`, `connection_rules.json`, `UI/Detail/ConnectionCard.swift`, push-sender | Distance porte à porte (voir 12, exclu) et rebooking (`alternate-flights`, payant) : exclus |
| 2 | Leave-now time | `Reminders/LeaveTimeEstimator.swift`, `LeaveByRow.swift` | Rien |
| 15 | Siri et Shortcuts | `Apps/Intents/FlightIntents.swift`, `SomaFlightShortcuts.swift` | Rien |
| 17 | Boarding pass sur la Watch | `Apps/Watch/WatchPassScreen.swift`, `BoardingPass/` | Montée auto à la porte : petit lot, voir plan 17 |
| 21 | Aircraft flown | `UI/Screens/Aircraft/AircraftStatsView.swift` (tails) | Badge "3e fois sur cet avion" sur la fiche vol, voir plan 21 |
| 26 | Travel documents | `TravelDocuments/`, rappel passeport (93a3639) | Visas : table à maintenir, exclu pour l'instant |

## Liste A : sur l'appareil, rien à déployer (21)

Santé : 4 Jet lag plan, 5 Fear of flying (sans prévision de turbulence), 6 Recovery, 7 Long-haul care, 32 Cabin noise, 33 Cabin pressure.
Problèmes : 8 Passenger rights, 9 Cancellation kit.
Aéroport et vol : 11 Boarding group, 13 Arrival, 14 Offline flight, 34 Window side, 35 Sun in flight, 36 Landmarks.
Passport : 18 Year in review, 19 Travel journal, 20 CO2, 23 Route poster, 27 Expense export, 38 Status tracker, 39 Schengen.
Petits restes : 17 (montée auto), 21 (badge), 37 Destination card sans l'avis du State Department.

## Liste B : pas d'API externe, mais un déploiement ou une validation Apple (5)

- 3 Pickup mode et 22 Crossing paths : notre Supabase seulement (infra Friends existe). Migration + Edge Function : ton oui.
- 24 Sync CloudKit chiffrée : Apple seulement, gros chantier, container iCloud à créer.
- 25 Serveur MCP personnel : notre backend, question ouverte (toi seul ou tous les users).
- 16 CarPlay : pas d'API, mais entitlement CarPlay à demander à Apple.

## Exclus (API externe, ML ou achat)

5 (partie turbulence, aviationweather.gov), 10 (`airport-stats` payant ; une version "historique perso" seule est trop pauvre), 12 (OSM indoor), 28 à 30 (prédictions ML), 31 (Foundation Models = modèle), 37 (partie avis State Dept), 40 (certificat Pass Type ID).

## Prérequis commun aux features santé

Aucun code HealthKit dans le repo aujourd'hui. Un lot 0 avant 4, 5, 6, 7, 32, 33 :

1. Entitlement HealthKit sur iOS et Watch, chaînes `NSHealthShareUsageDescription`.
2. `Health/HealthReader.swift` dans FlightKit : lecture seule, par type, protocole + fake pour les tests et la démo (`-useFakes YES`).
3. Interrupteur "Santé" dans Settings, off par défaut. Rien ne quitte le téléphone : vérifier que `PrivacyInfo.xcprivacy` et la fiche App Store restent justes (lecture locale, pas de collecte).
4. Tests : fake reader, refus d'autorisation, aucun appel réseau dans les chemins santé.

## Plans par feature

Format : logique, UI, tests, taille (S = 1 jour, M = 2 à 4 jours, L = 1 semaine+).

### 4. Jet lag plan (M)
- Logique en Rust `flightcore/src/jetlag.rs` : décalage horaire et direction (est/ouest) depuis les tz de l'itinéraire, règles publiées (avancer de 1 h/jour vers l'est, retarder vers l'ouest), fenêtres lumière, caféine, sommeil sur J-3 à J+3. Pure fonction, FFI.
- Ajustement par le sommeil réel : heure de coucher moyenne des 7 derniers jours depuis HealthKit (lot 0), sinon 23:00.
- UI : carte "Jet lag" sur la fiche vol dès 3 h de décalage, écran jour par jour, rappels locaux optionnels via `ReminderScheduler`.
- Tests Rust : Paris vers Tokyo, NYC vers Paris, < 3 h = pas de plan, passage de date.

### 5. Fear of flying mode (M, sans turbulence)
- Contenu : explications des bruits et sensations par phase (roulage, train, volets, palier, descente), phase déduite de `EstimatedProgress`.
- Respiration guidée (animation 4-7-8) sur iPhone et Watch.
- Déclencheur Watch : fréquence cardiaque au-dessus de la moyenne de repos + 25 bpm pendant 2 min, proposition de respiration (lot 0).
- Tests : phase par horaire, seuil FC sur série fake.

### 6. Recovery after the flight (M)
- Comparer sommeil, HRV et FC de repos : 7 jours avant le vol contre 3 jours après. Calcul Swift dans `Health/Recovery.swift`.
- UI : section dans la fiche Passport d'un vol passé, ton neutre ("HRV 12 % sous ta moyenne 2 jours"), pas de diagnostic.
- Tests : séries fakes, données manquantes, vol de moins de 2 h ignoré.

### 7. Long-haul care (S)
- Vols de plus de 4 h : rappels Watch boire toutes les 60 min, marcher toutes les 2 h, hors fenêtres décollage/atterrissage et nuit locale de bord.
- Planifiés au départ réel (`FlightEvent`), annulés à l'atterrissage. Réglage on/off.
- Tests : planning sur vol 11 h, vol décalé replanifié.

### 8. Passenger rights (M)
- Moteur de règles `flightcore/src/rights.rs` : EU261 (départ UE, ou arrivée UE sur compagnie UE ; 250/400/600 EUR selon distance et retard à l'arrivée ; annulation < 14 jours ; exception circonstances extraordinaires signalée, pas tranchée) et règles DOT US (remboursement sur annulation ou changement important).
- Pays depuis `countries.json`, liste compagnies UE dans `airlines.json` (champ à ajouter).
- Lettre de réclamation générée sur le téléphone, partage via share sheet.
- Bannière "Information, pas un conseil juridique". Copie relue par un avocat avant la Release (bloquant).
- Tests : grille distance x retard, vol hors champ, compagnie non UE depuis l'UE.

### 9. Cancellation kit (S)
- Table embarquée `airline_contacts.json` (téléphone service client par pays, page de rebooking) pour les 148 compagnies connues, sources notées.
- Écran sur vol annulé ou retard de plus de 3 h : appeler, quoi demander, vouchers hôtel et repas, lien vers 8.
- Tests : présence pour chaque compagnie de `airlines.json`, numéros au format E.164.

### 11. Boarding group timing (S)
- Heure d'embarquement (départ moins 30 à 45 min selon le type d'avion, ou l'heure du pass), nombre de groupes typique par compagnie (table), estimation linéaire par groupe.
- Affiché "groupe 5, vers 14:12" sur la fiche et la Live Activity. Toujours marqué "environ".
- Tests : groupe lu dans le BCBP, pas de groupe, embarquement déjà commencé.

### 13. Arrival card (S)
- Assembler ce qu'on a déjà : tapis bagages (provider), heure locale, METAR d'arrivée (gratuit, déjà en place), sortie de l'aéroport (texte par aéroport pour les 50 plus fréquents, sinon "suivre Arrivées").
- Carte qui remplace "At a glance" après l'atterrissage.
- Tests : copie par cas, pas de tapis connu.

### 14. Offline flight (M)
- Avant l'embarquement : cache de la route (`great_circle`), faits du vol, tuiles de carte de la route (MapKit snapshot) dans `Cache/`.
- En vol sans réseau : position estimée = horaire réel de décollage + vitesse de croisière du type + grand cercle, `flightcore/src/geo.rs` (`position_at(t)`). Nom de la zone survolée depuis `world_land.json` et un fichier océans/régions.
- UI : badge "Estimé, hors ligne" sur la carte.
- Tests Rust : CDG-JFK à mi-vol au-dessus de l'Atlantique, avant décollage, après atterrissage.

### 18. Year in review (M)
- Données déjà dans `compute_passport` (distance, vols, aéroports, retards, minutes en l'air). Ajouter pays, plus long vol, heures.
- 6 cartes `ImageRenderer` (format story 9:16), partage via share sheet. Rien n'est envoyé.
- Tests : snapshots des cartes, année vide.

### 19. Travel journal (M)
- `PhotosPicker` (pas d'accès à la photothèque), filtré sur la date du vol. Stockage local des identifiants `PHPicker` + miniatures dans l'App Group, pas de sync serveur.
- Galerie dans la fiche Passport du vol.
- Tests : association vol-photos, suppression d'un vol.

### 20. CO2 per flight (S)
- Méthode publique et sourcée (facteurs DEFRA/ICAO par distance et classe, coefficient sièges), écrite dans `docs/co2-method.md`. Calcul Rust `co2.rs`.
- Affiché par vol et cumulé dans Passport. Aucune compensation vendue.
- Tests : valeurs de référence de la méthode à 1 % près.

### 21. Aircraft flown, badge (S)
- Sur la fiche vol, si l'immatriculation du jour est dans l'historique : "3e vol sur F-GSQA".
- Tests : comptage, immatriculation inconnue.

### 23. Route poster (M)
- Rendu vectoriel des routes Passport (projection, `world_land.json`) en PDF A2/A3 via `ImageRenderer`, 3 styles. Export Fichiers ou impression.
- Tests : PDF généré, 0 vol, 1 000 vols (perf).

### 27. Expense export (S)
- Un PDF par voyage (vols groupés par `reason = business` et dates proches) : vols, horaires, code de réservation, notes. `ImageRenderer` ou PDFKit.
- Tests : regroupement, champs manquants.

### 32. Cabin noise (S)
- Watch : `environmentalAudioExposure` HealthKit pendant le vol (lot 0). Moyenne et pic sur la fiche du vol passé ; rappel bouchons si plus de 80 dB pendant 30 min.
- Tests : série fake, pas de Watch.

### 33. Cabin pressure (S)
- Carte explicative (cabine vers 2 400 m, fatigue, hydratation). SpO2 Watch seulement si l'utilisateur active, affichée sans interprétation médicale.
- Tests : copie, interrupteur off = aucune lecture.

### 34. Window side (M) et 35. Sun in flight (S, même moteur)
- `flightcore/src/sun.rs` : position du soleil (algorithme NOAA, pas de dépendance) en chaque point de la route estimée (plan 14).
- 34 : côté gauche ou droit pour le coucher/lever de soleil ; vues fixes (Alpes, Manhattan, etc.) depuis la table du plan 36. Utilise `SeatPosition` existant.
- 35 : heures de lever et coucher vues de l'avion.
- Tests Rust : soleil vs tables NOAA, CDG-NRT de nuit, vol nord-sud.

### 36. Landmarks overflown (M)
- Table embarquée `landmarks.json` (environ 500 lieux, coordonnées + rayon de visibilité), construite une fois depuis Wikidata (CC0) par un script, pas d'appel à l'exécution.
- Notification locale quand la position estimée passe à moins du rayon. Fonctionne hors ligne.
- Tests : Mont Blanc sur GVA-LHR, rien sur un vol océanique.

### 37. Destination card, partie statique (S)
- `countries.json` étendu : prise, tension, monnaie, pourboire, rappel eSIM. Sans avis du State Department (source externe).
- Tests : chaque pays de `airports.tsv` couvert.

### 38. Status tracker (S)
- L'utilisateur saisit son programme et ses seuils (segments, distance). Compte depuis l'historique de l'année, barre de progression. Pas de login compagnie.
- Tests : comptage par compagnie de l'alliance choisie, année civile vs glissante.

### 39. Schengen 90/180 (S)
- Liste des pays Schengen dans `countries.json`. `flightcore/src/schengen.rs` : jours de présence sur toute fenêtre de 180 jours depuis les vols entrée/sortie. Jours d'entrée et de sortie comptés.
- UI : compteur dans Passport + "tu peux rester jusqu'au …". Avertissement : vols seuls, trajets terrestres non vus.
- Tests Rust : cas de la calculatrice officielle UE, ressortie puis entrée le même jour.

### 17. Pass sur la Watch, montée auto (S)
- `RelevantContext` WidgetKit (Smart Stack) sur la fenêtre embarquement - 30 min, et ouverture directe de `WatchPassScreen`.
- Tests : fenêtre calculée, pas de pass.

## Ordre conseillé

1. Rapides et visibles : 39, 21, 20, 11, 9, 37, 27, 38.
2. Moteur géo commun : 14, puis 35, 34, 36.
3. Passport : 18, 23, 19.
4. Santé : lot 0, puis 7, 4, 6, 32, 33, 5.
5. 8 en dernier : il attend la relecture juridique.
