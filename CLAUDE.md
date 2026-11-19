# CLAUDE.md: Smart Dog Collar with Embedded AI

> Project context for Claude Code. Read before any task in this repository.
> **Language:** everything in the repository (code, comments, docs, ADRs, UI, commits) is
> in **English**. Talk to the user in **Portuguese (BR)** in chat.

---

## 1. Overview

A dog collar with a motion sensor (IMU) and a microcontroller that **recognizes the dog's
behavior on the chip itself (TinyML)**: still, walking, running, scratching, shaking,
eating and drinking. The collar stores per-minute summaries and syncs them over BLE to a
home base station (Wi-Fi) or to the phone app, which send them to a backend. The backend
learns each dog's normal pattern and raises alerts ("scratched 3× more than usual",
"activity 40% below normal").

**Goal:** an **open project anyone can build and use with any dog**, done right like a
product, not a college prototype; selling it as a ready-made product is a later goal
(ADR 0009). Every decision is measured and documented.

**Principles:**
1. **Measure, don't guess:** accuracy with honest splits, power measured with a current
   meter, battery life measured in the field.
2. **Every phase ends with something working** and an objective done criterion.
3. **Document decisions** in `docs/decisions/` (short ADR: context, decision, alternatives,
   consequences).
4. **Animal welfare above all:** weight, comfort, skin irritation, and never forcing
   behavior to collect data.
5. **Works for any dog:** data from many dogs, evaluation on unseen dogs, hardware and app
   that a non-technical owner can set up (ADR 0009).

---

## 2. Architecture

```
┌──────────────────────── COLLAR ─────────────────────────┐
│ IMU (LSM6DSOX, built-in MLC)                             │
│   ├─ level 1: decision tree in the IMU → still/moving    │
│   └─ FIFO + interrupt → wakes the MCU                    │
│ nRF52840 (Zephyr)                                        │
│   ├─ level 2: int8 1D CNN (TFLite Micro) → fine classes  │
│   ├─ temporal smoothing → per-minute summary → flash     │
│   └─ BLE: batch sync, raw dump, OTA (MCUboot)            │
└──────────────┬──────────────────────────┬────────────────┘
               │ BLE (at home)            │ BLE (away)
┌──────────────┴─────────────┐ ┌──────────┴───────────────────┐
│ BASE STATION (ESP32)       │ │ APP (Flutter)                │
│ wall plug, auto sync       │ │ collection (video + raw),    │
│ ADR 0007                   │ │ fallback sync, screens       │
└──────────────┬─────────────┘ └──────────┬───────────────────┘
               │ Wi-Fi / HTTPS            │ HTTPS
┌──────────────┴──────────────────────────┴────────────────┐
│ BACKEND: TypeScript API (Fastify + Zod) →                │
│ Postgres + TimescaleDB; jobs: per-dog baseline,          │
│ anomaly detection, push                                  │
└───────────────────────────────────────────────────────────┘
```

---

## 3. Repository layout (monorepo)

```
coleira-inteligente/
├── CLAUDE.md
├── README.md                 # showcase: results, photos, charts, decisions
├── ml/                       # Python: data, training, evaluation, quantization
│   ├── data/                 # NOT versioned (.gitignore)
│   │   ├── public/           # public dataset
│   │   ├── raw/              # collected sessions (csv + video)
│   │   └── labels/           # exported labels
│   ├── notebooks/            # exploration (numbered: 01_explore.ipynb...)
│   ├── scripts/              # reproducible entry points (download, train, synth data)
│   ├── src/coleira_ml/       # reusable code (windows, features, models)
│   ├── models/               # exported artifacts (.tflite, .h)
│   └── tests/
├── firmware/                 # Zephyr / nRF Connect SDK
│   ├── app/                  # main application
│   ├── logger/               # collection firmware (Phase 1)
│   ├── boards/               # overlays (XIAO, later the custom PCB)
│   └── west.yml              # pinned SDK version
├── basestation/              # ESP32 home base station (ADR 0007)
├── app/                      # Flutter
├── backend/                  # TypeScript (Fastify)
│   ├── src/
│   ├── migrations/           # plain SQL (hypertables, continuous aggregates)
│   └── tests/
├── tools/
│   └── labeler/              # web labeling tool (HTML/JS + uPlot)
├── hardware/
│   ├── cad/                  # enclosure (sources + STL/STEP)
│   └── pcb/                  # KiCad (Phase 7)
└── docs/
    ├── decisions/            # ADRs
    ├── product/              # owner-facing indicators and screens
    ├── energy-budget.md      # measured power budget
    ├── public-dataset.md     # public dataset analysis
    ├── results.md            # accuracy per phase, confusion matrices
    └── protocols/            # collection and labeling protocols
```

