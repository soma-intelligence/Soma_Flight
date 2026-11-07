# Audit des écarts : Flighty face à Soma Flight

Date : 4 novembre 2026. Code lu : le dépôt tel qu'il est sur le disque (GOAL.md, docs/, `Packages/FlightKit`, `Apps/`, `supabase/`). Rien n'a été modifié ailleurs que ce fichier.

Cet audit remplace dans les faits `docs/audits/2026-10-30-flighty-pro-audit.md`, qui date d'avant la plupart des chantiers : l'app Watch, les widgets, l'onglet Amis, les imports, le Connection Assistant, les prédictions, les programmes FAA, les NOTAM, le calcul de l'heure de départ et le lien de partage existent maintenant dans le code.

Les fonctions de Flighty sont décrites avec nos mots, d'après les pages publiques citées en fin de document. Je n'ai pas pu lire les notes de version détaillées de 2026 (la fiche App Store n'en donne que la dernière, et un article de presse était bloqué). Ce qui suit sur 2026 vient de la fiche App Store et d'un article du 25 mars 2026.

## 0. Constat d'ensemble

Sur le papier, le périmètre fonctionnel est proche de celui de Flighty. L'écart principal n'est pas une fonction manquante : c'est que la couche payante côté serveur (prévision d'arrivée, avion entrant, tableaux d'aéroport, recherche par date) est coupée en production, et que rien n'est déployé. Les vrais manques fonctionnels sont plus étroits : Siri et Raccourcis, iPad, import par adresse de transfert et TripIt, couverture mondiale des aéroports, richesse des alertes.

## 1. Ce que Flighty fait et que Soma Flight ne fait pas (ou pas encore)

Effort : S = quelques jours, M = une à deux semaines, L = plus. Dépendance : donnée payante, API Apple, ou travail interne.

### Impact fort

| Écart | Où en est Soma Flight | Effort et dépendance |
|---|---|---|
| Tout le suivi live en production : alertes avant la compagnie, prévision d'arrivée, avion entrant, tableaux d'aéroport | Le code existe de bout en bout, mais `INSIGHTS_ENABLED = NO` en Release, `SCHEDULES_ENABLED = NO` partout, aucun déploiement Supabase fait (GOAL.md, checklist App Store). Voir section 2. | S pour le code (un réglage), mais bloqué par la décision du propriétaire : clé AeroAPI Standard (100 $ minimum), déploiement, accord sur le coût. |
| Import par e-mail transféré et synchronisation TripIt | Il y a un import depuis le partage d'un e-mail, lu sur l'appareil, plus calendrier, CSV et export Flighty. Pas d'adresse de transfert côté serveur, pas de TripIt (hors périmètre jusqu'au lancement, GOAL.md). | M pour une adresse de transfert avec analyseur (schema.org puis modèle de langage), L pour TripIt. Dépend d'un service de réception d'e-mails et d'un partenariat TripIt. Heurte le principe « aucun accès à la boîte mail » si mal fait : à lire sur l'appareil ou en traitement éphémère. |
| Siri, Raccourcis et App Intents (statut du vol, porte) | Aucun `AppIntent`, aucun Spotlight, aucune `NSUserActivity` dans le code. Flighty a ajouté Siri pour le statut et la porte à l'automne 2026. | M. API Apple seulement (App Intents). Se branche sur les stores locaux, pas de coût de données. |
| Couverture mondiale des aéroports et résumés en langage clair | Rapport d'opérations, courbes de retard, météo METAR et explication météo existent, mais reposent sur le tableau des vols d'un fournisseur (voir `BOARD_PROVIDER` en section 2). Les programmes FAA, les NOTAM et la file de sécurité sont américains. Pas de TAF, pas de résumé rédigé par modèle de langage. Flighty annonce plus de 14 000 aéroports, la météo METAR et TAF, les NOTAM et des explications de cause. | M à L. Données payantes pour les tableaux (AeroAPI ou équivalent). METAR, TAF et NOTAM hors États-Unis : sources publiques variables, à vérifier pays par pays. |

### Impact moyen

