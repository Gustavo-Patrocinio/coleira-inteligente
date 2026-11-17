# Data collection protocol (Phase 1)

How to record sessions that become training data: the collar logs the IMU while a phone
films the dog, and the two are aligned and labeled later in the [labeler](../../tools/labeler/).

**Goal of Phase 1:** ≥ 2 h labeled from **≥ 5 dogs** (the author's + ≥ 4 others, small /
medium / large), ≥ 3 min of each class 0–4, packet loss < 1%. Public datasets already
cover still, walking, running and shaking well (87 dogs), so our collection focuses on
what is missing: **scratching, sleep nights and dog diversity**
([public-dataset.md](../public-dataset.md)).

---

## 1. Welfare and safety (read first)

The dog's comfort comes before any data. Stop a session if the dog seems bothered.

- **Adaptation:** a few days wearing the collar without recording, 15–30 min at a time,
  increasing gradually. Check the skin under the case daily (redness, hair loss, rubbing).
  If irritation appears, stop and fix the fit before continuing.
- **Fit:** two fingers between collar and neck. The case sits under the neck, arrow up
  (contract 4.2). The case must not dangle.
- **Never force a behavior.** Do not induce scratching (no irritants, no tickling to
  provoke it) and do not stress the dog to make it run or shake. Record what happens
  naturally; long sessions capture rare behaviors.
- **Supervision:** until the sealed case (Phase 6), the dog wears the prototype only while
  someone is watching. Remove it before leaving the dog alone and at night unless doing a
  supervised night recording.
- **Battery (LiPo):**
  - only cells with a protection circuit (PCM);
  - **charge with the collar off the dog**, at room temperature, on a non-flammable surface,
    never unattended overnight;
  - a swollen, dented or hot cell is discarded immediately (battery recycling point),
    never used again;
  - keep the case rigid enough to protect the cell from bites and crushing.
- **Water:** the prototype is not waterproof. Remove it for baths, swimming and rain. For
  shake sessions after a bath, put the collar on **after towel-drying**, with the
  electronics inside a thin zip bag in the case. Splashes are fine; immersion is not.
- **Heat:** do not leave the collar in a closed car or in direct sun when not worn.

## 2. Consent (dogs that are not the author's)

Before the first session with someone else's dog, the owner reads and signs the
[consent template](consent-template.md) (translate it into the owner's language). Keep the
signed copy outside the repository. Each dog gets a `dog_id` code; the owner's name and
contact never go into `meta.json` or the repository.

## 3. Equipment checklist

- Collar with charged battery (≥ 50%), case closed, orientation arrow visible.
- Phone on a tripod or stable surface, collection app installed, storage for video.
- For night sessions: a camera with night vision (a baby monitor that records, or a phone
  in night mode next to a dim light).
- Kibble/water bowl and toys as usual for the session type.
- Before starting: in the app, confirm the collar is connected and data is flowing.

## 4. Camera setup

- Frame the **whole dog** most of the time; zoom out rather than in. If the dog leaves the
  frame, that stretch is labeled `unknown`.
- Good light, camera fixed (handheld is OK on walks, but keep the dog in view).
- Landscape, 30 fps or more. Do not use slow-motion or time-lapse modes.
- Avoid filming people's faces when possible; the video is only for labeling.

## 5. Sync taps (every session, start and end)

1. Start recording in the app (collar + video together).
2. Hold the collar case **in front of the camera** and tap it firmly with a finger
   **3 times**, about half a second apart.
3. Put the collar on the dog (or start the session if it is already on).
4. At the end, before stopping: **3 taps again** in front of the camera.

The end taps let the labeler correct clock drift (ADR 0003). A session without end taps is
still usable but is marked `drift_corrected: false` in its notes.

## 6. Session types

| Session | Length | How | Main classes |
|---|---|---|---|
| Rest | 10–20 min | dog resting or napping in its usual spot | still |
| Leash walk | 15–30 min | normal walk, vary pace; follow the dog to keep it in view | walking, still, sniffing |
| Play / run | 10–15 min | fetch or play in a safe area, letting the dog run freely | running, walking |
| Meals | until done | kibble and water as usual; camera close to the bowl | eating, drinking (Phase 6) |
| After a walk in grass / after a bath | 20–40 min | natural moments when dogs often scratch or shake; do not provoke | **scratching**, **shaking** |
| Long free session | 1–2 h | dog at home doing its own thing, camera on a wide view | **scratching**, rare behaviors |
| **Night** | 2–6 h | supervised, night-vision camera on the dog's bed; collar fitted snug | **sleep**, breathing (see below) |

Vary days, times, floors (tile, wood, grass, sand) and the person holding the leash.

### Night recordings (sleep and breathing)

- 2–3 nights per dog for the author's dog; at least 1 for some of the other dogs.
- The collar a bit snugger than usual (still two fingers), case centered under the neck.
- Camera framing the chest: the labeler will mark **asleep**, **lying awake** and **got up**,
  and in a few still stretches count breaths for 60 s (chest rises) to validate the
  respiratory-rate experiment ([breathing_feasibility.md](../results/breathing_feasibility.md)).
- If the logger supports it, enable raw mode with a more sensitive accelerometer range for
  these sessions and note it in `meta.json` (`accel_range`).
- Someone checks on the dog at least once; remove the collar if the dog is restless with it.

## 7. After each session

1. Stop recording after the end taps.
2. Export the session folder from the app: `imu.csv`, `meta.json`, video (contract 4.5).
3. Fill in `meta.json`: `dog_id`, `location`, `surface`, `notes` (session type, anything
   unusual, collar fit, weather). For a new dog, add size, approximate weight and breed in
   `notes`.
4. Copy it to `ml/data/raw/<session_id>/` (outside git). `session_id` =
   `YYYYMMDD-HHMM-<dog_id>`.
5. Quick check in the labeler: taps visible in the signal, packet loss < 1%, video plays.
6. Label it (see [labeling.md](labeling.md)) and export to `ml/data/labels/<session_id>.csv`.

## 8. Tracking progress

Keep a simple table (outside the repo or in `ml/data/`) with: session, dog, type, minutes,
labeled (yes/no), minutes per class. The labeler shows minutes per class for each session.
Phase 1 is done when the totals reach the goal at the top of this page.