---

## 4. Contracts (do not change without an ADR)

### 4.1 Classes (stable IDs; names: ADR 0008)

| ID | Class | Phase it enters |
|----|-------|-----------------|
| 0 | `still` (lying, sitting, standing, sleeping, stationary sniffing; ADR 0004) | 0 |
| 1 | `walking` (includes sniffing while walking) | 0 |
| 2 | `running` (trot and gallop) | 0 |
| 3 | `scratching` | 1–2 |
| 4 | `shaking` | 1–2 |
| 5 | `eating` | 6 |
| 6 | `drinking` | 6 |
| 255 | `unknown` / transition | — |

IDs are **never** reused or reordered. A new class gets a new ID.

### 4.2 IMU sampling
- 50 Hz, accelerometer ±16 g (ADR 0005: shaking exceeds 8 g) and gyroscope ±2000 dps (chip
  maximum; saturates during part of the shaking, accepted).
- Mounting: under the neck, always in the same physical orientation (marked on the case).

### 4.3 Model window
- 2 s = 100 samples, 50% overlap (1 s step).
- Input: 7 channels = ax, ay, az, gx, gy, gz and accelerometer magnitude.
- Output: per-class probabilities.
- Smoothing (ADR 0002):
  - state classes (0, 1, 2, 5, 6): majority over the last 5 windows;
  - event classes (3, 4): event confirmed when prob. ≥ `p_event` in ≥ `n_min` consecutive
    windows (calibrated in Phase 2); events override the state.
- Training window label: class with ≥ 70% of the samples; for 3 and 4, ≥ 50% or ≥ 1 s
  contiguous is enough. Otherwise the window is dropped or labeled 255.

### 4.4 Raw BLE data packet (Phase 1), little-endian

| Offset | Type | Field |
|--------|------|-------|
| 0 | uint8 | `version` (=1) |
| 1 | uint8 | `type` (0x01 = raw) |
| 2 | uint16 | `seq` (packet counter, wraps around) |
| 4 | uint32 | `device_ms` (uptime of the 1st sample) |
| 8 | int16 × 6 × N | samples (ax, ay, az, gx, gy, gz), N = 10 |

Size: 8 + 120 = 128 bytes → requires MTU ≥ 131.

GATT (ADR 0010): service `c01a0000-7e3b-4c5e-9d2a-5f1e8b6a2c10`, notify characteristic
`c01a0001-7e3b-4c5e-9d2a-5f1e8b6a2c10`, advertised name `Collar-Logger`. Sampling: IMU at
104 Hz read by a 20 ms MCU timer (≈ 50.03 Hz on the MCU crystal).
The collar firmware serves the same service as raw dump mode, streaming while a client is
subscribed (ADR 0014).

The app stores each packet with its receive `phone_ts`. Inside a packet, sample i's time =
`device_ms` + i × 20 ms. Across packets an exact ODR is **not** assumed: the real rate is
estimated by regression on `device_ms`, and video alignment uses taps at the start and at
the end with a linear correction (ADR 0003).

### 4.5 Raw session CSV (`ml/data/raw/<session_id>/imu.csv`)
`phone_ts_ms, device_ms, seq, ax, ay, az, gx, gy, gz` (raw int16 values; the scale lives in
`meta.json`)

`meta.json`: `session_id, dog_id, device_id, start_phone_ts, video_file,
video_start_phone_ts_ms, accel_range, gyro_range, odr_hz, location, surface, notes,
sync_taps`

`sync_taps` = `{start_video_ms, end_video_ms, start_device_ms, end_device_ms}`, filled in by
the labeler after alignment (ADR 0003).

