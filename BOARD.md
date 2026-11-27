# Board
<!-- board v1 prefix:FL next:26 -->

## Roadmap

## Doing
- FL-1 P1 Soumission App Store de la build 2026112501 `since:2026-11-25`
  Reste : captures finales aux bonnes tailles (slides iPhone 6.9 et 6.3, iPad 13, Mac ajoutées le 2026-11-25), métadonnées, questionnaire d'âge, notes de review avec compte démo, upload et envoi en review.
- FL-2 P2 Version web (Apps/Web) : premier jet à finir `since:2026-11-11`
  Reste : 30 commits locaux non poussés, rien déployé. Vérifier la connexion email réelle, le décodage du 503 de flight-lookup, les tests Deno des fonctions enveloppées.

## Blocked
- FL-3 P1 Accord développeur Apple et profils de provisioning
  Bloqué : le titulaire du compte (Chloé) accepte le Program License Agreement, puis création des App IDs me.somalabs.flight et .widgets (Sign in with Apple, push, App Group) et des profils iOS et Mac.
- FL-4 P1 Pages vie privée et support en 404
  Bloqué : débloquer le déploiement Vercel de somalabs.me (Git deploys bloqués), puis fusionner les PR landing /legal/soma-flight-privacy et /support. Les deux URLs sont obligatoires dans App Store Connect.
- FL-5 P1 Révocation du jeton Apple à la suppression de compte
  Bloqué : créer une clé Sign in with Apple, poser les secrets APPLE_TEAM_ID, APPLE_SIGNIN_KEY_ID et APPLE_SIGNIN_PRIVATE_KEY, puis donner le oui pour redéployer delete-account.
- FL-6 P1 Clé AeroAPI Standard et conditions B2C
  Bloqué : lire les conditions commerciales, souscrire le niveau Standard, poser AEROAPI_KEY dans Supabase, puis dire quand basculer SCHEDULES_ENABLED et BOARD_PROVIDER. Sans clé, horaires et prévisions restent sur fausses données.
- FL-7 P1 Clé APNs et mise en prod des notifications
  Bloqué : fournir la clé APNs et l'URL de redirection somaflight://auth-callback dans le tableau Supabase, puis valider le test push et Live Activity sur appareil réel.
- FL-8 P2 Licences logos et vues de profil des avions
  Bloqué : choisir le fournisseur (Airhex pour les logos, Logostream ou Airliners Illustrated pour les profils), signer, et trancher la question marque déposée avec un juriste. Les images IA montrent des marques de compagnies.
- FL-9 P2 Clé MapKit JS pour la version web
  Bloqué : créer la clé MapKit JS, valider le projet Vercel, le DNS flight.somalabs.me et le oui pour déployer les fonctions avec CORS et mapkit-token.

## Todo
- FL-10 P1 Vérifications sur appareil réel
  Pushs APNs, Live Activity, tap de notification à froid, Keychain en sandbox Mac, Sign in with Apple, export et suppression de compte, build -StoreDemo sur la Watch.
- FL-11 P1 Compte démo pour la review Apple
  Compte email avec quelques vols suivis, à mettre dans les notes de review.
- FL-12 P2 Migration airlines 20261104000010 absente du cloud
  Vérifier le delta de lignes (39 compagnies) sur le projet Flight, compter avant et après le push.
- FL-13 P2 Asiana : passer en SkyTeam après le 2026-12-16
  Mettre à jour supabase/seed/airlines.csv, régénérer la seed et le JSON de l'app, ajouter une migration delta.
- FL-14 P2 Rustines d'audit premium restantes
  E14 (pushs backend sans date de péremption), phrases NOTAM et météo Rust encore en anglais, verre absent des snapshots macOS.
- FL-15 P2 Couche proactive : connexion en danger et heure de départ
  Croiser retard entrant, temps de correspondance minimum et distance entre portes ; calcul de "leave now" avec trajet MapKit et attente sécurité.
- FL-25 P0 Contrôle Nightboard de bout en bout `since:2026-11-27`
  Précision : Test du workflow Nightboard. Étape 1 : ouvre la pièce jointe avec Read, puis passe cette carte en Blocked avec une ligne Bloqué : qui demande si l'onglet visible sur la capture s'appelle bien À toi (propose oui ou non), commite BOARD.md et arrête-toi. Étape 2, seulement si une ligne Réponse : existe : déplace la carte en Done. Ne modifie aucun autre fichier que BOARD.md.
  Pièce jointe : ios-inbox.png
  Question : l'onglet visible sur la capture ios-inbox.png s'appelle-t-il bien À toi ? Réponds oui ou non (la capture montre l'onglet À toi sélectionné, titre À toi).
  Réponse : oui

## Later
- FL-16 P3 Plan de jet lag avec Prism
  Moteur Circadian partagé via WellnessKit, calcul sur le téléphone. Spec 2026-11-08-prism-integration.
- FL-17 P3 Droits des passagers EU261 et DOT
- FL-18 P3 Serveur MCP personnel pour les données de vol
  Question ouverte : pour le propriétaire seulement ou pour tous les utilisateurs.

## Done
- FL-19 P1 Écran de lancement animé et splash avion `done:2026-11-18` `3d7ccb34`
- FL-20 P1 Audit premium iOS : 59 points corrigés `done:2026-11-18` `c6bea3ff`
- FL-21 P1 Refonte Flight refined depuis Penpot `done:2026-11-17` `4d5bcf48`
- FL-22 P2 Bouton Suggérer une fonctionnalité dans Réglages `done:2026-11-23` `c2629174`
- FL-23 P2 Aéroports par code ICAO, 14 types d'avion, vue de profil pour chaque type `done:2026-11-25` `c3db81e3`
- FL-24 P2 Argument de lancement -StoreDemo pour les captures `done:2026-11-26` `5fc56401`
