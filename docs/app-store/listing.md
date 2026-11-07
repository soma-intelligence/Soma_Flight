# Soma Flight: App Store listing

Text for App Store Connect, version 1.0, English (U.S.). Limits are Apple's; `Scripts/asc/push_listing.py` checks them and pushes this file.

## App information

- **Name** (30): Soma Flight - Travel Smarter
- **Subtitle** (30): Live flight status and log
- **Bundle ID**: me.somalabs.flight
- **SKU**: set when the record was created
- **Primary category**: Travel
- **Secondary category**: Navigation
- **Content rights**: the app shows third-party content (flight data from FlightAware AeroAPI, airline names and marks). Answer "Yes, it contains third-party content, and I have the rights".
- **Age rating**: 4+. Every questionnaire answer is None or No: no violence, no mature themes, no gambling, no contests, no unrestricted web access, no user-generated content shown to strangers (friends see only flights they were invited to see), no medical content.
- **Copyright**: 2026 Quentin Caron
- **Price**: Free, all territories.

## URLs

- **Privacy Policy URL**: https://somalabs.me/legal/soma-flight-privacy
- **Support URL**: https://somalabs.me/support
- **Marketing URL**: https://somalabs.me

Both pages are on the landing `main` (PRs #151 and #154) but answer 404 until production is deployed again.

## Promotional text (170)

Know where your flight is, when it boards and which gate before the screen at the airport changes. Every trip lands in your Passport. No ads, no tracking, ever.

## Description (4000)

Soma Flight follows your flights for you, from booking to baggage claim, and keeps a record of every trip you take.

FOLLOW ANY FLIGHT
Search by flight number, route or airport and follow it in one tap. Departure and arrival times, gates, terminals and delays update on their own, and Soma Flight tells you when something changes.

ON YOUR LOCK SCREEN
A Live Activity shows the countdown to departure, the time left in the air and your arrival gate, on the Lock Screen and in the Dynamic Island. Widgets keep your next flight on the Home Screen, and the Apple Watch app puts it on your wrist.

LEAVE ON TIME
See when to leave for the airport, based on the drive and the time you like to arrive early.

YOUR PASSPORT
Flights you take land in your Passport: a map of every route, the distance you have flown, the hours in the air, the airports, airlines and aircraft you have used. Import past trips from a file, a boarding pass or a confirmation email you share with the app.

TRAVEL WITH FRIENDS
Invite friends with a link and see their upcoming flights next to yours. You choose what they see.

YOUR DOCUMENTS IN ONE PLACE
Keep loyalty numbers and passport details in the app. They are encrypted on your iPhone before they sync, so nobody else can read them.

PRIVATE BY DESIGN
No ads. No analytics. No tracking. Soma Flight never reads your mailbox or your contacts. Your data is used to run the app and nothing else, and you can export it or delete your account from Settings at any time.

Flight data provided by FlightAware.

## Keywords (100)

flight,tracker,status,delay,gate,boarding,airport,airline,arrival,departure,live,trip,log,plane,map

## What's New (version 1.0)

First release.

## App Review information

- **Sign-in required**: unchecked. No demo account: the reviewer signs in with their own Apple ID (owner's choice, 2026-11-05). Email sign-in is a magic link, so it cannot serve as a demo login.
- **Contact**: Quentin Caron, quentin@somalabs.me, phone set in App Store Connect.
- **Notes**:

  No demo account is needed. Sign in with Apple (or Google) using any account: Soma Flight creates the account on first sign-in. A new account starts empty: search a flight number, route or airport (for example SFO AUS) and tap Add to follow it.

  Flight data comes from FlightAware AeroAPI through our backend. Location is asked only from "Leave by" on a flight, to compute the drive time; it never leaves the device. The camera is used only to scan a boarding pass. Calendar access is asked only when the user turns on Calendar in Settings.

  Account deletion: Settings, Account, Delete Account.

## App Privacy (data use disclosure)

Published in App Store Connect on 2026-11-05. Matches `Apps/iOS/PrivacyInfo.xcprivacy`. Tracking: No. Every type below is linked to the user and used for App Functionality only.

| Category | Type |
|---|---|
| Contact Info | Name (display name shown to friends) |
| Contact Info | Email Address |
| Identifiers | User ID |
| Identifiers | Device ID (push tokens) |
| User Content | Photos or Videos (profile photo) |
| User Content | Other User Content (followed flights, flight history, travel documents, sealed) |
| Usage Data | Product Interaction (rate-limit records) |

## Screenshots

Uploaded 2026-11-05 to the "iPhone with Dynamic Island (medium display)" slot (APP_IPHONE_61, 1206 x 2622) from `docs/app-store/screenshots/iphone-6.3/`; App Store Connect scales them to the other iPhone sizes. Sources at 1320 x 2868 in `iphone-6.9/`. Mac (2880 x 1800) later, with the Mac version.