### 4.6 Label CSV (`ml/data/labels/<session_id>.csv`)
`start_ms, end_ms, class_id, annotator, confidence` (time relative to the start of the video)

### 4.7 Per-minute summary (flash → BLE → backend)
Little-endian, v1 (ADR 0001):

| Offset | Type | Field |
|--------|------|-------|
| 0 | uint8 | `version` (=1) |
| 1 | uint32 | `minute_ts` (epoch s, UTC) |
| 5 | uint8 × 7 | `seconds_per_class[0..6]` |
| 12 | uint8 | `unknown_s` |
| 13 | uint8 | `battery_pct` |
| 14 | uint8 | `flags` |

= 15 bytes/min, ~21 KB/day. Invariant: `sum(seconds_per_class) + unknown_s ≤ 60`. A new
class or field → new `version`. `flags` bit 0 = battery not measured; other bits 0 (ADR 0013).

### 4.8 Summary sync GATT service (ADR 0013)

Service `c01a0100-7e3b-4c5e-9d2a-5f1e8b6a2c10`; characteristics `…0101` Time (write
`uint32 epoch_s`), `…0102` Control (write `0x01 + uint32 since_minute_ts`, or `0x02` status),
`…0103` Data (notify, k × 15-byte records), `…0104` Status (read/notify, 16 bytes: kind,
clock_set, battery_pct, reserved, uint32 count, uint32 oldest, uint32 newest). Sequence:
write Time → subscribe → Control `0x01, X` → records → Status `0x81`.

---

## 5. Stack and conventions

| Part | Stack | Conventions |
|------|-------|-------------|
| ML | Python 3.12, `uv`, numpy, pandas, scipy, scikit-learn, Keras 3/TensorFlow (ADR 0006), TFLite (int8 conversion) | `ruff` + `pytest`; notebooks only explore, logic lives in `src/` |
| Firmware | Zephyr via nRF Connect SDK (version pinned in `west.yml`), C, TFLite Micro, MCUboot | Kconfig in `prj.conf`; zero `printk` in release; power measured after every relevant change |
| Base station | ESP32 (Zephyr or ESP-IDF, decided when it starts), BLE central + Wi-Fi | Same BLE sync protocol as the app; per-device API credential |
| App | Flutter, `flutter_blue_plus`, `camera` | BLE logic isolated in a testable service |
| Backend | Node + TypeScript, Fastify, Zod, `pg`/Kysely, Postgres 16 + TimescaleDB | Plain SQL migrations; idempotent ingestion (`ON CONFLICT DO NOTHING`) |
| Labeler | Plain HTML + JS, uPlot | No build step; opens directly in the browser; logic tested with `node --test` |
| Hardware | CAD (enclosure), KiCad (PCB) | Export STEP + STL for every version |

**Commits:** Conventional Commits (`feat(firmware): ...`, `fix(ml): ...`).

---

## 6. Rules for Claude

1. **Never** version `ml/data/`, videos or large models. Check `.gitignore`.
2. **Train/test splits always by group** (dog in the public dataset; session/day in our own
   data). Random splits by window are forbidden, because they inflate accuracy.
3. Do not change the section 4 contracts without an ADR.
4. All firmware from Phase 3 onward keeps **OTA working**; a change that breaks updates is
   blocking.
5. When reporting model results, always show: balanced accuracy, per-class F1, confusion
   matrix, size (KB) and inference RAM. From now on, also report a **cross-population** test
   (train on one dataset, test on another) when more than one dataset is available.
6. Power consumption is only claimed with a measurement (PPK2) and recorded in
   `docs/energy-budget.md`.
7. Prefer simple solutions and explain why; the project is also a learning project.
8. When a phase task is done, update the checklist below.
9. Repository content in English; chat with the user in Portuguese (BR).

---

## 7. Plan by phase

### Phase 0: ML pipeline on a public dataset (no hardware)
**Goal:** prove the complete pipeline and get a first model.

