# Store fixes for the premium checklist audit: API for the UI wave (2026-11-18)

This note lists what the store and model layer now exposes for the findings of `2026-11-18-premium-checklist-audit.md`, so the screens can adopt it. Paths are relative to `Packages/FlightKit/Sources/FlightKit/` unless stated. Everything is additive: old names still work, except where a store no longer writes an action failure into its load `error` (E6, E10, I4). Those screens show nothing for a failed action until they read the new property.

Tests for all of it: `Packages/FlightKit/Tests/FlightKitTests/StoreAuditFixTests.swift`.

## Shared types

- `ActionFailure` (`Stores/ActionFailure.swift`): a failed user action, apart from the load error. Fields: `kind` (`ActionFailure.Kind`: `.unfollow`, `.follow`, `.respond`, `.cancelRequest`, `.removeFriend`, `.updateFriend`, `.pauseSharing`, `.saveProfile`, `.invite`, `.resetCode`, `.notify`), `error: APIError`, `retry: @MainActor () async -> Void`, `needsSignIn: Bool`. It is `Identifiable`, so it can drive an alert or a toast.
- `APIError.needsSignIn`: true for `.unauthorized`. Use it to swap Retry for Sign In.
- `ToastAction` (`App/ToastAction.swift`): a toast button, `title` ("Undo", "Retry") and `run`.

## E1. Cache before the network

`MyFlightsStore.load()` now fills an empty list from the cache before the network answers, and falls back on the cache for any error, not only `.offline`.

- `MyFlightsStore.isShowingCache: Bool`: the list on show is the saved copy.
- `fetchedAt` is the cache's save time while `isShowingCache` is true, so the freshness line can say how old it is.
- `hasLoaded` keeps its meaning (a network load finished). `MyFlightsView` already shows rows whenever there are any, so the cached list appears with no screen change.

## E2. Offline lifts

- A pushed update now clears `MyFlightsStore.isOffline` (and an `.offline` error).
- `MyFlightsStore.refreshIfNeeded(staleAfter:now:)`: reloads when offline, after an error, while showing the cache, or when stale without a live stream. It leaves a healthy live list alone.
- `Connectivity.onReconnect(_:)`: calls back on each offline to online change. `Connectivity.set(online:)` moves a fixed connection (tests, fakes).
- `HomeModel` wires both itself: `refreshAfterReconnect()` runs on reconnect, and `sceneDidBecomeActive()` runs on `UIApplication.didBecomeActiveNotification` (or the AppKit one) once `start()` has run. Shells need no change. They may call `sceneDidBecomeActive()` themselves if they prefer.
- Still for the UI: mount `SectionFreshness` while offline too (`MyFlightsView.swift:129-136`).

## E3. Session expired

- `AuthService.refreshSession()` is a new requirement, with a default that does nothing. `SupabaseAuthService` renews the token.
- `SessionStore.recoverSession() async -> Bool` tries one refresh, shared between callers. A refusal sets `SessionStore.isSessionExpired`. `clearSessionExpired()` resets it, and a new sign-in clears it too.
- `MyFlightsStore.onUnauthorized` and `FriendsStore.onUnauthorized` are wired by `HomeModel`. A load (or an unfollow) that meets `.unauthorized` refreshes once and retries before it shows the error.
- `HomeModel.isSessionExpired`: the signal the UI should use. When it is true, or when an error's `needsSignIn` is true, show "Sign in" instead of Retry. Present `SignInView` as a sheet over the current state, so editors keep their text. Do not rely on `SignInGate` swapping the tree.
- `PassportStore` is not wired yet. Its `.unauthorized` errors still need the `needsSignIn` check in the banner.

## E4. Friends: no double send

- `FriendsStore.pending: Set<UUID>` and `FriendsStore.isPending(_:)`. Request ids are pending for `respond(to:accept:)` and `cancel(_:)`, and friend ids for `remove(_:)`. A second call while one runs does nothing.
- UI: disable and show progress (`LoadingButtonStyle`, I14) on Accept, Decline, Cancel and Remove while `isPending(id)`.

## E5. Notification permission

- `PushCoordinator` is now `@Observable`, with `permission: NotificationPermission?` (nil until read or on the Mac) and `isDenied`. `refreshPermission()` reads it again without prompting. It runs at launch, after a follow and on scene activation.
- `HomeModel.notificationPermission` and `HomeModel.notificationsDenied` are the properties screens should read.
- UI: when denied, show the bell as off in `DetailHeader`, show a "Notifications are off" card with a Settings button on the Notifications screen, and dim its switches.

## E6. Retry runs the failed action

- `MyFlightsStore.actionError: ActionFailure?`, with `clearActionError()`. `unfollow(_:)` now returns `APIError?` (discardable) and no longer sets `error`.
- `SearchStore.followError: ActionFailure?`, with `clearFollowError()`. `SearchStore.following: Set<Flight.ID>` holds follows on their way. `follow(_:)` no longer sets `error`.
- `FriendsStore.actionError: ActionFailure?`, with `clearActionError()`. Every action (switches, pause, profile, invite, remove, respond, cancel, reset code) reports there. `error` is the load's only. `clearError()` clears both.
- UI: show `actionError` as an error toast or banner whose Retry calls `actionError.retry()`, and keep the load banner's Retry on `load()`. `SearchView.swift:296-297` should read `followError`.

## E7. Server outage is not "offline"