| Écart | Où en est Soma Flight | Effort et dépendance |
|---|---|---|
| Nombre et finesse des alertes (Flighty annonce plus de 65 types) | 18 types côté serveur (retards, porte, terminal, tapis, décollage, atterrissage, annulation, rétablissement, déroutement, avion entrant en retard, retard prédit, correspondance menacée, programme d'aéroport) plus des rappels locaux (enregistrement, matin du départ, heure de départ). Il manque par exemple l'embarquement, un changement d'avion, un changement d'heure d'embarquement. | S à M par type. Dépend des événements du fournisseur de données. |
| App iPad (Flighty couvre iPhone, iPad, Mac, Apple Watch et Vision) | `TARGETED_DEVICE_FAMILY: "1"` : iPhone seul, plus Mac et Watch. iPad et Vision exclus avant lancement (GOAL.md). | M. Mise en page seulement, aucune donnée en plus. |
| Rayon de proximité et radar au sol | Position et trace sur le globe. Pas de radar mondial (hors périmètre avant lancement). | L. Source de positions ADS-B sous licence (OpenSky exige une licence écrite pour un produit commercial, voir `docs/free-providers.md`). |
| Avis ATC en direct hors États-Unis | Seul le système de statut de la FAA est lu. | M. Dépend de sources nationales, pas de source mondiale libre identifiée. |
| Guide porte à porte par modèle de langage | Rien. Il y a des pièces voisines : heure de départ calculée, marche jusqu'à la porte, correspondance. | M. Appel à un modèle (Azure) et garde-fous : le texte doit rester vérifiable. |
| Raisons de retard rédigées pour chaque vol | Il y a une explication météo et des règles. Pas de rédaction générale de la cause (rotation, équipage, trafic). | M. Les causes viennent surtout du fournisseur de données, pas toutes disponibles. |
| Alertes pour aéroports favoris | Il existe un suivi des aéroports habituels dans les migrations (`airport_regulars`), mais je n'ai pas trouvé d'alerte de perturbation par aéroport favori : à vérifier. | S à M. Programmes FAA déjà lus ; l'abonnement par aéroport reste à faire. |

### Impact faible

| Écart | Où en est Soma Flight | Effort et dépendance |
|---|---|---|
| Mode « téléphone posé » (support type tente en vol) | Aucun mode dédié. | S. Mise en page seulement. |
| Tableau de bord web des perturbations, mode télévision, comparaison d'aéroports avec ses amis | Rien. | M. Dépend de tableaux d'aéroport en production. |
| Écran verrouillé et StandBy dédiés, CarPlay | Live Activity et widgets d'écran verrouillé présents. Aucune scène CarPlay explicite ; l'affichage des Live Activities y est géré par iOS. À tester sur un véhicule. | S pour la vérification. |
| Wi-Fi en vol limité à la messagerie | Les textos en vol sont écrits mais coupés (section 2). | Dépend du canal Linq. |
| Vols directs de remplacement | Existent (`alternate-flights`), mais dépendent de `INSIGHTS_ENABLED`. | Voir ligne 1. |

## 2. Ce qui existe dans Soma Flight mais reste coupé

| Fonction | Interrupteur | État | Ce qu'il faut pour l'allumer |
|---|---|---|---|
| Prévision d'arrivée, avion entrant (où est mon avion), vols de remplacement | `INSIGHTS_ENABLED` : `YES` en Debug, `NO` en Release (`Apps/*/Config.Release.xcconfig`) | Code et cache serveur prêts. Avec `NO`, les sections sont cachées et aucun appel n'est fait. | Accord sur le coût AeroAPI, déploiement de `flight-insights` et `alternate-flights`. |
| Recherche par date et par route dans le futur | `SCHEDULES_ENABLED = NO` partout | Debug : horaires fictifs. Release : message disant que les dates futures demandent le service. | Déployer `flight-schedules`, accord sur le coût des horaires AeroAPI. |
| Tableaux d'aéroport, statistiques d'aéroport, rapport d'opérations alimentés par les vols | `BOARD_PROVIDER` (secret de fonction) : `aeroapi` par défaut, `none` possible. Avec `none`, `airport-stats` répond `available: false`. `docs/free-providers.md` recommande `none` avec un fournisseur gratuit (quota trop faible). | Selon la configuration retenue, les écrans aéroport n'ont que les données de référence et la météo. | Une clé AeroAPI Standard, ou un fournisseur payant. Aucun palier gratuit n'autorise une app d'entreprise. |
| Fournisseur de statut et de position | `STATUS_PROVIDER`, `POSITION_PROVIDER` (`aeroapi`, `aviationstack`, `flightlabs`, `opensky`, `none`) | Avec autre chose qu'AeroAPI : pas d'alertes poussées par le fournisseur, interrogation périodique à la place (`provider-poll`, toutes les 5 minutes). | Choix du fournisseur par le propriétaire. |
| Alertes par texto et iMessage (« Text Me Too », textos en vol) | `SMS_ALERTS_ENABLED` non défini ; pas de `LINQ_API_KEY` | Code complet, section de l'app affichée « Coming soon », rien ne part. | Ligne Linq dédiée (environ 250 $ par mois d'après la doc), enregistrement A2P, secrets, déploiement, mise à jour des étiquettes de confidentialité. Voir `docs/sms-alerts.md`. |
| NOTAM décodés | `FAA_NOTAM_CLIENT_ID` et `FAA_NOTAM_CLIENT_SECRET` non définis | La fonction répond `configured: false`, l'app n'affiche aucun NOTAM. | Compte développeur FAA gratuit du propriétaire. |
| Connexion Google | `GOOGLE_SIGN_IN_ENABLED = NO` | Désactivé. | Activer le fournisseur dans Supabase. |
| Logos de compagnies et vues de profil sous licence | `LOGO_PROVIDER`, `AIRHEX_KEY`, `SIDE_VIEW_PROVIDER` non définis | La synchronisation ne fait rien ; l'app affiche un monogramme quand le logo manque (principe « échec fermé »). | Licences Airhex et d'un fournisseur de vues de profil, avis juridique sur les marques. |
| Données fictives | Debug : l'option `-useFakes` | Les builds Debug tournent sur des fausses données ; les builds Release refusent de démarrer sans configuration réelle. | Configuration Supabase de production. |

