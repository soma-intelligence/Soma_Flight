# Audit : fonctionnalités de Flighty Pro face à Soma Flight

Date : 30 octobre 2026. Code audité : branche `feat/backend` (commit e12197e, PR #1).

Sources de la liste Flighty : la page d'aide officielle « Why subscribe », la page de tarifs et la fiche App Store (version 4.11.3). S'y ajoutent les annonces de juillet 2026 (Connection Assistant, prédictions de porte). Flighty Pro coûte 4,99 $ par semaine, 59,99 $ par an ou 299 $ à vie, et le premier vol est offert. Soma Flight n'a pas de version Pro : tout est gratuit, sans paywall.

Légende : **Fait** (existe et marche en vrai), **Partiel** (une partie existe, ou seulement avec les fausses données), **Manquant**, **Exclu** (écarté par décision).

## 1. Fonctionnalités exclusives Pro

| Flighty Pro | Soma Flight | État |
|---|---|---|
| Alertes avant les compagnies (avion entrant en retard ou annulé, météo, trafic) | Les push partent sur les événements AeroAPI : changement de porte, départ, arrivée, annulation, déroutement. Aucune alerte anticipée sur l'avion entrant. | Partiel |
| Prédiction de retard, avec la raison | Aucune prédiction, aucun champ de raison. | Manquant |
| Prédiction de porte | Aucune. | Manquant |
| Tendances de retard de l'aéroport | Courbes de retard au décollage et à l'atterrissage, performance du jour, routes et compagnies perturbées. | Fait |
| Rapport d'opérations de l'aéroport en direct | La météo METAR et la catégorie de vol (VFR/IFR) sont affichées. L'écran « Operations Report » de la maquette n'existe pas. | Partiel |
| Connection Assistant (étapes et temps de correspondance) | Rien. | Manquant |
| Guide IA porte à porte | Rien. | Manquant |
| NOTAM décodés | Rien. | Manquant |

## 2. Le reste de Pro

| Flighty Pro | Soma Flight | État |
|---|---|---|
| Live Activities | Live Activity sur l'écran verrouillé et la Dynamic Island, mise à jour par push APNs. | Fait |
| Alertes push (Flighty en annonce plus de 65) | 5 types immédiats, plus le tapis bagages dans la Live Activity. Pas d'embarquement, d'heure modifiée, ni de rappel la veille. | Partiel |
| Avis ATC en direct (FAA) | Rien. | Manquant |
| Where's My Plane sur 25 h | L'écran existe (chaîne de vols entrants), mais `InsightsService` ne renvoie rien en production tant que le coût AeroAPI n'est pas validé. Il ne marche qu'avec les fausses données. | Partiel |
| Alerte « avion en retard » | Dépend des données sur l'avion entrant ci-dessus. | Manquant |
| Vols directs alternatifs | Rien. | Manquant |
| Retards météo en direct | Météo de l'aéroport affichée, mais aucun lien fait entre la météo et un retard. | Partiel |
| Arrival Forecast (historique d'arrivée du vol) | Même situation que Where's My Plane : l'écran est là, les données live sont coupées. | Partiel |
| Synchronisation du calendrier | Pas d'EventKit. La page Mac « Calendar Sync » de la maquette n'est pas construite. | Manquant |
| Import par e-mail et TripIt | Rien. | Manquant |
| Historique et recherche de vols passés illimités | L'historique est illimité, alimenté par l'archive des vols suivis. On ne peut ni ajouter un vol passé à la main, ni l'importer en lot. | Partiel |
| Import en lot | Rien. Un export existe (`PastFlightExport`). | Manquant |
| Widgets d'écran verrouillé en direct | Seulement la Live Activity. Aucun widget d'écran d'accueil ou verrouillé. | Partiel |
| Complications Apple Watch | Pas d'app Watch. | Manquant |
| Détails de l'immatriculation | Immatriculation, âge, nom de l'avion, appareils fréquents, vue de profil photoréaliste (677 paires). | Fait |
| Temps de roulage | Le tableau horaire détaillé affiche le roulage au départ et à l'arrivée. | Fait |
| Détails de l'aéroport | Fiche aéroport complète, tableaux des départs et des arrivées. | Fait |
| Données live sur le Wi-Fi « messagerie seule » des avions | Rien. | Manquant |
| CarPlay | iOS affiche les Live Activities dans CarPlay. Probablement acquis, à vérifier sur une voiture. | À vérifier |

## 3. Fonctionnalités gratuites de Flighty, pour comparaison

| Flighty gratuit | Soma Flight | État |
|---|---|---|
| Suivi illimité, données live | Recherche, suivi, positions et route réelle via AeroAPI. | Fait (le déploiement attend l'accord) |
| Flighty Passport et statistiques | Passport complet, statistiques annuelles et globales, statistiques avion. | Fait |
| Flighty Friends | Écarté par le propriétaire (pas d'onglet Amis). | Exclu |
| Partage de vol en direct | Partage d'un texte. Pas de lien web en direct. | Partiel |
| App Watch et widgets | Voir la section 2. | Manquant |
| Sauvegarde iCloud | Remplacée par le compte Supabase. | Équivalent |
| Morning-Of Assistant, Check-In Assistant | Rien. | Manquant |
| Airport Intelligence (résumé en langage simple) | Le bloc Good to Know dit par exemple « Delays at CDG ». | Partiel |
| Radar de proximité et radar au sol, plans de vol réels | Position et trace sur le globe. Pas de radar ni de plan de vol déposé. | Partiel |
| iPhone Duo (téléphone posé en vol) | Rien. | Manquant |

## 4. Bilan

Sur 27 fonctions Pro : 5 faites, 8 partielles, 13 manquantes, 1 à vérifier. La partie visible (fiche du vol, Passport, aéroports, statistiques avion) est au niveau. Les manques sont la couche prédictive et proactive qui justifie l'abonnement Flighty : alertes anticipées, prédictions, correspondances, calendrier et import.

## 5. Priorités proposées

**P1 : peu coûteux, gros gain**

1. Activer `InsightsService` en production. Cela débloque Where's My Plane, Arrival Forecast et l'alerte « avion en retard ». Il faut l'accord sur le coût AeroAPI.
2. Synchronisation du calendrier avec EventKit, entièrement sur l'appareil, sans backend.
3. Widgets d'écran d'accueil et d'écran verrouillé (WidgetKit). La cible Widgets existe déjà.
4. Plus de types de push : embarquement, heure modifiée, avion entrant en retard, rappel la veille (Morning-Of) et à l'enregistrement.
5. Ajout manuel et import en lot de vols passés, par exemple en CSV, en réutilisant le format de l'export.

**P2 : moyen**

6. Connection Assistant : temps minimum de correspondance et changement de terminal, à partir des deux vols suivis.
7. Avis FAA et état du système aérien. L'API publique NAS Status est gratuite.
8. NOTAM décodés. L'API NOTAM de la FAA est gratuite avec une clé, et le core Rust peut faire le résumé.
9. App Apple Watch et complications.
10. Lien web de partage en direct (page publique sur somalabs.me).

**P3 : lourd, ou dépend de données payantes**

11. Prédictions de retard et de porte. Il faut un historique ou un modèle, à partir des tableaux et des archives.
12. Import par e-mail (adresse de transfert, parseur) et TripIt (API partenaire).
13. Vols directs alternatifs, guide IA porte à porte, données sur le Wi-Fi messagerie.

## Sources

- [Flighty : What is Flighty Pro](https://flighty.com/help/why-subscribe)
- [Flighty : Pricing](https://flighty.com/pricing)
- [Flighty sur l'App Store](https://apps.apple.com/us/app/1358823008)
- [MacTech, annonces du 6 au 10 juillet 2026](https://www.mactech.com/2026/07/10/software-announcements-for-the-week-of-july-6-10/)
- [Thrifty Traveler : Connection Assistant](https://thriftytraveler.com/news/travel/flighty-upgrades-connection-assistant/)
