# ADR 0007: Data sync: home Wi-Fi base station + phone over BLE

- **Status:** accepted
- **Date:** 2026-11-16
- **Affects:** architecture (section 2), Phases 3–4, bill of materials

## Context

The collar has no internet connection. Data must reach the backend without hurting the
battery, and the owner wants it to arrive **automatically**, without having to open the
app. Phone-only sync has two limits:
- data only moves when the phone is near the collar **and** the app gets a chance to run;
- on iOS, background BLE is heavily restricted, so in practice sync happens when the app
  is opened.

## Decision

Two sync paths, both using the **same BLE sync protocol** ("send everything since minute
X", contract 4.7 records):

1. **Home base station (primary):** an ESP32 board on a wall plug (e.g. Seeed XIAO
   ESP32-C3) connects to the collar over BLE whenever it is in range, pulls the new
   records and uploads them over **Wi-Fi** (HTTPS) to `POST /ingest`. Data arrives on its
   own throughout the day.
2. **Phone app over BLE (fallback):** outside home (walks, trips) the app syncs the same
   way and uploads over the phone's connection.

Both can upload the same minutes: ingestion is already idempotent
(`ON CONFLICT (device_id, minute_ts) DO NOTHING`), so duplicates are harmless. The collar
keeps days of records in flash, so nothing is lost while out of range.

```
collar ──BLE──▶ base station (ESP32, wall plug) ──Wi-Fi──▶ backend
   └────BLE──▶ phone app (fallback, away from home) ──4G──▶ backend
```

## Alternatives

- **Phone only:** simplest, but not automatic, especially on iOS.
- **Wi-Fi on the collar itself (option A), kept on record as a future possibility:**
  - would need an ESP32 (alone or next to the nRF52840), since the nRF52840 has no Wi-Fi;
  - an ESP32 draws roughly 5–10× more than the nRF52840 to run inference every second,
    which turns the "weeks of battery" goal into days (to be confirmed by measurement if
    ever prototyped);
  - a Wi-Fi burst upload every hour could be affordable on its own (a few mAh/day), so a
    dual-chip design (nRF52840 for sensing/ML, ESP32 woken only to upload) is the variant
    worth revisiting;
  - it only works within Wi-Fi range, so walks would still need BLE;
  - revisit if the base station proves unreliable or if a product needs collar-direct cloud sync.

## Consequences

- One more component (`basestation/`, ESP32 firmware) after Phase 3, when the collar
  already stores summaries. It needs Wi-Fi provisioning (set up from the app over BLE) and
  a per-device credential to call the API.
- The collar's BLE sync service must handle two kinds of clients (base station and phone),
  with the base station preferred when both are present.
- The backend tracks which path delivered each batch (useful for debugging gaps).