Tout le reste du serveur (webhook AeroAPI, push APNs, archivage horaire, plafond de dépense, alerte de coût) est écrit et testé, mais non déployé : `GOAL.md` place la mise en production en priorité 2, après les bloqueurs App Store.

## 3. Ce que Soma Flight fait et que Flighty ne fait pas, ou ne montre pas sur ses pages publiques

À prendre comme « non annoncé sur les pages consultées », pas comme preuve d'absence.

- Code source ouvert (AGPL) et principes de confidentialité inscrits : pas de publicité, pas de mesure d'audience, pas d'accès à la boîte mail, suppression de compte qui révoque le jeton Apple.
- Tout gratuit, sans abonnement ni vol d'essai. Flighty Pro coûte 4,99 $ par mois (ou 59,99 $ par an) d'après sa page de prix.
- Heure de départ calculée : trajet MapKit, file de sécurité estimée à partir des débits TSA publics (591 points de contrôle), dépôt des bagages, marche jusqu'à la porte (table des 40 plus gros aéroports américains), embarquement. Rappel recalculé à chaque mesure.
- Coffre de documents de voyage dans le Keychain (passeport, numéros de fidélité, voyageur connu), alerte quand le passeport expire dans les six mois d'un vol international.
- Cartes d'embarquement scannées ou lues depuis un `.pkpass`, gardées sur l'appareil, avec ajout à Apple Wallet.
- Prédictions de retard et de porte calculées sur l'appareil par le cœur Rust, sans appel payant propre.
- Position estimée hors ligne : le vol avance sur le grand cercle quand il n'y a plus de réseau ou plus de mise à jour depuis 5 minutes.
- Textos en vol pensés pour le Wi-Fi « messagerie seule » (coupés pour l'instant, voir section 2).
- Fiche d'avion avec vues de profil photoréalistes pour 700 paires compagnie et type environ, dérives, plans, statistiques par appareil.
- Lien de partage web d'un vol en direct, sans compte, avec image d'aperçu, qui expire 24 h après l'arrivée.
- Import du CSV d'export de Flighty : une porte de sortie pour ses utilisateurs.
- Plafond de dépense serveur avec courriel d'avertissement au propriétaire.

À parité avec Flighty : Live Activity et Dynamic Island, widgets d'accueil et d'écran verrouillé, app Apple Watch avec complications, app Mac, Passport et statistiques, onglet Amis (invitation par lien ou code, sans contacts), synchronisation du calendrier, import calendrier, Connection Assistant, programmes FAA, temps de roulage, détail d'immatriculation, historique illimité avec ajout manuel, import CSV et export.

## 4. Les cinq écarts qui comptent le plus

1. Allumer le suivi payant en production (clé AeroAPI Standard, déploiement, `INSIGHTS_ENABLED`, `SCHEDULES_ENABLED`) : sans cela, la promesse « avant la compagnie » n'existe pas pour un utilisateur réel.
2. Siri, Raccourcis et App Intents.
3. Import par adresse de transfert (puis TripIt).
4. Aéroports hors États-Unis : tableaux, TAF, NOTAM, résumés clairs.
5. Étendre les types d'alertes et ajouter l'iPad.

## 5. Sources

Flighty :
- Page d'aide « Why subscribe » (liste free et Pro) : https://flighty.com/help/why-subscribe
- Page de prix (prix, import, 65 alertes ou plus) : https://flighty.com/pricing
- Fiche App Store (version 4.11.3 du 26 octobre, plateformes, assistants, Siri depuis 4.11.0, iPhone Duo) : https://apps.apple.com/us/app/flighty-live-flight-tracker/id1358823008
- The Shortcut, « Airport Intelligence » du 25 mars 2026 : https://www.theshortcut.com/p/new-flighty-update-lets-you-see-real-time-airport-disruptions-and-operational-changes
- Executive Traveller sur la mise à jour iOS 26 (page bloquée à la lecture, titre seul vu dans une recherche) : https://www.executivetraveller.com/news/flighty-ios-26-update

Soma Flight (fichiers locaux) :
- `GOAL.md`, `README.md`, `docs/operations.md`, `docs/free-providers.md`, `docs/sms-alerts.md`, `docs/data-sources.md`, `docs/app-store-checklist.md`
- `docs/audits/2026-10-30-flighty-pro-audit.md`, `docs/audits/2026-10-30-soar-diff.md`
- `Apps/iOS/Config.Release.xcconfig`, `Apps/iOS/Config.Debug.xcconfig`, `project.yml`
- `supabase/functions/_shared/alerts.ts`, `supabase/functions/_shared/providers/select.ts`
