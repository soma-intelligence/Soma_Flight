# Soma Flight: App Store checklist

State on 2026-10-29 (Task 12). Done means in the code on `feat/backend`; open means someone still has to act before submission.

## In the app

| Item | State | Where |
|---|---|---|
| Privacy manifest, iOS app | Done. No tracking, no tracking domains. Collected, linked to the account, app function only: email address, user id, other user content (followed flights and flight history). Required-reason API: UserDefaults, CA92.1 (own settings and recent searches) and 1C8F.1 (clock setting in the App Group). | `Apps/iOS/PrivacyInfo.xcprivacy` |
| Privacy manifest, macOS app | Done. Same data; UserDefaults CA92.1 only (no App Group on the Mac). | `Apps/macOS/PrivacyInfo.xcprivacy` |
| Privacy manifest, widget extension | Done. Collects nothing; UserDefaults 1C8F.1 (reads the clock from the App Group). | `Apps/Widgets/PrivacyInfo.xcprivacy` |
| Other required-reason APIs | None used by our code: no file timestamp, disk space, boot time or active keyboard APIs (checked by grep on 2026-10-29). Third-party packages (supabase-swift, swift-crypto and friends) ship their own manifests. Recheck the generated privacy report (Xcode Organizer, "Generate Privacy Report") on the first archive. | |
| Account deletion path | Done on iOS and macOS: Settings, Account, Delete Account, a confirmation dialog ("Delete your account? Your followed flights and flight history will be removed. This can't be undone."), then `SessionStore.deleteAccount()` (edge function `delete-account`). Success signs out and shows Sign In; failure shows the error and stays signed in. | `SettingsView.swift`, `SessionStore.swift` |
| History export | Done: JSON and CSV built on the device, handed to the share sheet as `soma-flight-history-YYYY-MM-DD.json/.csv`. | `PastFlightExport.swift` |
| Alerts | Per-flight Notify Me switch on the flight detail (`follow(_:notify:)`), plus a link to the system notification settings. Per-type filtering is not in v1. | `FlightDetailView.swift` |
| Notification permission text | iOS shows no custom usage string for notifications (the system prompt has none). The permission is asked through the system prompt (Task 10). Nothing to add. | |
| Live Activity | `NSSupportsLiveActivities` is set. There is no usage string for Live Activities; the user controls them in Settings, Soma Flight, Live Activities. | `Apps/iOS/Info.plist` |
| 12 hour clock in the Live Activity | Done through the App Group `group.me.somalabs.flight` (app and extension entitlements). A running activity picks a changed setting up on its next update. | `SharedSettings.swift` |
| Offline cache | SwiftData store at `Application Support/SomaFlight/cache.store`, wiped on sign-out, account change and deletion. | `CacheStore.swift` |
| Export compliance | `ITSAppUsesNonExemptEncryption` = false in all four app Info.plists: HTTPS and Apple's system crypto only, no custom crypto. | `Apps/iOS/Info*.plist`, `Apps/macOS/Info*.plist` |
| Location | Not requested in v1. | |
| Screenshots | Draft set in `docs/screens/final/`: iPhone 17 Pro simulator captures dark and light (`ios/`), Mac window captures (`mac/`, the Mac app is dark only by design), every screen and state rendered dark and light (`rendered/`), Live Activity renders (`docs/screens/live-activity-*.png`). Store screenshots still need the required sizes (6.9 inch iPhone, Mac 2880 x 1800 or 1440 x 900) and real, not seeded, flights. | |

## Open before submission

1. **Apple developer team and profiles.** App IDs `me.somalabs.flight` and `me.somalabs.flight.widgets` with Sign in with Apple, Push Notifications and the App Group `group.me.somalabs.flight`; provisioning profiles for both targets on iOS and for the Mac app (Sign in with Apple and push; the Mac Debug build signs to run locally without them). Not touched by Task 12.
2. **Privacy policy and support pages.** Settings links to `https://somalabs.me/privacy` and `https://somalabs.me/support`; on 2026-10-29 both answered **404** (after a redirect to www). Publish both, then enter the privacy policy URL in App Store Connect. The policy must cover: email and user id, followed flights and flight history, push tokens, FlightAware as the data source, deletion and export.
3. **App Store Connect privacy answers ("data use disclosure").** Match the manifests: Contact Info, Email Address; Identifiers, User ID; User Content, Other User Content. All linked to the user, none used for tracking, purpose App Functionality. No analytics, no diagnostics SDK.
4. **AeroAPI commercial terms.** The app must ship on the Standard tier (B2C distribution), not Personal; the full terms (attribution, caching and retention, redistribution) were not read. See `docs/provider-check.md`.
5. **Release configuration.** Release fails closed without `Config.local.xcconfig` (Supabase URL and anon key); create it on the archiving machine.
6. **Age rating.** Fill the questionnaire: no objectionable content, no user-to-user communication, no web browsing; expected 4+.
7. **Review notes.** A demo account (email sign-in) with a few followed flights, since every screen needs an account on the backend.
8. **Real-device checks still open from earlier tasks.** Real APNs pushes and Live Activity updates, a cold-start notification tap, Keychain under the Mac sandbox, Sign in with Apple on a device, and real taps on the export and deletion rows (the share sheet and the dialog were not driven in this pass).
9. **Interface orientations warning.** The iOS Release device build warns that all interface orientations must be supported unless the app requires full screen; set `UIRequiresFullScreen` or the orientation list before archiving.
