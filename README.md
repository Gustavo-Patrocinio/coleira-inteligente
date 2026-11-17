# Smart Dog Collar · on-device behavior recognition

[![CI](https://github.com/Gustavo-Patrocinio/coleira-inteligente/actions/workflows/ci.yml/badge.svg)](https://github.com/Gustavo-Patrocinio/coleira-inteligente/actions/workflows/ci.yml)

A dog collar that **recognizes what the dog is doing on the chip itself** (still, walking,
running, scratching, shaking, and later eating and drinking), learns what is normal for
*that* dog, and warns the owner when something changes: *"scratched 3× more than usual"*,
*"restless night"*, *"activity 40% below normal for 3 days"*.

**Open and buildable by anyone, for any dog** ([ADR 0009](docs/decisions/0009-open-project-for-any-dog.md)):
the goal is that you can order the parts, follow the guide, flash the firmware, install the
app and use it with your own dog. A ready-made product is a later goal. Built like a
product, not a demo: every decision is measured, written down as an
[ADR](docs/decisions/), and every phase ends with an objective done criterion.

![System architecture](docs/images/architecture.svg)

> **Status:** Phase 0 (ML pipeline) ✅ complete. Software for Phases 1–4 is written and
> tested without hardware (firmware builds and is host-tested, backend runs on a real
> TimescaleDB, the Flutter app has 19 tests); the board is on the way to validate it on a
> real dog. See the [roadmap](#roadmap).

---

## Highlights

- **TinyML on a coin-sized board.** An int8 1D CNN of **18.8 KB** classifies 2-second IMU
  windows on an nRF52840, with **0.957 balanced accuracy on dogs it has never seen**.
- **Two-level classification for battery life.** A 29-node decision tree runs *inside the
  IMU* (ST's Machine Learning Core) and only wakes the MCU when the dog moves
  (0.986 balanced accuracy for still × moving).
- **Honest evaluation.** Train/test splits are always **by dog** (`GroupKFold`); random
  window splits are forbidden because they inflate accuracy. The code asserts there is no
  leakage.
- **Robust to a rotating collar.** 3D-rotation augmentation keeps accuracy at 0.957 when
  the collar is turned on the neck; without it, accuracy drops to 0.779.
- **Data arrives on its own.** A home base station (ESP32, Wi-Fi) syncs with the collar
  over BLE; the phone app is the fallback away from home. Ingestion is idempotent, so
  nothing is lost or duplicated ([ADR 0007](docs/decisions/0007-data-sync-architecture.md)).
- **Our own labeling tool.** A no-install web app that syncs video and IMU, corrects clock
  drift, and labels with the keyboard ([tools/labeler](tools/labeler/)).

---

## Results so far (Phase 0, public dataset, collar sensor only)

Evaluated with 5-fold `GroupKFold` by dog on the
[Movement Sensor Dataset for Dog Behavior Classification](docs/public-dataset.md)
(45 dogs). Full tables in [docs/results.md](docs/results.md).

| Model | Classes | Balanced accuracy | Size |
|---|---|---:|---:|
| Shallow Random Forest (baseline) | still · walking · running | 0.956 ± 0.013 | ~64 KB |
| **1D CNN, int8** | still · walking · running | **0.957 ± 0.010** | **18.8 KB** |
| 1D CNN, int8, collar rotated | still · walking · running | 0.957 ± 0.010 | 18.8 KB |
| MLC decision tree (in the IMU) | still × moving | 0.986 ± 0.004 | 29 nodes |

<table>
  <tr>
    <td width="58%"><img src="docs/images/behaviors.png" alt="Accelerometer and gyroscope traces for each behavior"></td>
    <td width="42%"><img src="docs/results/figures/D_cnn_int8.png" alt="Confusion matrix of the int8 CNN on unseen dogs"></td>
  </tr>
  <tr>
    <td><sub>How each behavior looks from the collar: still is flat, walking and running
    are periodic, shaking is a short burst that saturates the gyroscope.</sub></td>
    <td><sub>int8 CNN on unseen dogs. The remaining confusion is fast walking × slow trot.</sub></td>
  </tr>
</table>

<img src="docs/images/intensity.png" alt="Movement intensity per class" width="70%">

<sub>A single feature (variation of the acceleration magnitude over 2 s) already grows
~10× per step from still to walking to running to shaking.</sub>

**Honest check across populations.** Adding a second public dataset (Marcato et al. 2023,
42 assistance dogs, [details](docs/results/multi_dataset.md)) shows the real challenge: a
model trained on one dataset and tested on the other's dogs scores **0.71–0.85**, mostly
because each lab drew the still / walking boundary differently. Training on both helps the
harder population (+0.07) without hurting the other, and a shared
[labeling guide](docs/protocols/labeling.md) is now part of the protocol.

> These numbers come from public datasets (different sensor, controlled environments).
> The drop on our own dogs' data (domain gap) will be measured in Phase 1.

---

## What the owner sees

The app is built around questions an owner actually asks, always compared against the
dog's own normal ([indicators](docs/product/indicators.md) ·
[clickable prototype](docs/product/app-prototype/)):

| Indicator | Question |
|---|---|
| **Exercise** | Did he burn his energy today? |
| **Sleep** | Did he sleep well? How often did he wake up? |
| **Skin** | Is he scratching more than usual? |
| **Something's off** | Is he lethargic or acting differently? |
| **Water** *(Phase 6)* | Is he drinking a lot more? |

Experimental: **sleeping respiratory rate** from the IMU while the dog is still. Vets ask
owners to count resting breaths because a persistent increase is an early sign of heart
disease. A [feasibility check](docs/results/breathing_feasibility.md) on the public dataset
shows the collar clearly sees **panting** (a candidate new class), while calm breathing
still needs our own night recordings to confirm.

---

## How it works

**On the collar.** The IMU samples at 50 Hz (±16 g, ±2000 dps). A tiny decision tree in
the IMU decides still × moving; while the dog is still, the MCU sleeps and just counts
time. When the dog moves, the MCU runs the CNN on 2 s windows (7 channels: 3-axis accel,
3-axis gyro, and acceleration magnitude), smooths the output (majority vote for states,
event detection for short bursts like shakes), and writes a **15-byte summary per minute**
to flash, enough for weeks of history.

**Getting data out.** A home base station (or the phone) asks the collar for "everything
since minute X" over BLE and uploads it over Wi-Fi. The backend keys every minute by
`device_id + minute_ts`, so re-sending a batch is harmless.

**In the backend.** TimescaleDB stores per-minute activity; a nightly job builds each dog's
baseline (median + MAD per hour of day, weekday vs weekend, last 28 days) and raises alerts
with a robust z-score only after 14 days of history.

The data formats (classes, packets, CSVs, summary record) are fixed
[contracts](CLAUDE.md#4-contracts-do-not-change-without-an-adr); changing one requires an ADR.

---

## Repository layout

```
ml/              Python: dataset loader, windows, features, CNN, int8 export, tests
  notebooks/     exploration (01_explore.ipynb)
  scripts/       download data, train baseline/CNN, generate a synthetic session
tools/labeler/   web labeling tool (video + IMU), no build step
firmware/        Zephyr / NCS: logger (raw BLE stream) and app (TFLite Micro, summaries, sync)
basestation/     ESP32 home base station (Phase 4, not started; ml/scripts/sync_ble.py emulates it)
app/             Flutter app for iOS and Android (dashboard, collection mode, sync)
backend/         Fastify + Postgres/TimescaleDB (ingestion, baseline, alerts)
hardware/        enclosure CAD (Phase 6) and custom PCB (Phase 7)
docs/            ADRs, results, dataset notes, product indicators
```

---

## Getting started

### ML pipeline

Requires [uv](https://docs.astral.sh/uv/); it installs Python 3.12 for the project.

```bash
cd ml
uv sync                                     # environment + dependencies
uv run python scripts/download_public.py    # public dataset (~440 MB, SHA-256 checked)
uv run python scripts/train_baseline.py     # Random Forest + MLC tree  (~20 s)
uv run python scripts/train_cnn.py          # CNN float + int8, 5 folds (~10 min, CPU)
uv run pytest                               # tests
```

Reports are written to `docs/results/`; the int8 model to `ml/models/` (not versioned).

### Labeling tool

Open `tools/labeler/index.html` in Chrome or Edge. To try it without hardware:

```bash
cd ml && uv run python scripts/make_synthetic_session.py
```

then open the folder `ml/data/raw/synthetic_demo/` in the labeler. The synthetic session
uses real signal, shows the behavior on screen, and simulates clock drift and packet loss.

---

## Engineering decisions

| ADR | Decision |
|---|---|
| [0001](docs/decisions/0001-summary-record-version-byte.md) | Version byte in the per-minute summary |
| [0002](docs/decisions/0002-per-class-smoothing-short-events.md) | Per-class smoothing so short events (shakes) survive |
| [0003](docs/decisions/0003-session-time-sync.md) | Video × IMU sync with start/end taps and drift correction |
| [0004](docs/decisions/0004-stationary-sniffing.md) | Stationary sniffing counts as "still" |
| [0005](docs/decisions/0005-accelerometer-16g.md) | Accelerometer at ±16 g (35% of shakes exceed 8 g) |
| [0006](docs/decisions/0006-keras-for-the-cnn.md) | Keras/TensorFlow for a reliable int8 TFLite path |
| [0007](docs/decisions/0007-data-sync-architecture.md) | Home Wi-Fi base station + phone over BLE (Wi-Fi on the collar kept as an option) |
| [0008](docs/decisions/0008-english-class-names.md) | English class names, stable IDs |
| [0009](docs/decisions/0009-open-project-for-any-dog.md) | Open project for any dog first, product later |
| [0010](docs/decisions/0010-logger-sampling-and-gatt.md) | Logger sampling clock (IMU 104 Hz read at 50 Hz) and GATT service |
| [0011](docs/decisions/0011-daily-baseline-alerts.md) | Alerts on daily totals vs a same-day-type baseline |
| [0012](docs/decisions/0012-ble-library-license.md) | universal_ble (BSD-3) instead of flutter_blue_plus (paid commercial license) |
| [0013](docs/decisions/0013-summary-sync-protocol.md) | Per-minute storage in flash and the BLE sync protocol |
| [0014](docs/decisions/0014-raw-dump-mode.md) | Raw dump mode in the collar firmware (collect data without reflashing) |

---

## Roadmap

| Phase | Goal | Done when | Status |
|---|---|---|---|
| 0 | ML pipeline on a public dataset | int8 CNN ≥ 85% balanced acc. on unseen dogs, < 64 KB | ✅ 0.957, 18.8 KB |
| 1 | Collect and label data from real dogs | ≥ 2 h labeled from ≥ 5 dogs, ≥ 3 min per class, < 1% packet loss | 🚧 labeler, logger firmware, PC recorder and phone collection mode ready; hardware shipping |
| 2 | Model running on the chip | F1 ≥ 0.85 (states), ≥ 0.70 (events) on unseen dogs, inference < 50 ms | 🚧 firmware builds, host-tested against training; needs the board and our own data |
| 3 | Wireless, full day on battery, OTA | 24 h recorded, lossless sync, OTA tested | 🚧 flash storage + BLE sync (firmware, app, PC base-station emulator); OTA and power measurements pending |
| 4 | Backend, alerts, home base station | a real alert fires; no duplicates; data arrives on its own | 🚧 backend + alerts done (19 tests on a real TimescaleDB); ESP32 base station and push pending |
| 5 | Two-level classification for battery life | ≥ 14 days measured in the field | |
| 6 | Open release + beta | 10+ owners for a month, 3+ collars built by others from the docs | |
| 7 | Product (later goal) | production design, certification, viable cost per unit | |

**Want to help?** Once Phase 1 hardware works, the most valuable contribution is labeled
data from more dogs (all sizes and breeds). A contribution guide will follow.

The detailed checklist lives in [CLAUDE.md](CLAUDE.md#7-plan-by-phase).

## Hardware (prototype)

Seeed XIAO nRF52840 Sense · 3.7 V ~250 mAh LiPo · Raspberry Pi Pico as SWD probe ·
Nordic PPK2 for power measurements · later an LSM6DSOX/LSM6DSV16X (MLC), a MAX17048 fuel
gauge and an ESP32 base station.

## Animal welfare

The dog's comfort comes first: gradual adaptation, minimal weight (the target is well under
3% of body weight; the prototype is ~15 g), regular skin checks, supervised use until the
enclosure is sealed, and no behavior is ever forced to collect data.

## Data and citation

The public dataset is by Vehkaoja et al. (2022), *Data in Brief* 40, 107822, and
Kumpulainen et al. (2021), *Applied Animal Behaviour Science* 241, 105393
([Mendeley Data](https://data.mendeley.com/datasets/vxhx934tbn)). It is downloaded by a
script and never committed.

## License

[MIT](LICENSE). The public dataset keeps its own license and is not redistributed here.
