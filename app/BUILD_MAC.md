# Build and run the app on an iPhone (from a Mac)

Step by step, from a Mac with nothing installed to the app open on your iPhone, talking to
the server running on the same Mac. About 1–2 hours the first time (mostly downloads).

> **Status (2026-11-17):** the app passes its 35 automated tests, but it has **not been built
> for iOS yet**. If a step fails, copy the exact error message: it is usually one setting.

## What you need

| | Notes |
|---|---|
| A Mac with macOS 15 or newer | Apple silicon or Intel; ~40 GB free (Xcode is big) |
| An iPhone with iOS 15 or newer | and its USB cable |
| An Apple ID | free works; the app then expires after **7 days** and you run it again. A paid developer account (US$ 99/year) removes that and allows TestFlight and push notifications |
| The same Wi-Fi for Mac and iPhone | the app talks to the server on the Mac |
| No collar needed | sign-up, dogs, profile and the screens work without it; pairing, sync and recording need the collar (Phase 1 hardware) |

Software (installed in step 1): Xcode, Homebrew, Git, Flutter 3.50, Docker Desktop, Node 22.

## 1. Install the tools (once)

1. **Xcode:** App Store → Xcode → Get. Open it once, accept the license and let it install the
   iOS platform (Settings → Components → iOS). Then, in Terminal:

   ```bash
   sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
   sudo xcodebuild -runFirstLaunch
   ```

2. **Homebrew** (installs the rest): follow the one-line command on https://brew.sh, then the
   two lines it prints at the end to add `brew` to your PATH.

3. **Git, Node 22, CocoaPods:**

   ```bash
   brew install git node@22 cocoapods
   brew link --overwrite node@22
   ```

4. **Flutter 3.50** (the version CI uses):

   ```bash
   git clone https://github.com/flutter/flutter.git -b 3.50.0 ~/flutter
   echo 'export PATH="$HOME/flutter/bin:$PATH"' >> ~/.zshrc
   source ~/.zshrc
   flutter doctor
   ```

   `flutter doctor` must show a check mark for **Flutter** and **Xcode**. Android Studio and
   Chrome warnings can be ignored for the iPhone.

5. **Docker Desktop:** https://www.docker.com/products/docker-desktop (pick Apple chip or
   Intel chip). Open it once and wait until it says *Engine running*.

## 2. Get the code

```bash
cd ~
git clone https://github.com/Gustavo-Patrocinio/coleira-inteligente.git
cd coleira-inteligente
```

Later, to update: `git pull` in this folder.

## 3. Start the server (database + API) on the Mac

```bash
cd ~/coleira-inteligente/backend
docker compose up -d                  # the database (Postgres + TimescaleDB)
npm ci
cp .env.example .env
```

Open `.env` (`open -e .env`) and replace `JWT_SECRET` with a long random string, for example
the output of `openssl rand -hex 32`. Then:

```bash
npm run migrate                       # creates the tables
npm run dev                           # leave this Terminal window open
```

Check it: http://localhost:3000/health in Safari shows `{"ok":true}`.
If macOS asks whether `node` may accept incoming connections, click **Allow** (the iPhone
connects to it over Wi-Fi).

Find the Mac's address on the Wi-Fi (you type it in the app):

```bash
ipconfig getifaddr en0                # e.g. 192.168.0.23
```

Your data stays in the Docker database on this Mac (`docker compose down` keeps it;
`docker compose down -v` erases it).

## 4. Open the project in Xcode and sign it

In a **new** Terminal window:

```bash
cd ~/coleira-inteligente/app
flutter pub get
cd ios && pod install && cd ..        # if Flutter uses Swift Package Manager it may say there is nothing to do
open ios/Runner.xcworkspace
```

In Xcode:

1. Left panel: click **Runner** (blue icon) → target **Runner** → tab **Signing &
   Capabilities**.
2. Tick **Automatically manage signing**, and in **Team** pick your Apple ID (*Add an
   Account…* if it is not there).
3. **Bundle Identifier:** change `dev.smartcollar.collarApp` to something only yours, e.g.
   `dev.smartcollar.gustavo` (Apple refuses ids already used by someone else).
4. Do **not** add *Push Notifications* with a free account: it breaks signing.

Close Xcode afterwards (or leave it open; it does not matter).

## 5. Prepare the iPhone (once)

1. Connect it with the cable, unlock it, tap **Trust** this computer.
2. Settings → Privacy & Security → **Developer Mode** → on (the iPhone restarts; confirm).
3. In Terminal, `flutter devices` must list the iPhone.

## 6. Run

```bash
cd ~/coleira-inteligente/app
flutter run --release
```

The first build takes several minutes. On the first launch:

- If the iPhone says **Untrusted Developer**: Settings → General → VPN & Device Management →
  your Apple ID → **Trust**, then open the app again.
- When the app asks to find devices on the **local network**, tap **Allow** (that is how it
  reaches the server on the Mac). Bluetooth and camera permissions are asked when used.

## 7. Use it

1. **Server:** `http://<the Mac's address>:3000`, e.g. `http://192.168.0.23:3000`
   (`http`, not `https`, on your own Wi-Fi).
2. **Create account** with an email and a password of 10+ characters.
3. Read the privacy notice → agree.
4. Register the dog (only the name is required) → *Skip for now* on the collar step.
5. **Profile** tab: your name, password, add more dogs, edit each one. With two or more dogs,
   tap the name at the top of any tab to switch.

Without a collar the screens are empty ("No data for today yet"): that is expected.

After 7 days (free Apple ID) the app stops opening: connect the iPhone and run
`flutter run --release` again. Your account and data are on the server, nothing is lost.

## Something went wrong

| Problem | Fix |
|---|---|
| `flutter doctor`: Xcode not found / incomplete | repeat the two `sudo xcode-select` / `xcodebuild` lines in step 1, open Xcode once |
| `pod install` fails | `cd ios && pod repo update && pod install` |
| Xcode: *No profiles for '…' were found* / *Failed to register bundle identifier* | change the Bundle Identifier to something more unique (step 4.3) and pick your Team again |
| Build error mentioning *iOS deployment target* | the project targets iOS 15; Xcode → Runner → General → Minimum Deployments must be 15.0 |
| *Could not reach the server* in the app | Mac and iPhone on the same Wi-Fi; `npm run dev` still running; the address from `ipconfig getifaddr en0` (it can change after a restart); Local Network allowed (iPhone Settings → Privacy & Security → Local Network → the app); macOS firewall allows `node` |
| `npm run dev`: *JWT_SECRET must be at least 16 characters* | the `.env` file is missing or `JWT_SECRET` is short (step 3) |
| `docker compose up` fails | open Docker Desktop and wait for *Engine running* |
| The app opened before, now it does not | 7-day limit of a free Apple ID: run `flutter run --release` again |

Anything else: copy the full error (Terminal or Xcode) and open an issue or send it to whoever
helps you.
