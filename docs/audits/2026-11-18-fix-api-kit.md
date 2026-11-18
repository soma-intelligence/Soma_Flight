# API du kit après l'audit premium (2026-11-18)

Ce que la vague « composants partagés » a livré, et quand les écrans doivent s'en servir. Base : l'audit `2026-11-18-premium-checklist-audit.md`. Les chemins sont relatifs à `Packages/FlightKit/Sources/FlightKit/`.

Règle générale : un écran n'écrit plus de couleur, de rayon, de bouton de chargement, de dialogue de suppression ni de champ de texte à la main. Il prend le composant ci-dessous.

## Jetons (`UI/Theme.swift`)

### Couleurs de texte des retards (A3)

| Jeton | Remplace en texte | Clair | Sombre |
|---|---|---|---|
| `Theme.lateText` | `Theme.late` | `#8F6000` | `#FDB022` |
| `Theme.onTimeText` | `Theme.onTime` | `#0B7A45` | `#12B76A` |
| `Theme.veryLateText` | `Theme.veryLate` | `#C4281E` | `#FF6961` |
| `Theme.canceledText` | `Theme.canceled` | `#636369` | `#FFFFFF` |
| `Theme.divertedText` | `Theme.diverted` | `#8A2BC2` | `#C97AF5` |
| `Theme.friendText` | `Theme.friend` | `#0A7381` | `#3CD3E6` |
| `Theme.accentText` | `Theme.accent` | `#0066D6` | `#3D9BFF` |

- Tous dépassent 4,5:1 sur `#FFFFFF` et `#F2F2F7` en clair, et sur `#202023` et `#18181A` en sombre. Les ratios sont dans le commentaire de `Theme.swift`.
- **Quand** : tout texte (mots, heure révisée, lien) écrit dans une couleur de retard ou d'accent. Les teintes d'origine restent pour les points, barres, arcs et remplissages.
- `DelayLevel.textColor` donne le jeton texte d'un niveau (à côté de `DelayLevel.color`).
- `FlightStatusSummary.textTone` et `FlightStatusSummary.textTone(for:)` : la couleur des mots d'un statut. `DetailHero` (hors de ce lot) doit passer de `tone` à `textTone` pour ses mots.

### Augmenter le contraste (A4)

- `Color(light:dark:highContrastLight:highContrastDark:)` et `Color(light:lightOpacity:dark:darkOpacity:highContrastLight:highContrastDark:)`. Les deux derniers paramètres sont optionnels.
- iOS : lit `traitCollection.accessibilityContrast == .high`. Mac : les apparences `accessibilityHighContrastAqua` et `accessibilityHighContrastDarkAqua`.
- Ont une variante forte : `secondary`, `separator`, `grid`, les sept jetons texte ci-dessus, `destructive`.
- **Quand** : tout nouveau jeton de texte ou de trait fin doit donner sa variante forte.

### Autres jetons (D8, D9)

- `Theme.destructive` : fond d'une action destructrice (corbeille du glissement, jauge dépassée), blanc dessus. `Theme.destructiveText` : mots destructifs hors `role: .destructive`.
- `Theme.Space` : `xxs` 4, `xs` 8, `sm` 12, `md` 16, `lg` 24, `xl` 32. Toujours via `scaledPadding` ou `Theme.metric`.
- `Theme.Radius` : `control` 12, `card` 14, `sheet` 38. `Theme.cardRadius` et `Theme.sheetRadius` restent des alias.
- `Theme.Shadow.card` et `Theme.Shadow.floating`, posés avec `.themeShadow(_:)`.
- **Quand** : tout code neuf ou retouché. Pas de migration en masse des écrans dans ce lot.

## Texte localisé (A1, A2)

