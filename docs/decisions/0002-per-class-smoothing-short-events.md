# ADR 0002: Per-class smoothing and windows for short events

- **Status:** accepted
- **Date:** 2026-11-16
- **Contract affected:** section 4.3

## Context

The contract called for majority-vote smoothing over the last 5 windows (1 s step) for
every class, and the Phase 0 plan said to drop every window with mixed labels.

A shake lasts ~1–2 s (median 1.4 s in the public dataset) and a short scratching bout
lasts a few seconds. These events cover 1–2 of the 5 windows, so they **never win the
majority** and disappear from the summary. For the same reason, almost no 2 s window is
100% "shaking", and dropping mixed windows would remove most examples of the rarest class.

## Decision

**Smoothing, two rules:**
- State classes (0 `still`, 1 `walking`, 2 `running`, later 5, 6): majority over the last
  5 windows.
- Event classes (3 `scratching`, 4 `shaking`): event detection. An event is confirmed when
  the class probability is ≥ `p_event` in ≥ `n_min` consecutive windows (initial values:
  `p_event = 0.6`, `n_min = 1` for shaking and 2 for scratching). These thresholds are
  calibrated in Phase 2 with our own data. A confirmed event overrides the state class
  for those seconds.

**Window label (training and evaluation):**
- The window gets the class that covers ≥ 70% of its samples. Below that, it is dropped
  (or labeled 255).
- For classes 3 and 4, a window is also accepted if the event covers ≥ 50% of the
  samples **or** ≥ 1 s contiguous (whichever comes first). With 100-sample windows the
  second condition implies the first; it matters again if the window grows.

## Alternatives

- **Smaller (1 s) windows for everything:** doubles inference and hurts the state classes.
- **A separate model for events:** more accurate, but costs flash and RAM. Revisit if F1
  for classes 3 and 4 does not reach 0.70.

## Consequences

The firmware has two post-processing paths, which need unit tests with synthetic
sequences. Training uses a parameterized window-labeling function in `coleira_ml`.