- [x] Set up `ml/` with `uv`, ruff and pytest
- [x] Download the public dataset (`ml/scripts/download_public.py`; summary in `docs/public-dataset.md`): Kumpulainen et al. (2021), *"Dog behaviour classification with movement sensors placed on the harness and the collar"* (Mendeley Data). Check the exact class list and sampling rate in its README. If it has shaking/eating/drinking/sniffing labels, keep the mapping to pre-train classes 3–6 later
- [x] Use **only the collar sensor** (`coleira_ml.public_dataset.load_collar`)
- [x] Notebook `01_explore`: plot stretches of each behavior
- [x] Resample to 50 Hz; map the dataset classes to IDs 0–2 (also 4–6, which the dataset has; saturation at ±16 g/±2000 dps, ADR 0005)
- [x] Windowing (2 s, 50%); window label by the section 4.3 rule (≥ 70%; special rule for short events)
- [x] Augmentation: random 3D axis rotation, small noise and scale variation
- [x] `GroupKFold` by dog
- [x] Baseline: features (mean, std, min, max, energy, dominant FFT frequency, magnitude) + **shallow** Random Forest → balanced accuracy 0.956 (see `docs/results.md`)
- [x] MLC-compatible variant: shallow tree using only features ST's MLC computes (mean, variance, energy, peak-to-peak, zero-crossings, min/max, filters; **no FFT**). This is the one that goes into the IMU in Phase 5 (still × moving: 0.986 with 29 nodes; still needs retraining with rotation)
- [x] Small 1D CNN (e.g. 3× [Conv1D k=5 → ReLU → MaxPool], 16/32/32 filters → GAP → Dense), in Keras (ADR 0006)
- [x] Quantize to int8; compare float vs int8 accuracy (no loss: 0.957 × 0.957)
- [x] `docs/results.md`: table model × balanced accuracy × F1 × KB

**Done when:** int8 CNN with balanced accuracy ≥ 85% on 3 classes, on unseen dogs, under 64 KB.

✅ **Completed 2026-11-16:** int8 CNN with 0.957 balanced accuracy (GroupKFold 5× by dog), 18.8 KB, robust to collar rotation.

---

### Phase 1: collection and labeling with real dogs
**Goal:** 2–3 h of our own data synced with video, including scratching and shaking, from
the author's dog **and at least 4 other dogs** of different sizes (ADR 0009).

**Hardware:**
- [ ] Seeed XIAO nRF52840 Sense (6-axis IMU + microphone + charger on board). Its IMU is an LSM6DS3TR-C, **without MLC**. The MLC only arrives with the IMU swap in Phase 5
- [ ] SWD probe (Raspberry Pi Pico H as debugprobe, or J-Link EDU Mini): Zephyr debugging and, in Phase 3, flashing MCUboot over the factory UF2 bootloader
- [ ] 3.7 V ~250 mAh LiPo with protection (PCM), soldered to the BAT+/BAT− pads under the XIAO (the board has no JST connector)
- [x] Provisional 3D-printed case, with the orientation marked: `hardware/cad` (build123d, STEP + STL, 3 collar widths, fit-checked in code; not printed yet); assembly in `docs/build-guide.md`

