# Putting the firmware on the collar (no programming needed)

The firmware files come ready-made on the project's GitHub **Releases** page. You do not need
to install any developer tools: a USB-C data cable and a computer (Windows, macOS or Linux)
are enough.

> Prototype firmware: tested by the project's continuous integration (it compiles, the logic
> passes its tests) but still early on real boards. Supervised use only (see the build guide).

## Which file do I need?

| File | What it is | Who |
|---|---|---|
| `collar.uf2` | **The collar firmware.** Recognizes behavior, stores ~13 days, syncs with the app | everyone |
| `collar-logger.uf2` | Raw-data logger, only for checking a new board (build guide step 3) | builders |
| `collar-debug-log.uf2` | Same as `collar.uf2` plus a log on the USB serial port | developers |
| `collar-ota-*.hex` / `.bin` / `.zip` | Wireless-update version (needs an SWD probe once) | developers, see below |
| `SHA256SUMS.txt` | Checksums to confirm the download is intact | optional |

Files that end in `-devkey` are signed with the public development key: fine for the bench,
not for a collar you hand to someone else (see `firmware/app/README.md`, *Signing key*).

## Flash `collar.uf2` (about 1 minute)

1. Download `collar.uf2` from the latest release.
2. Plug the XIAO into the computer with a **data** USB-C cable (some cables only charge: if
   nothing happens, try another).
3. **Double-tap** the tiny reset button next to the USB-C connector. The orange LED pulses and
   a drive named **`XIAO-SENSE`** appears, like a USB stick.
   - Inside the case: the button sits next to the USB-C slot; use a toothpick.
   - On macOS, ignore the "disk not ejected properly" warning that shows up at the end.
4. Drag `collar.uf2` onto the `XIAO-SENSE` drive. The drive disappears by itself after a few
   seconds: that means it worked.
5. Open the app: under **Collar → Pair collar**, the collar shows up as `Collar`.

Your stored data: flashing a new `collar.uf2` keeps the minutes already in the collar, but
sync before flashing anyway. Switching to the logger and back erases them.

## Something went wrong?

| What you see | What to do |
|---|---|
| No `XIAO-SENSE` drive after the double-tap | Tap faster (two taps within half a second); try another cable and another USB port |
| The drive appears but copying fails | Copy again; on Windows, make sure the file is `.uf2`, not `.uf2.txt` |
| The app does not find `Collar` | Bluetooth on, phone within 1 m; unplug and replug the collar; check you flashed `collar.uf2`, not the logger |
| Still nothing | Open an issue on GitHub with your computer's OS, what you did and a photo of the board |

## Checking the download (optional)

Compare the file's SHA-256 with the line in `SHA256SUMS.txt`:

- Windows (PowerShell): `Get-FileHash collar.uf2`
- macOS / Linux: `shasum -a 256 collar.uf2`

## Wireless updates (OTA)

The OTA files replace the board's USB bootloader with MCUboot, so later updates go over
Bluetooth from the phone: in the collar app, **Collar → Collar firmware → Check for
updates**. That first step needs an SWD probe (a Raspberry Pi Pico works); the steps are in
`firmware/app/README.md`, *OTA variant*.

| OTA file | Use |
|---|---|
| `collar-ota-first-flash*.hex` | first flash over SWD (MCUboot + firmware) |
| `collar-ota-update*.bin` | the update the app downloads by itself |
| `collar-ota-update*.zip` | the same update for nRF Connect Device Manager |

## For maintainers: making a release

Tag a commit and push the tag; CI builds every firmware, runs all tests, and publishes the
files to a new (pre-)release with this page as the notes:

```bash
git tag v0.1.0 && git push origin v0.1.0
```

To sign OTA images with the project's own key instead of the development key, store the PEM
(made with `imgtool.py keygen -t ecdsa-p256`) as the repository secret `MCUBOOT_SIGNING_KEY`
and keep an offline backup: without it, collars already flashed cannot accept new updates.