- `FlightStatusSummary.make(...)` : construit `text` à partir de clés à format (`"Departed %@ late"`, `"lands %@"`, `"gate %@"`, `"departs %@"`, `"%@ late"`, `"Landed %@ late"`, `"Landed %@ early"`, `"Diverted to %@"`). Les morceaux sont joints par `FlightStatusSummary.separator` (`" · "`). Sortie anglaise inchangée.
- `FlightStatusSummary.showsLandingTime` : vrai quand le texte finit par l'heure d'atterrissage. **`MyFlightRow.status(...)` doit tester ce booléen** au lieu de `text.contains(" · lands ")`, qui échoue en français.
- `BoardRow.statusText` : clés `"%@ Late"`, `"%@ Early"`, `"Belt %@"` et les statuts existants.
- `Format.ago(_:now:)` : `Date.AnchoredRelativeFormatStyle` dans la langue de l'app, « just now » sous une minute. Anglais : « 4 min. ago » (avant « 4 min ago »).
- `Format.updated(_:now:stale:)` : « Updated 4 min. ago » ou « Last update 3 hr. ago », clés `"Updated %@"` et `"Last update %@"`.
- `FlightActivityDisplay.duration(minutes:)` : `Duration` formatée (heures et minutes, largeur étroite) dans `FlightActivityDisplay.uiLocale`. Anglais inchangé (« 2h 37m »), français « 2h 37min ».
- `FlightActivityDisplay.uiLocale` : la locale de la langue des chaînes de l'app (premier `Bundle.main.preferredLocalizations`). **Quand** : tout `formatted(...)` de nombre, durée ou date affiché à côté de mots traduits.
- Clés ajoutées au catalogue `Apps/Shared/Localizable.xcstrings`, toutes traduites en français (tutoiement) : 32 clés, dont `Retry`, `Sign In`, `Couldn't refresh`, `Updated %@`, `Last update %@`.
- **Quand** : un écran qui compose une phrase avec une valeur passe par `String(localized: "… \(valeur) …", bundle: .main)` et ajoute la clé au catalogue. Jamais de concaténation de morceaux anglais.

## Erreurs et fraîcheur

### `ErrorBanner` (E3, E8, A2)

```swift
ErrorBanner(error: APIError, hasContent: Bool = true, retry: (() -> Void)? = nil, signIn: (() -> Void)? = nil)
```

- `hasContent: false` quand rien n'est affiché sous la bannière (recherche, aéroport sans cache, liste vide) : le texte ne promet plus « Showing the last update ».
- `signIn` : pour `.unauthorized`, la pastille devient « Sign In » au lieu de Retry. **Tous les écrans qui chargent avec une session** (Mes vols, Amis, Passeport, fiche vol) doivent passer `signIn`.
- `APIError.message(hasContent:)` : la copie seule. `APIError.message` vaut `message(hasContent: true)`.
- `ErrorBannerAction` (`.retry`, `.signIn`, `pick(for:retry:signIn:)`) et `ErrorActionPill(_:)` : la pastille seule, pour une carte d'erreur sur mesure.
- `RefreshErrorCard(error:updatedAt:now:retry:signIn:)` : même règle Sign In ; sous-titre localisé (`"Last updated %@"`, `"Offline · last updated %@"`).

### `OfflineBanner` (E8, D8)

- `OfflineBanner.text(hasContent:)` : `homeText` avec des vols enregistrés, `emptyText` sans. **L'accueil vide hors ligne doit passer `text(hasContent: false)`.**
- Rayon : `Theme.Radius.card` (14), comme `ErrorBanner`. Le bouton « Try again » a sa cible de 44 pt.

### `StaleBadge` (E9, D4)

```swift
StaleBadge(fetchedAt: Date, ttl: Duration, now: Date? = nil, style: .line | .badge = .line,
           source: String? = nil, hidesWhileFresh: Bool = false)
```

