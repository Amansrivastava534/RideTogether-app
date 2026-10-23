# RideTogether

Live group bike tracking: friends on multiple bikes join one ride and see each other on a Google Map in real time — who is ahead, who is behind, who has stopped — without phone calls.

Flutter (Android + iOS) · Firebase Auth / Cloud Firestore / Cloud Functions / Cloud Messaging / Hosting · Riverpod 3 · google_maps_flutter · geolocator.

Firebase project: **`ridetogether-4590`** (personal account `amansrivastava4590@gmail.com` — never use the work account for this repo; the CLI is bound per-directory, see [Setup](#1-firebase-cli-account)).

---

## Contents

- [Architecture](#architecture)
- [Data model](#data-model)
- [Security](#security)
- [Location tracking, battery & cost](#location-tracking-battery--cost)
- [Setup](#setup)
- [Build & run](#build--run)
- [Deploy](#deploy)
- [Tests](#tests)
- [iOS](#ios)
- [iPhone without the App Store (web app)](#iphone-without-the-app-store-web-app)
- [Two-phone testing checklist](#two-phone-testing-checklist)
- [Status & known limitations](#status--known-limitations)

---

## Architecture

```
lib/
  main.dart, app.dart          Firebase init, offline cache, routes, auth gate, deep links (/j/CODE)
  providers.dart               Riverpod providers (repos, streams, settings, clock)
  core/                        geo maths (distance, polyline, simplify), shared UI widgets/theme
  domain/
    models.dart                UserProfile, Ride, RideMember, LiveLocation, RideInvitation, RideHistory, RideAlert
    ride_logic.dart            status (moving/stopped/stale/offline), membership, invite codes,
                               group spread, fall-behind detector, adaptive publish policy
  data/                        RideRepository, UserRepository — the only code that talks to Firebase
  features/
    auth/ profile/ home/       sign-in, profile & settings, dashboard
    ride/                      create, join, waiting room, ride settings, ride lifecycle (RideScope)
    map/                       live map, markers (custom icons + bearing arrow), bottom panel
    tracking/                  LocationPublisher (throttle/coalesce), TrackingController (GPS, recovery)
    history/                   ride history, ride summary
firestore.rules                authorization (the real security boundary)
firestore.indexes.json         TTL policies (retention)
functions/                     push notifications only (SOS, join requests)
web/                           web app (PWA): index.html, manifest, icons, privacy page, App Link / Universal Link files
firestore-tests/               security-rules integration tests (emulator)
```

Widgets never call Firebase directly; they go through repositories exposed as providers. Domain logic is pure Dart and unit tested.

### Why Cloud Firestore (not Realtime Database)

| | Firestore | Realtime Database |
|---|---|---|
| Pricing | per document read/write | per GB stored / downloaded |
| High-frequency small writes | fine at our volume (see cost) | cheaper at very large scale |
| Security rules | can `get()` membership docs | can't read Firestore; membership would have to be mirrored |
| Offline cache & queued writes | built in | built in |
| Automatic cleanup | native TTL policies | needs a scheduled function |

One database means one rule set and no mirrored membership to keep in sync. At group-ride scale (a handful of riders, a few hours) the per-op cost is cents per ride. Revisit RTDB only if rides grow to dozens of riders updating every second.

---

## Data model

```
users/{uid}                        name, photoUrl, bikeName, historyConsent, fcmTokens[]   (private)
users/{uid}/recentRides/{rideId}   name, joinedAt, expireAt                                 (private)
users/{uid}/history/{rideId}       name, startedAt, endedAt, distanceMeters,
                                   polyline (simplified, ≤1500 pts), participants[], expireAt (private)

invites/{CODE}                     rideId, rideName, requireApproval, createdBy, expireAt   (get-only, 8-char code)

rides/{rideId}                     name, ownerId, code, requireApproval, status (waiting|active|ended),
                                   createdAt, startedAt, endedAt, fallBehindMeters, expireAt
rides/{rideId}/members/{uid}       name, photoUrl, bikeName, role (owner|member),
                                   status (pending|active|removed), joinedAt, inviteCode, expireAt
rides/{rideId}/locations/{uid}     lat, lng, accuracy, speed, heading, clientTs, serverTs, sharing, expireAt
rides/{rideId}/alerts/{id}         type=sos, uid, name, lat, lng, createdAt, expireAt
```

- **Latest location only**: one document per rider, overwritten. No GPS stream is ever appended to a document.
- **Route history** (opt-in) is kept on the device while riding, then simplified (Douglas–Peucker, 10 m) and saved once at ride end as an encoded polyline.
- **Ordering**: `clientTs` (GPS fix time) must strictly increase — enforced by the rules — so a delayed/offline write can never replace a newer position. `serverTs = request.time` is used for freshness.

### Retention (Firestore TTL on `expireAt`)

| Data | Deleted |
|---|---|
| Live location | on stop/leave; otherwise ~24 h after the last update |
| Invites | 24 h after creation (also rejected by the rules once expired) |
| Rides, members, recent rides | 30 days |
| SOS alerts | 7 days |
| Ride history | 90 days, or any time by the user |
| Account | Profile & settings → Delete account (history, memberships, profile, auth user) |

TTL deletion runs within ~24 h of expiry. **TTL policies require the Blaze plan** (see [Deploy](#deploy)).

---

## Security

All authorization is in [`firestore.rules`](firestore.rules); client checks only pick the UI.

- Only **active members** of a ride can read its members, locations and alerts. Pending members can read the ride name only.
- Joining requires a **valid, unexpired invite code for that ride**; the member status must match the ride's real approval setting (`pending` if approval is on).
- A rider can only write **their own** location, only while active, only while the ride hasn't ended, with validated fields, `serverTs == request.time`, no future timestamps, and strictly newer `clientTs`.
- Only the owner can approve/remove riders, change settings, rotate the invite code, start or end the ride. Status only moves forward; ended rides are frozen.
- **Removed** riders keep a tombstone they can't delete, so they can't rejoin with the old code.
- Invites are `get`-only (no listing). Codes: 8 chars from a 31-symbol alphabet (~8.5×10¹¹), generated with `Random.secure()`, rotatable.
- Profiles, FCM tokens and history are readable only by their owner. Cloud Functions re-check membership before sending any push.
- No admin credentials or secrets are in the app. The Maps key lives in a gitignored `.env` and must be restricted (see Setup).

Tracking actually stops (GPS stream cancelled → foreground service ends) on pause, stop, leave, ride end, removal, sign-out and account deletion — and the backend rejects writes after removal/end regardless.

---

## Location tracking, battery & cost

**Permissions** are requested only when the user taps *Share my location*, after an in-app explanation:

- Android: `ACCESS_FINE_LOCATION` ("while using the app") + a **location foreground service** with a persistent notification. Because the service starts while the app is in use, `ACCESS_BACKGROUND_LOCATION` is **not** requested — the Play-policy-friendly path.
- iOS: "When In Use" + `UIBackgroundModes: location` with the blue background indicator. "Always" is never requested (the usage string exists only because App Review requires it for the plugin).
- Notifications (FCM) are requested when the user first starts sharing.

**Adaptive publishing** ([`PublishPolicy`](lib/domain/ride_logic.dart)):

| Situation | Write when |
|---|---|
| Moving (≥ 1.5 m/s) | every ≥ 4 s and moved ≥ max(10 m, accuracy) |
| Stopped | every ≥ 15 s if it moved; otherwise heartbeat |
| Heartbeat | every 30 s (keeps peers from seeing you as stale) |
| Battery ≤ 20 % | intervals × 2.5 (heartbeat unchanged) |
| Poor GPS (> 100 m) | heartbeat only |

At most **one write is in flight**; while offline, newer fixes replace the queued one, so reconnecting sends at most two writes, never a backlog.

**Freshness on the map**: no update for 45 s → *Location unavailable* (grey marker); 3 min → *Offline / last seen …*. Stale riders are never drawn as live.

**Fall behind / group spread**: distance from the group's *median* point; needs ≥ 3 riders with good GPS, a 60 s dwell beyond the threshold (default 3 km, owner-configurable) and hysteresis before clearing. It only reports distance — it never infers a crash.

**Estimated cost** (5 riders, 3 h, mostly moving):

| | Count | Approx. cost |
|---|---|---|
| Location writes | 5 × 2,700 ≈ 13.5 k | ~ $0.03 |
| Rule `get()`s (member + ride per write) | ≈ 27 k reads | ~ $0.02 |
| Listener reads (each write → 5 listeners) | ≈ 67.5 k reads | ~ $0.04 |
| **Per ride** | | **≈ $0.10** |

The free tier (50 k reads / 20 k writes per day) covers roughly one such ride a day. Functions and FCM cost are negligible at this volume. Figures are estimates — check the Firebase usage dashboard after real rides.

**Battery**: GPS stays on (high accuracy) while sharing; expect roughly 5–10 % per hour depending on the phone. Writes are throttled, so radio use is modest. Measure on your devices before relying on these numbers.

---

## Setup

### Prerequisites

- Flutter 3.35+ (Dart 3.9), Android SDK 36, Android Studio's JBR (Gradle runs on it; Java 25 is not supported by Gradle 8.12)
- Node 22+ and Firebase CLI (`firebase-tools`) for rules/functions
- Xcode 16+ and CocoaPods for iOS (not installed on the current dev Mac)

### 1. Firebase CLI account

This folder is bound to the personal account (the global default may be a work account):

```bash
firebase login:add
```

```bash
firebase login:use amansrivastava4590@gmail.com
```

```bash
firebase login:list
```

The first line must say `Logged in as amansrivastava4590@gmail.com` when run inside this folder.

### 2. Firebase console (one-time)

- **Authentication → Sign-in method**: enable **Google** and **Anonymous**.
- **Firestore**: database `(default)` in `asia-south1` (already created).
- **Project settings → Android app**: add the SHA-1 and SHA-256 of every signing key (debug key already added; add your release/upload key and the Play App Signing key).
- **Upgrade to Blaze** for TTL cleanup, Cloud Functions and Google Maps.

After changing providers or SHAs, refresh the app config:

```bash
flutterfire configure --project=ridetogether-4590 --platforms=android,ios --android-package-name=com.ridetogether.app --ios-bundle-id=com.ridetogether.app --yes
```

### 3. Google Maps API key

In [Google Cloud Console](https://console.cloud.google.com/apis/credentials?project=ridetogether-4590), enable **Maps SDK for Android** (and **Maps SDK for iOS**) and create keys:

- Android key — *Application restriction*: Android apps → `com.ridetogether.app` + SHA-1 of each signing key. *API restriction*: Maps SDK for Android.
- iOS key — *Application restriction*: iOS apps → `com.ridetogether.app`. *API restriction*: Maps SDK for iOS.

Put the Android key in the repo-root `.env` (gitignored; Gradle injects it into the manifest):

```bash
echo "MAPS_API_KEY=YOUR_ANDROID_KEY" >> .env
```

For iOS create `ios/Flutter/Secrets.xcconfig` (gitignored) containing `MAPS_API_KEY = YOUR_IOS_KEY`.

### 4. Release signing (Android)

Until `android/key.properties` exists, release builds are signed with the **debug key** — fine for testing, never for the Play Store. Create an upload key (keep it and its passwords out of git and backed up):

```bash
keytool -genkey -v -keystore ~/ridetogether-upload.jks -keyalg RSA -keysize 2048 -validity 10000 -alias upload
```

Then create `android/key.properties`:

```
storeFile=/Users/<you>/ridetogether-upload.jks
storePassword=…
keyAlias=upload
keyPassword=…
```

Add the new key's SHA-1/SHA-256 to Firebase and to the Maps key restriction, and its SHA-256 to `web/.well-known/assetlinks.json`.

---

## Build & run

```bash
flutter pub get
```

```bash
flutter run --release
```

```bash
flutter build apk --release
```

Output: `build/app/outputs/flutter-apk/app-release.apk`. For Play: `flutter build appbundle --release`.

Install on a specific connected device:

```bash
adb -s <serial> install -r build/app/outputs/flutter-apk/app-release.apk
```

---

## Deploy

```bash
firebase deploy --only firestore:rules
```

Needs Blaze (TTL policies):

```bash
firebase deploy --only firestore:indexes
```

Needs Blaze (push notifications for SOS and join requests):

```bash
firebase deploy --only functions
```

Web app (PWA), invite links, privacy page, App Link / Universal Link files (builds the web app first):

```bash
firebase deploy --only hosting
```

For release builds, set the real values in `web/.well-known/assetlinks.json` (release SHA-256) and `web/.well-known/apple-app-site-association` (replace `APPLE_TEAM_ID`).

`functions/` pins `firebase-functions@6` because the installed firebase-tools (14.17) can't load v7 in the emulator; upgrade both together.

---

## Tests

Unit tests (distance, polyline, stale detection, status, membership, invite codes, group spread / fall-behind, publish policy, publisher coalescing & shutdown):

```bash
flutter test
```

```bash
flutter analyze
```

Security-rules integration tests — create → join → approve → share → end, non-member access, removal, out-of-order writes, ended rides, SOS, private data (23 cases, Firestore emulator; needs Java):

```bash
cd firestore-tests && npm install && npm test
```

Function trigger smoke test (emulator; no real FCM delivery):

```bash
firebase emulators:exec --only firestore,functions --project demo-ridetogether "node firestore-tests/fn-smoke.mjs"
```

**Regenerating the app icon** (orange background + white bike, same glyph as the splash) — writes all Android mipmaps and iOS AppIcon PNGs:

```bash
FLUTTER_ROOT=$(dirname $(dirname $(readlink -f $(which flutter)))) flutter test tool/generate_icons.dart
```

Then strip alpha from the iOS PNGs (App Store rejects icons with an alpha channel), e.g. round-trip each through JPEG with `sips`.

**Simulating movement on the Android emulator**: `adb emu geo fix <lng> <lat> 0 8 <knots>` (the velocity argument makes the rider show as *Moving*; `geo nmea` is ignored by current emulators).

---

## iOS

Configured but **not built on this machine** (Xcode isn't installed):

- `Info.plist`: location usage strings, `UIBackgroundModes` (location, remote-notification), `ridetogether://` scheme, Google Sign-In reversed client ID, `GMSApiKey` from `Secrets.xcconfig`.
- `Runner.entitlements`: push (`aps-environment`) and Associated Domains (`applinks:ridetogether-4590.web.app`) — needs a paid Apple Developer team.
- Deployment target iOS 15; `Podfile` included.

Steps on a Mac with Xcode:

1. Create `ios/Flutter/Secrets.xcconfig` with `MAPS_API_KEY = …`.
2. Open `ios/Runner.xcworkspace`, select your team, and enable the *Push Notifications*, *Background Modes → Location updates* and *Associated Domains* capabilities.
3. Upload an APNs auth key in Firebase → Project settings → Cloud Messaging.
4. Run `cd ios && pod install`, then `flutter run --release` on a device.

Background location, push and Universal Links need a **physical iPhone**. iOS may still throttle or suspend background delivery (Low Power Mode, force-quit by the user); riders will then show as *Location unavailable* / *Last seen* rather than as live.

---

## iPhone without the App Store (web app)

The same Flutter code is deployed as a **web app (PWA)** at **https://ridetogether-4590.web.app** — free, no Apple Developer account. iPhone users open it in **Safari → Share → Add to Home Screen** and get a RideTogether icon that opens full screen. Invite links (`/j/CODE`) open the Join screen directly; Android users with the app installed are sent to the app instead (App Links).

What differs from the native apps:

- Location is shared **only while the page is open**. The screen is kept awake while sharing (Screen Wake Lock); locking the phone or switching apps pauses updates and friends see *Location unavailable / Last seen*.
- No push notifications (SOS and join requests appear in-app while open).
- Google sign-in uses a full-page redirect on the same domain (Safari-safe); guests work as usual.
- Your own position is drawn as your marker (no native blue dot).

Setup: enable **Maps JavaScript API**, create a key restricted to *Websites* `https://ridetogether-4590.web.app/*`, `https://ridetogether-4590.firebaseapp.com/*`, `http://localhost/*` and API *Maps JavaScript API*, then:

```bash
echo "MAPS_WEB_API_KEY=YOUR_WEB_KEY" >> .env
```

Deploy (the `predeploy` hook runs `flutter build web --release --dart-define-from-file=.env`):

```bash
firebase deploy --only hosting
```

Local preview with the same rewrites (port 5050):

```bash
firebase emulators:start --only hosting
```

## Two-phone testing checklist

Use two real phones (A = owner, B = joiner), both on the same release build. Tick each box.

**Accounts & joining**
- [ ] A: *Continue with Google* signs in; profile setup saves name/bike.
- [ ] B: *Join as guest* works.
- [ ] A: *Create ride* with *Approve riders* on → waiting room shows an 8-char code.
- [ ] A: *Invite* opens the share sheet (WhatsApp); *Copy link* copies `https://ridetogether-4590.web.app/j/CODE`.
- [ ] B: entering a wrong code → "No ride found"; the right code → *Waiting for approval*.
- [ ] B (pending): cannot see riders or locations.
- [ ] A: request appears under *Join requests*; approve → B moves to the waiting room/map automatically.
- [ ] A: *Start ride* → both switch to the live map; elapsed time starts.

**Live map**
- [ ] Both: *Share my location* shows the explanation, then the OS prompt; pill turns green *You're sharing*; Android shows the persistent notification.
- [ ] Each sees the other's marker (initials, colour) and *n/n live*.
- [ ] Walk/ride with B: B's marker moves smoothly on A, status *Moving*, speed shown, arrow points in direction of travel.
- [ ] Tap a rider: card shows speed, *updated …*, GPS accuracy and *≈ distance (straight-line)*.
- [ ] *Show everyone* fits both; *Center on me* centres A; zoom buttons work; dark theme switches map style.
- [ ] *Navigate in Google Maps* opens Google Maps with the rider as destination.

**Freshness & resilience**
- [ ] B: *Pause* → A shows *Sharing paused* at B's last point. *Resume* → live again.
- [ ] B: airplane mode for 1 min → A shows *Location unavailable* (~45 s), then *Offline · last seen …* (~3 min); B shows the offline banner. Back online → B updates within seconds, no jumps backwards.
- [ ] B: screen off, phone in pocket for 5 min while moving → A keeps receiving updates (Xiaomi/Oppo/Vivo: set battery usage *Unrestricted* first).
- [ ] B: swipe the app away → A sees B go stale (expected: tracking stops when the process is killed). Reopen → *Location sharing resumed*.
- [ ] B: revoke location permission in system settings → app shows an error; A sees B go stale.

**Safety**
- [ ] With 3+ riders, one rider ≥ threshold away for > 1 min → others see "*X is ≈ … behind the group*" banner.
- [ ] B: *SOS* → confirmation explains limits → A gets an in-app alert (and a push, once Functions are deployed).

**Ending & privacy**
- [ ] B: *Stop sharing* → B disappears from A's map; Android notification disappears.
- [ ] A (owner): *Remove* B → B leaves the map and sees *You are no longer a member*; B can't rejoin with the same code.
- [ ] A: *New invite code* → old code fails, new code works.
- [ ] B: *Leave ride* → B gone from A's list; sharing stops.
- [ ] A: *End ride for everyone* → both see the summary; tracking stops on both (notification gone).
- [ ] With *Save my routes* on: history shows the route, distance, duration; *Delete* removes it.
- [ ] *Delete account* removes profile/history and signs out.
- [ ] A third phone/account that never joined cannot open the ride (verified by rules tests; optional manual check).

---

## Status & known limitations

Verified so far (Oct 2026): unit tests (30) and rules tests (23) pass; Android release build installs and runs; on an emulator + a Xiaomi (Android 13): guest/Google sign-in, profile, create ride, join with approval, start ride, live sharing both ways, map tiles, *Moving* status with speed and direction (simulated), straight-line distance, restart recovery, Navigate hand-off.

Not yet verified / pending:
- Blaze plan → TTL policies and Cloud Functions (push) are written and emulator-tested but **not deployed**.
- Web app deployed to https://ridetogether-4590.web.app; the map needs `MAPS_WEB_API_KEY` in `.env` and a redeploy. Location sharing in a real iPhone Safari not yet verified.
- Release signing uses the debug key until `android/key.properties` is set up.
- iOS not built (no Xcode on the dev Mac).
- Two real phones riding apart, background delivery with screen off, SOS push — use the checklist above.
- Profile photo comes from the Google account only (no custom upload); guests get initials.
- An in-app road-route polyline was prototyped and removed (Routes API key restriction issue); only the Google Maps hand-off remains.
- Background tracking stops if the OS or the user kills the app process; it is not restarted automatically.
