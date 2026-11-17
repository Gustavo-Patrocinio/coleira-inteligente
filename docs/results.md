# Results

Summary of every model. Each experiment's details (per-class F1, confusion matrix, folds)
live in the generated reports under `docs/results/`.

Rules (section 6 of CLAUDE.md): evaluation is always **by group** (dog / session), and
every result reports balanced accuracy, per-class F1, confusion matrix, size and RAM.

## Phase 0: public dataset, collar only, unseen dogs (GroupKFold 5×)

| Model | Classes | Balanced acc. | F1 (per class) | Size | RAM | Report |
|---|---|---:|---|---:|---:|---|
| Shallow RF (50 trees, depth ≤ 8) | 0, 1, 2 | **0.956 ± 0.013** | still 0.99 · walking 0.90 · running 0.96 | ~64 KB* | ~1.7 KB* | [A](results/phase0_baseline.md) |
| Shallow RF (50 trees, depth ≤ 8) | 0, 1, 2, 4 | 0.960 ± 0.013 | … · shaking 0.93 | ~52 KB* | ~1.7 KB* | [B](results/phase0_baseline.md) |
| MLC tree (depth ≤ 4, no FFT) | still × moving | 0.986 ± 0.004 | still 0.99 · moving 0.98 | 29 nodes | — | [C](results/phase0_baseline.md) |
| 1D CNN float (with augmentation) | 0, 1, 2 | 0.957 ± 0.010 | | 8.4k params | | [D](results/phase0_cnn.md) |
| **1D CNN int8 (with augmentation)** ✅ | 0, 1, 2 | **0.957 ± 0.010** | still 0.99 · walking 0.91 · running 0.95 | **18.8 KB** (.tflite) | ~2.3 KB* (activations) | [D](results/phase0_cnn.md) |
| 1D CNN int8, test with a **rotated** collar | 0, 1, 2 | 0.957 ± 0.010 (no aug: **0.779**) | | | | [D](results/phase0_cnn.md) |

\* Estimates: size ≈ 10 B per tree node; RAM = int16 window + |a| + feature vector, or the
largest pair of consecutive int8 activations for the CNN. Measured numbers come when we
export to the firmware (Phase 2).

### Reading (2026-11-16)

- ✅ **Phase 0 target met:** int8 CNN with **0.957** balanced accuracy on unseen dogs
  (target ≥ 0.85), at **18.8 KB** (target < 64 KB).
- **int8 lost nothing** compared with float (difference < 0.002 in every fold).
- **Augmentation is what makes it robust to rotation:** without it, rotating the collar
  drops accuracy from 0.966 to **0.779**; with it, accuracy stays at 0.957 either way. It
  costs ~1 point on the original test and is worth it, because collars rotate. The official
  model uses augmentation.
- **The CNN ties with the RF (0.956) while being 3× smaller** and with no hand-crafted features.
- **The main confusion is walking → running (8%).** Fast walking and slow trotting are neighbors.
- **Shaking: F1 0.93 with only 390 windows.** It is a very distinct signal (see `01_explore`).
- **MLC tree: 98.6% with 29 nodes**, which makes Phase 5's level 1 viable (the MCU sleeps
  while the IMU decides "still"). ⚠️ It uses axis-specific features (`ay`, `az`), which
  depend on collar orientation. It must be retrained with random rotation and validated on
  our own data before going into the IMU.
## Two public datasets (Vehkaoja + Marcato, 87 dogs) · [report](results/multi_dataset.md)

| Experiment | Balanced acc. |
|---|---:|
| Train V (45 dogs) → test M (42 other dogs, other lab) | **0.707** |
| Train M → test V | **0.851** |
| GroupKFold by dog, V test dogs: trained on V only / on V + M | 0.965 / 0.962 |
| GroupKFold by dog, M test dogs: trained on V only / on V + M | 0.665 / **0.737** |
| Combined int8 model (87 dogs) | 18.9 KB |

### Reading (2026-11-16)

- **Cross-population accuracy drops a lot (0.96 → 0.71–0.85).** This is the honest number
  for "someone else's dog, set up by someone else", and the main risk for the open project.
- **Most of the gap is where each lab drew the still / walking boundary**, not the sensor:
  the V-trained model calls 28% of M's "still" walking, and the M-trained model calls 42% of
  V's "walking" still. M's dogs stand with small steps during commanded postures; V's
  "walking" includes slow, sniffing walks. Consistent definitions
  ([labeling guide](protocols/labeling.md)) matter as much as more data.
- **Adding M helps M-like dogs (+0.07) without hurting V dogs.** More diverse data is worth it.
- **Shaking does not transfer from M** (F1 0.24–0.42 on M dogs): only ~19 short shakes in M,
  labeled at 1 s resolution, so boundaries are coarse.
- **What this changes:** every future model is also reported on a held-out population
  (cross-dataset), not only on held-out dogs; Phase 1 data is labeled with one shared guide;
  the Phase 1 domain-gap measurement on our own dogs is now the key result.

## Notes

- **Breathing ([report](results/breathing_feasibility.md)):** the collar clearly sees
  panting (~240/min, sharp peak); calm resting breathing is inconclusive on this dataset.
  Respiratory rate stays experimental until Phase 1 night videos.
- ⚠️ **All of this is on the public dataset** (different sensor, different mounting, dogs
  in a controlled setting). The drop on our own dog's data (domain gap) is measured in Phase 1.
