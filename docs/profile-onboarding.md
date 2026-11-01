# Profile onboarding

A short screen right after the first sign-in: a photo, a first name and a last name. Friends see the name and photo; nobody else does.

## How it works

- **Who sees it.** `ProfileStore.prepare(owner:)` shows it when `profiles.onboarded_at` is null, or when the profile has no name and the user did not press Later on this device. Later stamps `onboarded_at`, so it is shown once. An account already done on this device opens straight on the home without waiting for the network. Settings > Profile opens the same screen in edit mode (with the emoji shown when there is no photo).
- **Prefill.** `ProfileDraft.prefill`: the profile's own names, else the provider's given and family names, else its full name, else a name read from the email. Google's picture (`avatar_url` or `picture`) is offered as the starting photo and uploaded as the user's own only on Continue.
- **Apple.** `ASAuthorizationAppleIDCredential.fullName` arrives on the first authorization only, and Apple never gives a photo. `SignInView` asks for `.fullName`, and `SupabaseAuthService.signInWithApple(idToken:nonce:fullName:)` saves it at once to the account's metadata (`full_name`, `given_name`, `family_name`, through `auth.update(user:)`) and to `profiles.first_name`, `last_name`, `display_name` when they are still empty. `SessionStore.appleName` keeps it in memory for the onboarding in case a write failed.
- **Never a random string as a name.** `DisplayName.resolve` (pure, tested in `DisplayNameTests`): typed name, provider full name, given plus family, then the email's local part only when the address is not a private relay (`privaterelay.appleid.com`, or an iCloud, me.com or mac.com address with digits, the iCloud+ Hide My Email shape) and it reads like a name (letters, at most one dot or underscore). Ids, hashes, digit runs and addresses are skipped. Otherwise it is empty and the screen asks.
- **Photo.** PhotosPicker (iPhone and Mac), the front camera on iPhone, or initials on the user's colour. `AvatarImage.jpeg` squares it to 512 px and re-encodes it with no metadata (no EXIF, GPS, camera or date).
- **Header.** The gear at the top right of My Flights, Friends and Passport is now `ProfileButton`: the photo, else the initials, else a person glyph (signed out or loading), in the same glass circle, opening Settings. VoiceOver: "Settings and profile".

## Storage (migration `20261031000030_profile_onboarding.sql`)

- `profiles`: `first_name`, `last_name` (1 to 40 characters), `avatar_path` (only `<user_id>/avatar.jpg`), `onboarded_at`. `display_name` and `emoji` already existed (20261031000022); the app writes `display_name` from first and last name, so Friends keep reading one column. Owner updates through column grants.
- Bucket `avatars`: private, JPEG only, 1 MB at most. Storage policies: the owner inserts, replaces, deletes and reads `<own id>/avatar.jpg`; a friend reads it (the caller's own `friendships` row must point at the photo's owner). The app reads through signed URLs that live 5 minutes.
- `friend_avatars()`: the caller's mutual, active friends who have a photo, with the object's `updated_at` as the cache key. Allow-listed in `archive_test.sql`'s client function guard.
- `delete-account` removes `avatars/<user_id>/avatar.jpg` and clears the new columns, before deleting the auth user.

## Owner steps

1. **Push the migration** (needs your yes): `supabase db push` applies `20261031000030_profile_onboarding.sql` (renumber it if another 30 lands first). Then deploy `delete-account` (`supabase functions deploy delete-account`), which now removes the photo. Order: migration first, then the function.
2. **Google sign-in** (optional, off today):
   1. Google Cloud console: create an OAuth consent screen (app name Soma Flight, support email, privacy policy `https://somalabs.me/privacy`, scopes `openid`, `email`, `profile` only).
   2. Create an OAuth client ID of type **Web application**. Authorized redirect URI: `https://<project-ref>.supabase.co/auth/v1/callback`.
   3. Supabase dashboard > Authentication > Providers > Google: enable, paste the web client ID and secret.
   4. Supabase > Authentication > URL Configuration: add `somaflight://auth-callback` to the redirect allow list (already needed by the email link).
   5. Set `GOOGLE_SIGN_IN_ENABLED = YES` in `Apps/iOS/Config.Release.xcconfig` and `Apps/macOS/Config.Release.xcconfig` (and the Debug ones to try it). The app then shows "Continue with Google" on Sign In and runs Supabase's web flow in an `ASWebAuthenticationSession`; no Google SDK and no extra URL scheme are needed (the `somaflight` scheme is already registered).
   6. Before release, check Google's branding rules for the button (the app shows a plain "Continue with Google" with a system glyph, not Google's mark) and add Google to the privacy policy's sign-in providers.
3. **App Store privacy answers**: add Name and Photos (linked to the user, app functionality, not tracking). The privacy manifests already declare them.
