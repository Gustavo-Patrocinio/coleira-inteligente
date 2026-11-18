# Smart Collar app (Flutter, iOS + Android)

One codebase for iPhone and Android:

- **Today / Trends / Alerts** from the backend: 24 h timeline, Exercise, Sleep (night
  wake-ups) and Skin (scratching) indicators, daily trends, alerts in plain language with
  "made sense / false alarm" feedback (docs/product/indicators.md).
- **Sync** (contract 4.8): pairs the collar and syncs on its own whenever the app opens near
  it; the records stay on the phone too, so Today works offline.
- **Collection mode** (Phase 1): connects to the collar (logger firmware, or the normal
  firmware in raw dump mode, ADR 0014) over BLE, films the dog and
  writes `imu.csv` + `meta.json` (contracts 4.4–4.5, ADR 0003) at the same time, then shares
  the session folder to your computer for the labeler.

Screens follow the clickable prototype (`docs/product/app-prototype/`).

## Code map

| Folder | What |
|---|---|
| `lib/core/` | contracts: class IDs and colors, raw packet (4.4), per-minute record (4.7), GATT UUIDs |
| `lib/collar/` | `CollarLink` interface + `universal_ble` implementation (ADR 0012) |
| `lib/collection/` | `SessionRecorder` (CSV + meta.json) and the recording screen |
| `lib/api/` | backend client, day/timeline helpers, alert copy |
| `lib/ui/` | login, onboarding (consent, dog, pairing), home tabs, Today, Trends, Alerts, Collar |
| `test/` | contract byte vectors (shared with Python/backend), recorder, API client, full widget flow |

```bash
flutter analyze
flutter test        # 35 tests, no device needed
```

## Run on your iPhone (from the MacBook)

Full step-by-step guide, from a Mac with nothing installed: **[BUILD_MAC.md](BUILD_MAC.md)**. Short version:

1. Install Xcode (App Store) and Flutter on the Mac
   (`git clone https://github.com/flutter/flutter.git -b stable ~/flutter`, add
   `~/flutter/bin` to the PATH), then `flutter doctor`.
2. Clone this repo on the Mac, `cd app`, `flutter pub get`.
3. Open `ios/Runner.xcworkspace` in Xcode → *Runner* → *Signing & Capabilities* → pick your
   Apple ID as the team (a free account works; the app then needs reinstalling every 7 days;
   a paid developer account allows TestFlight). Change the bundle id if Xcode asks
   (e.g. `dev.smartcollar.<yourname>`).
4. Connect the iPhone by cable, trust the computer, enable *Developer Mode* on the iPhone
   (Settings → Privacy & Security), then `flutter run --release`.

BLE and the camera only work on a real phone, not in the simulator.

## Talking to the backend

Run the backend on your computer (`backend/README.md`) and, on the phone's login screen, use
the computer's LAN address, e.g. `http://192.168.0.10:3000` (same Wi-Fi). Plain HTTP is only
allowed for the local network (iOS `NSAllowsLocalNetworking`); a public server must use HTTPS.

## Push notifications (optional)

The app works without them: alerts show in the Alerts tab. Built without Firebase files, it
quietly skips push (`NoPush`). To turn them on for your server:

1. In the Firebase project of your server (`backend/DEPLOY.md`, *Push notifications*), add an
   Android app and an iOS app with this app's package/bundle id.
2. Download `google-services.json` → `android/app/`, and `GoogleService-Info.plist` →
   `ios/Runner/` (add it to the Runner target in Xcode). Both are ignored by git: they belong
   to your Firebase project.
3. Android: add the Google services Gradle plugin as the Firebase console shows.
4. iOS needs a **paid** Apple developer account: Xcode → *Signing & Capabilities* → add *Push
   Notifications* and *Background Modes → Remote notifications*; upload an APNs key in the
   Firebase console (Project settings → Cloud Messaging). With a free account, leave this out
   (the capability breaks free signing) and use the Alerts tab.

The app asks for notification permission right after the consent screen and sends the token
to the server (`PUT /v1/me/push-token`); signing out removes it.

## Status

- [x] `flutter analyze` clean, 35 tests passing (2026-11-17)
- [ ] Collection mode tested with the real collar logger (needs the XIAO)
- [ ] Installed on an iPhone and an Android phone
- [x] Phase 3 sync (contract 4.8): pair collar, "Sync now", upload via `api.ingest` (22 tests)
- [x] Automatic sync when the app opens / returns to the foreground (throttled to 10 min);
      records kept on the phone so Today works offline and failed uploads are retried
- [x] First-run onboarding: privacy notice + consent (LGPD, recorded on the server) → dog → pair
      collar; "Your data": download everything / delete the account
- [x] Several dogs and collars per account: Profile tab (owner name, password, dogs with
      sex, neutering, breed, birth date, weight), dog switcher on every tab, several collars
      per dog, unpair, all paired collars synced in one go, local cache kept per dog
- [x] Sleep on Today: bedtime–wake time, rest, awakenings, naps (estimated from movement)
- [x] Push notifications for new alerts (FCM, token sent after consent, removed on sign-out);
      [ ] tested on a real phone with a Firebase project
- [x] Firmware update from the newest GitHub release (BLE, MCUboot SMP)
- [ ] Base-station Wi-Fi provisioning
