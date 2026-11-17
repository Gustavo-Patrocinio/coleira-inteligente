# Owner-facing indicators (what the app shows)

Decided on 2026-11-16 from the app prototype (private link, kept outside the repo).

Criterion: only what answers a question the owner actually asks, and leads to some action,
goes on the main screen. Every number is compared against **the dog's own normal**
(Phase 4 baseline), never against a generic rule.

| Indicator | Owner's question | How it is computed | Phase |
|---|---|---|---|
| **Exercise** | "Did he burn his energy today?" | minutes of `walking` + `running` per day | 3 |
| **Sleep** | "Did he sleep well?" | see *Sleep* below (three levels, from simple to experimental) | 3 → 5 |
| **Skin** | "Is he scratching more?" | minutes and bouts of `scratching` | 3 (depends on Phases 1–2) |
| **Something's off** | "Is he lethargic or acting differently?" | robust z-score alerts against the baseline | 4 |
| **Water** | "Is he drinking a lot more?" | minutes of `drinking` | 6 |

## Sleep

Explicit owner request (2026-11-16). Three levels, from most reliable to experimental:

1. **Sleep estimated from immobility (actigraphy):** hours asleep at night, time he lay
   down and got up, number of awakenings (left `still` for ≥ 1 min), longest uninterrupted
   stretch, daytime naps. Comes from the existing per-minute summary (contract 4.7), no new
   model needed. Good for trends, not exact minute by minute. **Phase 3.**
2. **Asleep × lying awake:** an awake dog moves and raises its head; asleep, the neck
   angle changes (head resting) and there is almost no micro-movement. Needs ground truth:
   **record nights with a night-vision camera in Phase 1**. If they can be separated,
   "asleep" becomes a new class or a flag in the per-minute summary (decide in an ADR,
   since sleeping is part of class 0 today).
3. **Sleeping respiratory rate (experimental):** breathing may show up in the
   accelerometer when the dog is still. Vets ask owners to count resting breaths, because a
   persistent increase (above ~30/min) is an early sign of heart disease. It is the most
   clinically valuable indicator, if the collar can pick it up.
   - Signal path: only while fully still → 60 s window → remove gravity and band-pass
     0.1–1 Hz (10–30 breaths/min ≈ 0.17–0.5 Hz) → pick the strongest axis → count cycles
     (peaks or dominant frequency) → reject irregular windows (movement, dreaming).
   - Validate with the nights recorded in Phase 1 (breaths counted on video × raw signal),
     target error ±2 breaths/min.
   - **Feasibility check on the public dataset (2026-11-16,
     [report](../results/breathing_feasibility.md)):** panting is clearly visible (sharp
     peak at ~240/min, median SNR ~700), so the collar does see respiratory movement. Calm
     breathing is **inconclusive, leaning negative**: peaks mostly sit at ~9/min near the
     band edge (drift-like), only 6% in the plausible resting range. Stays experimental
     until Phase 1 night videos; try a snug collar, the gyroscope and a ±2 g range during
     sleep sampling.
   - Energy: sample ~1 min every 30 min during sleep, not continuously (Phase 5).
   - Needs a new field in the summary → summary v2 (the ADR 0001 version byte allows it).

The app never calls this a "sleep study": always "estimated from movement".

## What does NOT go on the main screen

- **Shakes:** still a model class (a strong movement the model must recognize so it does
  not confuse it with others), but the number alone leads to no action. Only available in
  the day's detail.
- **Sleep claims we do not measure** (sleep stages, 0–100 "quality" scores): only show what
  the levels above support.

## Ideas for later

- **Panting** (new class or a flag inside `still`, new ID + ADR): clearly visible from the
  collar and labeled for 296 min in the public dataset. Useful on its own: heat stress,
  pain, anxiety ("panting a lot while resting on a cool day").
- **Head shaking** (new class, ID 7+): a classic sign of ear infection, more clinically
  valuable than a whole-body shake. Needs collection and an ADR.
- Share a summary with the vet (web page on top of the Phase 4 API).
