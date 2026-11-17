# Public dataset: Movement Sensor Dataset for Dog Behavior Classification

- **Source:** Mendeley Data, DOI [10.17632/vxhx934tbn.4](https://data.mendeley.com/datasets/vxhx934tbn) (version 4, Nov 2025)
- **Cite (requested by the authors):**
  - Vehkaoja et al. (2022). *Description of movement sensor dataset for dog behavior classification.* Data in Brief 40, 107822.
  - Kumpulainen et al. (2021). *Dog behaviour classification with movement sensors placed on the harness and the collar.* Applied Animal Behaviour Science 241, 105393.
- **License:** CC BY 4.0 according to mirrors (forskning.fi). Still to be confirmed on the Mendeley page.
- **Download:** `cd ml && uv run python scripts/download_public.py` checks SHA-256 and extracts into `ml/data/public/` (outside git).

## What is inside (measured 2026-11-16)

- **45 dogs, 62 tests** (some dogs did 2), 10.6 million rows.
- **100 Hz**, ActiGraph GT9X Link, with two sensors: back (harness) and **neck (collar)**. We use only the neck one (`ANeck_*`, `GNeck_*`).
- Apparent units: accelerometer in **g**, gyroscope in **°/s**. The GT9X full-scale ranges are not confirmed yet.
- The CSV header says `ANeck_x, ANeck_y`, but `Data_description.txt` lists `ANeck_y` before `ANeck_x`. The header names win.
- Up to **3 simultaneous labels** per sample (`Behavior_1..3`). 28% of samples have 2 or more (e.g. `Panting` together with a posture).
- The `Task` column is the task the dog was asked to do (sit, stand, walk, trot, play, lie down, treat-search). **It is not the label**: the label is `Behavior_*`.

### Minutes per behavior (summing the 3 columns)

| Behavior | min | Our class |
|---|---:|---|
| Panting | 296 | ignored (overlaid on a posture) |
| Lying chest | 188 | 0 `still` |
| Sitting | 187 | 0 `still` |
| Standing | 171 | 0 `still` |
| Sniffing | 171 | 255: **always** alone, never with a posture or gait, so still and walking cannot be told apart (ADR 0004) |
| Playing | 156 | context: with a gait, the gait wins; alone, 255 |
| Walking | 131 | 1 `walking` |
| Trotting | 129 | 2 `running` |
| Eating | 52 | 5 `eating` (Phase 6) |
| Tugging | 50 | 255 |
| Galloping | 29 | 2 `running` |
| Carrying object | 24 | context (same as Playing) |
| Pacing | 13 | 1 `walking` (lateral gait; to confirm) |
| Drinking | 11 | 6 `drinking` (Phase 6) |
| **Shaking** | **7** | **4 `shaking`** |
| Jumping | 7 | 255 |
| Synchronization / Bowing / Extra_Sync | 3 | 255 |
| `<undefined>` | 3680 | 255 |

### Simultaneous labels: what appears together

Combinations that drove the rules in `coleira_ml.public_dataset.map_label_set`:

- **Galloping almost never appears alone** (0.6 min). It comes with `Playing` (13.6 min)
  or `Playing + Carrying object` (14.9 min). If `Playing` turned a sample into 255, we
  would lose all galloping. That is why `Playing`/`Carrying object` are *context*.
- `Eating` appears with a posture (`Standing` 19 min, `Lying chest` 14, `Sitting` 13): it
  becomes 5. With a gait (6 min): 255.
- Time is continuous: every sample is exactly 10 ms apart, no gaps inside a test.

### After mapping + resampling to 50 Hz

| Class | min | dogs |
|---|---:|---:|
| 0 `still` | 500.2 | 45 |
| 1 `walking` | 139.0 | 45 |
| 2 `running` | 156.0 | 45 |
| 4 `shaking` | 7.0 (286 events, median 1.4 s) | 45 |
| 5 `eating` | 45.7 | 42 |
| 6 `drinking` | 10.8 | 35 |
| 255 | 909.9 | — |

### Sensor range

The dataset peaks at ~19 g and ~2470 °/s. **35% of shaking samples exceed 8 g**, which led
to ADR 0005 (accelerometer at ±16 g). The loader saturates the data at our IMU's range
(±16 g, ±2000 dps) so training looks like the real collar.

Exploration with plots: `ml/notebooks/01_explore.ipynb`.

## Consequences for the plan

- **It has shaking (7 min), eating (52 min) and drinking (11 min).** Classes 4–6 can be
  pre-trained on public data before our own collection.
- **It has no scratching.** Class 3 depends entirely on our own collection (Phase 1).
- `running` is internally imbalanced: gallop (29 min) is much rarer than trot (129 min).
- The mapping is implemented and tested in `coleira_ml.public_dataset` (`map_label_set`).