- `.line` : légende « Updated 4 min. ago · FlightAware » sous une section ou en pied de fiche. `.badge` : la capsule d'en-tête.
- Passe en `Theme.lateText` et « Last update … » après `ttl`. Se met à jour seul toutes les 30 s si `now` est nil.
- **Quand** : toute donnée en cache ou rafraîchie par TTL (Mes vols hors ligne, Passeport `lastUpdated`, sections d'aéroport, pied de fiche vol avec la source). `hidesWhileFresh: true` là où un horodatage frais serait du bruit.

## Actions

### `.confirmDestructive` (I1, I3)

```swift
.confirmDestructive(isPresented: Binding<Bool>, title: String, message: String? = nil,
                    actionTitle: String, action: @escaping () -> Void)
.confirmDestructive(item: Binding<Item?>, title: String, message: ((Item) -> String)? = nil,
                    actionTitle: String, action: @escaping (Item) -> Void)
```

- **Quand** : toute action irréversible (supprimer un vol du Passeport, « Forget My Number », supprimer un numéro de fidélité, vider un numéro de document). Ce qui peut s'annuler prend un toast « Annuler » à la place.

### `.guardsUnsavedChanges` et `CancelButton` (I2)

```swift
.guardsUnsavedChanges(isDirty: Bool, isSaving: Bool = false, onDiscard: (@MainActor () -> Void)? = nil)
@Environment(\.requestCancel) var requestCancel   // RequestCancelAction?, appeler requestCancel()
CancelButton()
```

- Bloque le glissement vers le bas tant que `isDirty || isSaving`. Cancel demande « Discard changes? » si modifié, ferme sinon, est désactivé pendant l'enregistrement.
- `onDiscard` : pour une carte de `CardStack` (sinon `dismiss`).
- **Quand** : la racine de chaque éditeur (notes, réservation, vol passé, documents de voyage, profil, texte collé dans Import). Le Cancel de l'éditeur devient `CancelButton()`.

### `LoadingButtonStyle` et `.loadingButton` (E4, I14)

```swift
Button("Accept") { … }.loadingButton(isLoading: Bool, variant: .filled | .tinted | .plain = .tinted)
LoadingButtonStyle(isLoading: Bool, variant: …)   // le style seul, sans .disabled
```

- Garde la largeur du libellé, montre un `ProgressView`, désactive le bouton, VoiceOver lit « In progress ».
- **Quand** : tout bouton qui lance un appel réseau (Accepter, Refuser, Annuler une demande, Send Code, Verify, Save). À coupler avec un ensemble d'ids en cours dans le store.

### `.minTapTarget` (I8)

```swift
.minTapTarget(_ side: CGFloat = 44)
.minTapTarget(_ side: CGFloat = 44, shape: some Shape)
```

- Agrandit le cadre et la zone de tap sans changer le dessin. **Quand** : Refuser, Accepter, Annuler (Amis), « + » du Passeport, « … » du code ami, Send Code, Change, Verify.

### `.failureAlert` (I6)

```swift
.failureAlert(_ error: Binding<APIError?>, title: String = "Couldn't finish that", retry: (() -> Void)? = nil)
.failureAlert(_ message: Binding<String?>, title: String = "Couldn't finish that", retry: (() -> Void)? = nil)
```

- « Try Again » (action par défaut) et « Cancel » ; OK seul sans `retry`. La copie vient de `message(hasContent: false)`.
- **Quand** : les sept alertes « OK » listées en I6. Un chargement raté reste une `ErrorBanner`.

### `CardPressStyle` (I15)

```swift
CardPressStyle(cornerRadius: CGFloat = Theme.Radius.card)   // ou .buttonStyle(.cardPress)
RefinedCard(severity: Color? = nil, padding: CGFloat = 16, action: (() -> Void)? = nil) { … }
```

- Échelle 0,98 et assombrissement à l'appui, sans échelle sous Réduire les animations, 45 % désactivé.
- Déplacé de `Screens/Passport/PassportCards.swift` vers `UI/Refined/CardPressStyle.swift`. Les cartes du Passeport gardent `cornerRadius: 20`.
- **Quand** : toute carte cliquable. `RefinedCard(action:)` au lieu d'un `Button` `.plain` autour d'une carte.

## Formulaires

### `FormField` (I5, I12, I13)

```swift
FormField(_ label: String, text: Binding<String>, prompt: String? = nil, error: String? = nil,
          footnote: String? = nil, keyboard: .standard | .ascii | .number | .decimal | .phone | .email | .url,
          content: .none | .name | … | .oneTimeCode | .flightNumber | .countryName | …,
          capitalization: .never | .words | .sentences | .characters, autocorrect: Bool = true,
          submitLabel: SubmitLabel = .next, axis: Axis = .horizontal, isSecure: Bool = false,
          focus: FocusState<Field?>.Binding, field: Field, next: Field? = nil, onSubmit: (() -> Void)? = nil)
// Hors chaîne de focus (Field == Never) : mêmes paramètres sans focus/field/next, submitLabel .done par défaut.
```

- Libellé persistant au-dessus, invite en exemple de format, erreur en ligne sous le champ (contour rouge, annoncée par VoiceOver, lue en indice), note sous le champ sinon.
- `content: .none` par défaut : plus de `.oneTimeCode` sur un numéro de passeport, KTN ou Redress.
- `next` enchaîne le focus au Retour ; sur le dernier champ, `onSubmit`.
- **Quand** : tout champ d'éditeur. Corriger I5 : `keyboard: .number` pour Redress, `capitalization: .words` (pas `.characters`) pour la compagnie.

### `.keyboardDoneBar(_:)` (I12)

- Barre clavier avec « Done » qui ferme le clavier, action optionnelle avant. iOS seulement.
- **Quand** : une fois par écran qui a un pavé numérique, un `phonePad` ou un champ multiligne.

## Barre d'actions (A9, A12)

```swift
GlassActionBar(_ items: [GlassActionItem])            // actions et menus
GlassActionBarContainer(count: Int) { … }             // view builder, pour ShareLink
GlassActionLabel(title: String, systemImage: String, tint: Color? = nil)
.refinedActionBar(_ items:)
.detailActionBar(shown: Bool) { GlassActionBarContainer(…) { … } }
.refinedActionBarInset()
```

- Une seule famille : `DetailActionBar` et `DetailActionLabel` n'existent plus que comme alias internes de `GlassActionBarContainer` et `GlassActionLabel`. `UI/Detail/DetailActionBar.swift` est supprimé.
- Aux tailles d'accessibilité, les libellés disparaissent : icônes seules, avec le grand aperçu au toucher long.
- Les boutons de la barre prennent `CardPressStyle`. `detailActionBar(shown:)` se contente d'un fondu sous Réduire les animations.
- **Quand** : les nouveaux écrans écrivent `GlassActionBarContainer` et `GlassActionLabel`. Les alias peuvent disparaître quand `FlightDetailView` et `AirportView` auront migré.

## Mouvement et grand aperçu (A5, A6, A16)

- `CardMotion.transition(reduceMotion:)` : `.opacity` sous Réduire les animations, montée depuis le bas sinon. `CardMotion.transition` lit le réglage système. `CardStack` lit l'environnement. Les vues qui ont déjà `accessibilityReduceMotion` doivent préférer `transition(reduceMotion:)`.
- `GlobeMap` : les vols de caméra et le glissement des marges sautent sans animation sous Réduire les animations.
- `ImportProgressPanel` : le pictogramme ne pulse plus sous Réduire les animations.
- `.accessibilityShowsLargeContentViewer` sur les onglets et la loupe de `HomeTabPill`, `RoundButton` (donc `CloseButton`) et chaque bouton de `MapControlCapsule`.
- `SectionHeader` : le glyphe (i) suit Dynamic Type (`@ScaledMetric`, relatif à `caption2`).
- **Quand** : toute nouvelle transition d'entrée passe par `accessibilityReduceMotion` ; tout contrôle de taille fixe reçoit le grand aperçu.

## VoiceOver de `BoardRow` (A10)

- `BoardRow.spokenText` : « AF 84, Paris, 25m Late, scheduled 18:25, now 18:41, gate F11 ». Clés `"scheduled %@, now %@"`, `"scheduled %@"`, `"gate %@"`, `"Belt %@"`.

## Reste à faire par les écrans

- `MyFlightRow` : tester `status.showsLandingTime` au lieu de `" · lands "` (le fichier était en cours d'édition par une autre session, non touché ici).
- `DetailHero` : `facts.tone` reste pour la barre et le trait, `FlightStatusSummary.textTone(for:)` pour le titre coloré.
- `HeroFacts.age` reste en anglais : le remplacer par `Format.ago`.
- `FlightDetailView` et `AirportView` : passer `signIn` aux bannières, `.failureAlert` aux alertes OK.
- Écrans sans contenu (Recherche, aéroport sans cache, accueil vide) : `ErrorBanner(hasContent: false)` et `OfflineBanner.text(hasContent: false)`.
