# Labeling guide

Everyone who labels must use the same definitions; otherwise the model learns each
annotator's habits. When in doubt, label `unknown` (`x`): a missing label costs little, a
wrong one teaches the model the wrong thing.

Tool: [tools/labeler](../../tools/labeler/). Labels are exported in the contract 4.6 format.

## General rules

- **Sync first.** Mark the start and end taps before labeling anything (ADR 0003).
- **Label what you see, not what you expect.** If the dog is out of frame or hidden, it is
  `unknown`, even if you are sure it was lying down.
- **Boundaries:** start a segment on the first frame where the behavior is clearly
  happening and end it on the last such frame. The 1–2 s of transition between behaviors
  can stay unlabeled.
- **Minimum length:** don't label states shorter than 2 s (they barely fill one window).
  Events (scratching, shaking) are labeled even if short.
- **Uncertain** (`I` key, confidence 0.5): the behavior is probably right but the view is
  poor, or the boundary is fuzzy. Training can down-weight these.
- **Overlaps:** one label at a time. If two things happen at once, use the priority below.

**Priority when behaviors overlap:** shaking > scratching > drinking > eating > running >
walking > still. Example: the dog scratches while sitting → `scratching`.

## Class definitions (contract 4.1)

| Key | Class | Label it when | Do not label it as this when |
|---|---|---|---|
| `0` | **still** | lying, sitting, standing or sleeping without moving its feet; includes sniffing in place and small head turns | the dog is walking even slowly (→ walking); it is chewing a toy vigorously (→ unknown) |
| `1` | **walking** | moving forward at a walk, including sniffing while walking and pacing | ≥ 1 moment with all four feet off the ground repeatedly (→ running) |
| `2` | **running** | trot or gallop, including running while playing | jumping in place, tug of war (→ unknown) |
| `3` | **scratching** | scratching itself with a hind leg (neck, ear, flank), from the first to the last kick of the bout | licking or biting itself (→ unknown, for now); rubbing on furniture or the floor (→ unknown) |
| `4` | **shaking** | whole-body shake (the "wet dog" shake), from the first to the last twist | head-only shake (→ unknown; a possible future class) |
| `5` | **eating** | head at the bowl, chewing or taking kibble | sniffing the bowl without eating (→ still) |
| `6` | **drinking** | lapping water | standing near the bowl (→ still) |
| `x` | **unknown** | play, tug, jumping, being petted or handled, out of frame, anything that fits none of the above | — |

## Night sessions

For sleep, in addition to `still` (the class does not change), add a note per stretch in
the session's `notes` or a separate file `ml/data/labels/<session_id>_sleep.csv` with
`start_ms,end_ms,state` where `state` is `asleep`, `lying_awake` or `got_up`:

- **asleep:** eyes closed or head resting, no head movement for ≥ 30 s;
- **lying_awake:** lying with the head up, looking around, ears moving;
- **got_up:** stood up or walked.

For breathing, pick still stretches with a clear view of the chest and count breaths for
60 s; record `start_ms,breaths_per_min` in `ml/data/labels/<session_id>_breaths.csv`.
These files are experimental and not part of the contracts yet.

## Quality check

- About 10% of sessions are labeled by a second person; compare segment by segment. If
  agreement on a class is poor, refine its definition in this file.
- Before exporting, scroll through the whole session in the labeler with the 120 s window:
  every colored band should match what the video shows.