**Firmware `firmware/logger/`** (code written 2026-11-16 before the hardware arrived, ADR 0010; builds with NCS v2.9.0 with 0 warnings, not run on a board yet; see its README status list. PC recorder: `ml/scripts/record_ble.py`):
- [ ] Read the IMU at 50 Hz (Zephyr driver; check the board's exact IMU model)
- [ ] Custom GATT service, notify characteristic, section 4.4 packet
- [ ] MTU ≥ 131 negotiation (+ Data Length Extension); `seq` counter to detect loss
- [ ] Plan B: if Zephyr blocks progress for more than 1 weekend, write the logger in Arduino (Seeed core + ArduinoBLE) keeping the same packet format

**Collection app (`app/`, collection mode; Flutter for iOS + Android, BLE via universal_ble, ADR 0012; written and unit/widget-tested 2026-11-17, not yet run with the collar):**
- [x] Connect to the collar, film and write the CSV at the same time (section 4.5) (code + recorder tests)
- [x] Generate the session `meta.json` (including `video_start_phone_ts_ms`)
- [x] Export the session (share sheet; iOS Files app access enabled)
- [ ] Verified on a real phone with the collar logger

**Protocol (`docs/protocols/collection.md`, written 2026-11-16, with `labeling.md` and `consent-template.md`; items below are done when practiced in real sessions):**
- [ ] Adaptation: a few days wearing the collar without recording; check the skin
- [ ] Sync: 3 taps on the case in front of the camera at the **start and end** of each session (ADR 0003)
- [ ] 10–20 min sessions: sleeping, leash walk, play, kibble, water
- [ ] Long sessions to capture spontaneous behaviors (scratching); record after a bath (shaking)
- [ ] Vary days, times and floors
- [ ] Record 2–3 **nights** with a night-vision camera: ground truth for asleep × lying awake and breath counting (see `docs/product/indicators.md`, *Sleep*)
- [ ] Battery and water safety rules (charge off the dog, discard swollen cells, no immersion until the sealed case)
- [ ] Other dogs: ≥ 4 besides the author's, covering small / medium / large; a short written consent from each owner (what is recorded, how it is used, right to delete); `dog_id` + size/breed/weight in `meta.json` notes

**Labeling tool `tools/labeler/`:**
- [x] Load video + CSV; uPlot chart with cursor synced to the video
- [x] Alignment using start and end taps (offset + linear drift correction); write `sync_taps` to `meta.json`
- [x] Keyboard shortcuts to mark start/end per class
- [x] Export in the section 4.6 format
- (tested with a synthetic session via `ml/scripts/make_synthetic_session.py`; still to validate with a real session)

**Wrap-up:**
- [ ] Run the Phase 0 model on our own data and record the drop (domain gap) in `docs/results.md` (script ready: `ml/scripts/eval_domain_gap.py`; `own_data_report.py` checks the done criterion below; loader `coleira_ml.own_sessions` uses the labeler's timing)

**Done when:** ≥ 2 h labeled from ≥ 5 dogs, ≥ 3 min accumulated for each class 0–4, packet loss < 1%.

---

### Phase 2: model running on the chip (still on USB)
**Goal:** live classification inside the nRF matching the video.

- [ ] Fine-tuning: pre-train on public data + adapt on our own data (classes 0–4)
- [ ] Evaluation split by dog (leave-one-dog-out) and by session/day
  (both: `ml/scripts/finetune_lodo.py`, smoke-tested on public dogs posing as ours; waits for real sessions)
- [x] Export int8 `.tflite` → C array (`ml/scripts/export_model.py` → `firmware/app/src/model/`, with generated config and op list)
- [x] `firmware/app/`: integrate TFLite Micro (+ CMSIS-NN); 16 KB tensor arena (builds 0 warnings: 172 KB flash, 49 KB RAM)
- [ ] Measure inference time and RAM used **on the board** (printed by the app)
- [x] Smoothing per section 4.3: majority for states, event detection for 3–4; host-tested with synthetic sequences (`ml/tests/test_firmware_host.py`, C via zig cc)
- [ ] Calibrate `p_event`/`n_min` on a validation session (`ml/scripts/calibrate_events.py`: replays the firmware smoothing, a Python port checked against `smoothing.c`, on out-of-fold LODO probabilities)
- [x] Firmware preprocessing = training preprocessing (host test; same class on ≥ 99% of real windows)
- [ ] Live test: class printed on serial vs video, on a new session

**Done when:** F1 ≥ 0.85 on classes 0–2 and ≥ 0.70 on scratching/shaking on a never-seen session **and on never-seen dogs**; inference < 50 ms.

---

### Phase 3: wireless autonomy
**Goal:** a whole day recorded on battery alone.

- [ ] MCUboot + BLE DFU (OTA) working **before** everything else (flash MCUboot via SWD, since the XIAO ships with Adafruit's UF2 bootloader). Built 2026-11-17 as the `firmware/app/ota/` variant (ADR 0015: update slot in the 2 MB QSPI flash, self-confirm after a health check, signed images); the app updates the collar from the newest GitHub release (Dart SMP client); not run on a board yet
- [x] Per-minute summary (section 4.7) written to flash: FCB on a 416 KB partition, ~13 days (ADR 0013; `firmware/app`, builds, not run on a board yet)
- [x] BLE sync service: the client asks "since minute X" and receives the batch (contract 4.8; PC client `ml/scripts/sync_ble.py` emulates the base station and uploads)
- [x] Raw dump mode, enabled from the app (to keep collecting dataset): the collar firmware serves the logger's raw service while subscribed; the app's collection mode finds either firmware (ADR 0014; builds, not run on a board yet)
- [x] Clock: the client sends the current time on connect; the collar keeps it (2 h RAM buffer stamped retroactively)
- [x] App side of the sync: pair the collar (registers the device, keeps its token), "Sync now" fetches since X and uploads via `api.ingest` (tested with a fake collar; caught a status-before-data race)
- [x] App: daily routine screen (timeline per class + Exercise, Sleep and Skin indicators; see `docs/product/indicators.md`); sync on open and on return to the foreground (throttled); offline day from records kept on the phone
- [ ] First power measurement with PPK2 → `docs/energy-budget.md`

**Done when:** 24 h in a row recorded wirelessly, sync with no loss or duplicates, OTA tested.

---

### Phase 4: backend, alerts and home base station
**Goal:** the system learns what is normal for each dog, warns when it drifts, and data
arrives on its own.

- [x] Postgres + TimescaleDB via Docker Compose (`backend/`, 2026-11-17)
- [x] Tables: `users`, `dogs`, `devices`, `activity_minute` (hypertable), `alerts`, plus `daily_metrics`
- [x] Continuous aggregate per hour (`activity_hourly`); daily metrics computed in local time by the job
- [x] Fastify + Zod API: auth (JWT), dogs/devices, **idempotent** batch `POST /v1/ingest` (key `device_id + minute_ts`), recording which path delivered each batch (base station or app)
- [x] Query endpoints: daily routine (15-min blocks), trends; sleep estimated from movement (`GET /v1/dogs/:id/sleep/:day`: bedtime, wake time, rest, awakenings, longest stretch, naps; `src/sleep.ts`); shown on the app's Today card
- [x] Baseline job: daily totals vs **median + MAD** of the previous 28 days, same day type (ADR 0011, replaces the per-hour baseline for alerts)
- [x] Alerts by robust z-score (|z| > 3) for total activity, scratching time and night wake-ups; ≥ 14 complete days of history; incomplete days skipped
- [x] "Made sense / false alarm" feedback on each alert
- [ ] Push via Firebase Cloud Messaging (code done 2026-11-17: `backend/src/push.ts` sends one notification per new alert over the FCM HTTP v1 API when `FCM_SERVICE_ACCOUNT_FILE` is set; the app registers its token after consent and removes it on sign-out; waits for a Firebase project and a real phone; iOS needs a paid Apple account)
- [x] Tests: duplicate ingestion, sync gaps, time zones, accounts (33 tests, integration against a real TimescaleDB)
- [x] App: trends and alerts screens (with feedback), backed by the API; push notifications (code done, see above)
- [ ] **Base station (`basestation/`, ADR 0007):** ESP32 (e.g. XIAO ESP32-C3) as BLE central that pulls new summaries from the collar and uploads them over Wi-Fi to `/ingest`; Wi-Fi provisioning from the app over BLE; per-device credential; collar prefers the base station when both clients are present
- [ ] Phone keeps working as fallback sync away from home
- [x] Several dogs and several collars per account (profiles with sex, neutering, breed, birth date, weight; a collar moved between dogs keeps the old dog's history; app Profile tab and dog switcher, 2026-11-17); privacy (LGPD): export (`GET /v1/me/export`) and deletion (`DELETE /v1/me`); consent screen in the app, recorded on the server with its version (`PUT /v1/me/consent`, separate research opt-in); export/delete buttons in the app; per-IP rate limit on login/register; accounts: password reset by a 6-digit email code (SMTP, any provider; the server answers 501 without one), changing or resetting the password signs out other phones (`users.token_version`), app *Forgot password?* and readable errors (2026-11-19)
- [x] Self-hostable with Docker Compose: `backend/DEPLOY.md` (Caddy HTTPS, nightly backups, restore tested locally; encrypted off-site copies to S3-compatible storage, tested against a local S3 server); Oracle Cloud free ARM VM guide and setup script (`backend/DEPLOY-ORACLE.md`); running on an OCI VM since 2026-11-18 (sslip.io address; `smoke-test.sh` passes; encrypted off-site copies in OCI Object Storage; `restore-check.sh` restored the newest one, after it caught an empty first dump, now fixed); [ ] SMTP provider set up on it; [ ] one shared instance open to beta users
- [x] Upkeep: CI fails on high/critical `npm audit` findings, Dependabot weekly PRs, *Uptime* workflow every 30 min (needs the `HEALTH_URL` repository variable), `/health` checks the database (2026-11-19; dependencies upgraded past critical fast-jwt/fastify issues and redeployed)

**Done when:** a real alert fires correctly with your dog's data; repeated ingestion does
not duplicate; with the base station on, data reaches the backend within minutes of the
dog coming home, without opening the app.

---

### Phase 5: real energy (two-level classification)
**Goal:** weeks of battery life.

- [ ] Switch to an IMU with a Machine Learning Core (LSM6DSOX or LSM6DSV16X) on a breakout
- [ ] Train a shallow "still vs moving" tree with MLC-supported features; generate the configuration (ST tools)
- [ ] MCU in deep sleep; wakes on the MLC interrupt
- [ ] While still, the MCU does not even run the CNN: it only accounts `still` time
- [ ] Batch the IMU FIFO to reduce wake-ups
- [ ] Tune BLE advertising/connection intervals
- [ ] Fuel gauge (MAX17048) → real battery in the app
- [ ] Measure each mode with PPK2: sleep, active, inference, sync
- [ ] (Experimental) sleeping respiratory rate: sparse 1-min sampling every 30 min while asleep; validate against Phase 1 night videos. Public-dataset check: panting clearly visible, calm breathing inconclusive (`docs/results/breathing_feasibility.md`); try gyro and a ±2 g range during sleep sampling

**Targets (to validate by measurement):**

| Mode | Target average current |
|------|------------------------|
| Still (MLC + sleep only) | < 50 µA |
| Moving (CNN active) | < 1 mA |
| Daily average | < 200 µA → weeks on ~250 mAh |

**Done when:** battery life measured in the field ≥ 14 days.

---

### Phase 6: open release + beta (path A, ADR 0009)
**Goal:** anyone can build it from the docs and use it with their dog every day.

- [ ] DIY enclosure: 3D-printable, sealed (O-ring), outer TPU layer against impact and bites, **universal clip** for collars of any width; STEP + STL published
- [ ] Weight < 3% of the dog's weight for the smallest supported size; center of mass under the neck
- [ ] Build guide with photos: parts list with links and prices, soldering, assembly, fit check (text version: `docs/build-guide.md`; photos after the first build)
- [ ] Prebuilt firmware releases (collar + base station) and a flashing guide for non-developers (collar done 2026-11-17: pushing a `v*` tag makes CI publish UF2 + OTA files with checksums; guide `docs/flashing.md`; base station pending)
- [ ] App published (Android + iOS): onboarding that pairs the collar, creates the dog profile and provisions the base-station Wi-Fi, without help (onboarding written 2026-11-17: consent → dog → pair collar; Wi-Fi provisioning waits for the base station)
- [ ] Model trained on 10–20+ dogs (Phase 1 + opt-in sessions from users), evaluated leave-one-dog-out
- [ ] (Optional) audio fusion for `eating`/`drinking` (classes 5–6), turning the microphone on only when the IMU indicates head down + light movement
- [ ] Beta: 10–20 owners outside the project use it for 1 month; collect issues and alert feedback
- [ ] Troubleshooting guide and privacy policy; app copy never makes medical claims (written 2026-11-17: `docs/troubleshooting.md`, `docs/privacy-policy.md` as a template for each server operator; the app now clears its local minutes on sign-out; review after the beta)
- [ ] README: photos, demo video, accuracy and energy charts, decisions

**Done when:** ≥ 10 beta owners used it for 1 month, at least 3 collars were built by
other people from the docs alone, and accuracy on beta dogs is reported.

---

### Phase 7: product (path B, later goal)
**Goal:** a ready-made device that can be sold.

- [ ] Custom KiCad PCB: nRF52840 module + IMU with MLC + charger + fuel gauge + antenna per the module reference. Prefer a module **already certified by Anatel**: it barely changes the cost and greatly simplifies product certification in Brazil
- [ ] Magnetic pogo-pin charging (no exposed USB)
- [ ] Production enclosure (injection molding or SLA at volume), IP67 tested
- [ ] Cost model per unit (BOM, assembly, enclosure, packaging) and hosting cost per user
- [ ] Certification: Anatel (collar and base station), battery safety
- [ ] Company, support channel, warranty

**Done when:** a sealed collar running day to day for 1 month without intervention, built
from the production design, with a cost per unit that allows selling it.

---

## 8. Bill of materials (prototype)

| Item | Phase | Note |
|------|-------|------|
| Seeed XIAO nRF52840 Sense | 1 | Main prototype (ordered) |
| SWD probe (Raspberry Pi Pico H as debugprobe) | 1 | Debugging; required to flash MCUboot (Phase 3) (ordered) |
| 3.7 V 150–300 mAh LiPo with PCM | 1 | Soldered to BAT+/BAT− (XIAO has no JST); check polarity with a multimeter |
| PETG + TPU filament | 1/6 | Case |
| Nordic Power Profiler Kit II (PPK2) | 3 | Essential to measure power |
| Seeed XIAO ESP32-C3 (or similar ESP32) | 4 | Home base station (ADR 0007) |
| LSM6DSOX or LSM6DSV16X breakout | 5 | Machine Learning Core |
| MAX17048 breakout | 5 | Fuel gauge |
| Second XIAO nRF52840 Sense | 1 | Collect from other dogs in parallel / spare |
| O-ring | 6 | Size it in CAD |
| Magnetic pogo pins (2 or 4 pins) | 7 | Sealed charging |

---

## 9. Risks and mitigation

| Risk | Mitigation |
|------|------------|
| Tiring labeling → project stalls | Own tool with shortcuts; short sessions; public dataset covers the basics |
| Accuracy inflated by a wrong split | Rule 2 in section 6, no exceptions |
| Collar rotates on the neck | Rotation augmentation + magnitude channel + case weighted at the bottom |
| Rare classes with few examples | Continuous collection with dump mode; class weights; accept lower F1 at first |
| Short events (shaking) vanish in smoothing | Per-class smoothing with event detection (ADR 0002) |
| Clock drift misaligns IMU and video | Taps at start and end + linear correction (ADR 0003) |
| Steep Zephyr learning curve | Arduino plan B for the logger only; official Nordic samples as a base |
| BLE in the background on iOS | Home base station syncs on its own (ADR 0007); sync on app open; days of buffer in flash |
| Water/bites | Sealed DIY case in Phase 6; until then, supervised use |
| Model only works for the author's dog | Data from ≥ 5 dogs in Phase 1 and 10–20+ by Phase 6; leave-one-dog-out evaluation (ADR 0009) |
| Others cannot build or set it up | Build and flashing guides, prebuilt firmware, app onboarding; at least 3 external builds before Phase 6 is done |
| Medical-claim or privacy issues with other users | "Talk to your vet" framing, no diagnosis; LGPD consent, export and deletion |
| Dog discomfort | Gradual adaptation, minimal weight, check the skin, stop if there is discomfort |

---

## 10. Current status

- **Current phase:** 1 (Phase 0 completed 2026-11-16)
- **Goal:** open project for any dog first, product later (ADR 0009)
- **Next task:** when the XIAO arrives: flash `firmware/logger` and `firmware/app` (both build; NCS v2.9.0 in `C:\ncs`, tflite-micro in `C:\ncs\extra`), verify with `ml/scripts/record_ble.py`, the phone app's collection mode (install on the iPhone from the MacBook, `app/BUILD_MAC.md`, pointing at the deployed server) and the firmware serial log. Meanwhile (owner): SMTP provider for password reset, `HEALTH_URL` variable for the uptime check, offline backup of the signing key, Firebase project for push
- **Hardware:** XIAO nRF52840 Sense + Raspberry Pi Pico H ordered (AliExpress, ETA Nov 27 – Dec 4, 2026); battery, jumpers and soldering kit to buy locally