- `SupabaseBackend.map(_:deviceOnline:)`: `.timedOut`, `.cannotConnectToHost`, `.cannotFindHost`, `.dnsLookupFailed` and `.networkConnectionLost` are `.offline` only when the device's path is down. When the path is up they are `.providerUnavailable`. `.notConnectedToInternet`, `.dataNotAllowed`, `.internationalRoamingOff` and `.callIsActive` are always offline.
- `Connectivity.devicePathOnline: Bool?`: the last system path, readable from any thread. It is nil before the monitor reports, and a nil keeps the old mapping.

## E10. Partial data

- `FlightDetailStore.error` is set only when the flight call fails.
- `FlightDetailStore.sectionErrors: [FlightDetailStore.Section: APIError]`, with sections `.events`, `.origin` and `.destination`. UI: at most a quiet note in that section, never "Couldn't refresh".

## E11. Notification settings load

- `NotificationSettingsStore.loadFailed: Bool`: true when a load failed and the account's row was never read, so the switches show defaults. `isLoading: Bool` and `retry()` are new too.
- `hasLoaded` still means "a load finished". Use `hasPreferences` for "the switches are real".
- UI: when `loadFailed`, dim the switches and show a banner whose Retry calls `retry()`.

## E13. Travel documents sync

- `TravelDocumentsStore.syncState: SyncState`, one of `.off`, `.synced`, `.pending` or `.failed`.
- `TravelDocumentsStore.lastSyncedAt: Date?` and `retrySync()` are new too.
- UI: say "on all your devices" only for `.synced`. Show "Not synced yet" with Retry for `.failed`, and "Not synced yet" for `.pending`.

## E14. Live Activity staleness

- `FlightActivityAttributes.ContentState.staleDate(now:)`: while the flight is in the air, or leaving within `soonWindow` (3 h), the card goes stale `liveStaleAfter` (20 min) after each update, capped at the old arrival + 1 h. `SystemFlightActivityHost` uses it.
- `FlightActivityDisplay(…, isStale:)` and `staleNote: String?`. When stale, the level colours turn grey and the lock screen shows the note. `Apps/Widgets/FlightLiveActivity.swift` now passes `context.isStale`.
- Backend follow-up: remote Live Activity pushes do not carry `stale-date`. Add `stale-date = now + 20 min` to the APNs payload while the flight moves, or a pushed update keeps the stale date of the last local update.

## E15 and I1. Undoable unfollow

- `HomeModel.unfollowWithUndo(_ flight:)` hides the flight at once (`MyFlightsStore.hidden`, filtered out of `live`, `upcoming` and `flights`). It shows "Removed AF 84" with an Undo button, and only asks the server after `HomeModel.undoWindow` (5 s). Undo calls `undoUnfollow(_:)`, so the booking code, seat and notes stay, since the server never unfollowed.
- A refused unfollow puts the flight back and shows "Couldn't remove AF 84" with Retry ("Sign in again to remove AF 84" when the session is gone).
- `isUnfollowPending(_:)` and `commitPendingUnfollows()` are public. Call `commitPendingUnfollows()` when the scene goes to the background.
- `MyFlightsStore.unfollowing: Set<Flight.ID>`: an unfollow on its way, which a second call ignores. `hide(_:)`, `unhide(_:)`, `contains(_:)` and `flight(_:)` are public too.
- Toasts: `HomeModel.showToast(_:action:isError:)`, `toastAction`, `runToastAction()`, `dismissToast()` and `actionToastDuration` (5 s). `ToastSlot(home:)` and `AddedToast(text:isError:actionTitle:onAction:)` draw the button. The four shells (`Apps/iOS/RootTabView.swift`, `RegularHomeView.swift`, `DuoSplitHomeView.swift`, `Apps/macOS/RootSidebarView.swift`) now use `ToastSlot(home:)`.
- UI: the swipe and the context menu in `MyFlightsView` and the detail's "Delete Flight" should call `home.unfollowWithUndo(flight)` instead of `store.unfollow(flight)`. The detail closes at once. `SwipeToDelete` can drop its 1.5 s comeback, because the row stays hidden through `hidden`.

## I4. Alerts switch

- `FlightDetailStore.notifyError: APIError?` (the switch went back), with `retryNotify()` and `clearNotifyError()`. `setNotify` no longer touches `error`.
- UI: show an error toast whose Retry calls `retryNotify()`.

## I7. Flight that no longer exists

- A tapped notification or widget for a flight the server no longer has shows the toast `HomeModel.flightGoneText` ("This flight is no longer available").
- `FlightDetailStore.isGone`: the flight call answered `.notFound`. UI: show a "no longer available" state with Close, not the search's "Check the number and date" and Retry.

## D1. Search

`SearchStore.textChanged()` cancels a submitted search when the text now reads as another route, bumps the generation and stops the spinner. `search()` checks the route again after the network answers. There is nothing new for the UI.

## A11. Units

- `StoredUnits(locale:)` defaults to the region when the user never chose: miles and 12 hour in the US, kilometres and 24 hour in France.
- `StoredUnits.defaultUnits(_:)`, `SharedSettings.localeUses24Hour(_:)` and `SharedSettings.localeUsesMiles(_:)` are new. `SharedSettings.twelveHour(in:locale:)` falls back to the region too, so the Live Activity agrees with the app.
- Still for the UI: the hard-coded "°C", "KM/H" and AM/PM (`WeatherBlock.swift`, `FlightActivityDisplay.clock`) and the "45 percent" label.

## New strings for the catalog

These are not added to `Apps/Shared/Localizable.xcstrings`, which another agent is editing:

- "Undo"
- "Retry"
- "Removed %@"
- "Couldn't remove %@"
- "Sign in again to remove %@"
- "This flight is no longer available"
- "Not updated lately. Open Soma Flight for the latest."
