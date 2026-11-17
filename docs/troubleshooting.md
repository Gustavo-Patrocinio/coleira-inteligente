# Troubleshooting

Find the symptom, try the fixes in order. If nothing works, open an issue on GitHub with:
what you did, what you saw (a screenshot helps), your phone model and OS, and the collar
firmware version (Collar tab → Collar firmware → Check for updates).

> **Safety first.** A collar that gets **hot**, smells sweet, or has a **swollen** battery:
> take it off the dog now, unplug it, put it on a non-flammable surface outdoors and do not
> charge it again. The battery goes to recycling (build guide, battery rules).

## The collar

| Symptom | Try |
|---|---|
| Nothing happens when plugged in, no charge LED | Another USB-C cable (some only charge, some are broken) and another charger; check the battery joints (build guide step 4) |
| Charge LED never goes off | Normal for the first ~5 h on a 250 mAh cell. Much longer: the battery may be damaged, stop charging |
| Battery lasts much less than a day | Expected for now: the prototype runs the model all the time (Phase 5 brings weeks). A sudden drop compared with earlier days: the cell may be failing |
| No `XIAO-SENSE` drive for flashing | Double-tap the reset button faster; data cable; another USB port (flashing guide) |
| Collar flashed, but the app never finds it | You may have flashed the logger: flash `collar.uf2` again |

## Pairing and syncing

| Symptom | Try |
|---|---|
| "Pair collar" finds nothing | Bluetooth on; the app has Bluetooth permission (phone settings → apps → Collar); phone within 1 m; unplug/replug the collar to restart it; on Android, location services on (older Android versions need it to scan) |
| Found, but pairing fails | Check the phone has internet (pairing registers the collar on the server); sign out and in; try again |
| "Sync now" fails | Phone within 1–2 m, nothing metal between; close other apps using Bluetooth (fitness bands' apps can hold the connection); try again. The collar keeps ~13 days, nothing is lost by waiting |
| Synced, but the minutes do not show | Pull down on Today to refresh. "Offline" card: the phone has the minutes but could not reach the server; they upload on the next sync with internet |
| A day shows big gaps | The collar was out of the phone's range and the app was not opened for > 13 days, or it was off/charging. With the home base station (Phase 4) gaps get rare |
| Times look shifted by hours | The dog's time zone (set when the dog was created). Days and nights use the dog's local time |

## Firmware updates

| Symptom | Try |
|---|---|
| "This collar has the USB-only firmware" | The wireless-update version must be flashed once with an SWD probe (`firmware/app/README.md`, *OTA variant*). Until then, update by USB (flashing guide) |
| Update stops halfway / "stopped answering" | Phone right next to the collar, screen on, app open; try again. The collar keeps the old firmware until a complete, verified upload |
| "The collar refused the request" | The image is for another key or board: OTA images must be signed with the same key as the collar's bootloader (`-devkey` files only work on collars flashed with the development key) |
| After an update the version did not change | The new version did not pass its start-up check and the collar went back to the previous one. Report it with the version numbers |

## Behavior and alerts

| Symptom | Try |
|---|---|
| Recognition looks wrong (e.g. walking while asleep) | Check the collar sits **under the neck, arrow to the head**, two fingers loose (build guide step 8). A loose or rotated collar confuses the model. Recording sessions with "Help improve recognition" is the long-term fix |
| No alerts at all | Alerts need ≥ 14 complete days (≥ 20 h of data each) to learn what is normal. Days with gaps are skipped |
| An alert that makes no sense | Tap "False alarm": it is recorded and used to tune the rules. Alerts are never a diagnosis; when in doubt, talk to your vet |
| Sleep numbers look off | Sleep is **estimated from movement**: a dog lying awake and still counts as resting. Useful for trends over days, not minute by minute |

## The dog

| Symptom | Try |
|---|---|
| Red skin, hair loss or sores under the device | Stop using it until healed. Then loosen the fit, sand sharp edges of the case, try a softer collar or TPU case; check daily in the first week |
| The dog scratches or paws at the collar | Normal for the first days: short periods only (adaptation, `docs/protocols/collection.md`). If it continues after a week, stop |
| The device swings or rotates | Collar too loose, or the case too wide for the collar: print the base for your collar width |

## The server (if you run your own)

| Symptom | Try |
|---|---|
| The app says it cannot reach the server | `docker compose ps` on the server; `curl https://<domain>/health`; the address in the app's sign-in screen has `https://` |
| HTTPS certificate errors | The domain's DNS must point to the server and ports 80/443 must be open, so Caddy can get the certificate (`backend/DEPLOY.md`) |
| "Too many attempts" when signing in | The rate limit (20 per 15 min per IP). Wait 15 minutes |
| Restore after a failure | `backend/DEPLOY.md`, *Backups* |
