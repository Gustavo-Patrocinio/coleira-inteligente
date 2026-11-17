"""Event smoothing (ADR 0002) in Python, and calibration of `p_event` / `n_min`.

`smooth_sequence` is a line-by-line port of firmware/app/src/smoothing.c (checked against
the C code in tests/test_events.py), so a calibration done here behaves the same on the chip.

Event metrics work on runs of windows (1 s step): a true event is a run of windows labeled
with the event class; a predicted event is a run of smoothed outputs with that class. A
predicted event that overlaps a true one is a hit. False events per hour matter most for the
owner: a scratching alarm that never happened erodes trust faster than a missed one.
"""

from __future__ import annotations

from collections.abc import Iterable, Sequence
from dataclasses import dataclass

import numpy as np

UNKNOWN = 255


def smooth_sequence(
    probs: np.ndarray,
    class_ids: Sequence[int],
    n_min: dict[int, int],
    p_event: float,
    majority_len: int = 5,
) -> np.ndarray:
    """Per-window probabilities (n, k) → smoothed contract class IDs (n,), as the firmware.

    `n_min[class_id]` ≥ 1 marks an event class; classes not in it are state classes.
    """
    k = len(class_ids)
    nmin = [int(n_min.get(int(c), 0)) for c in class_ids]
    probs = np.asarray(probs, dtype=np.float32)
    p_event = np.float32(p_event)
    hist: list[int] = [0] * majority_len
    hist_count = hist_pos = 0
    run = [0] * k
    out = np.empty(len(probs), dtype=np.uint8)
    for t, p in enumerate(probs):
        best_state = best_event = -1
        for i in range(k):
            if nmin[i] == 0:
                if best_state < 0 or p[i] > p[best_state]:
                    best_state = i
                continue
            run[i] = min(run[i] + 1, 255) if p[i] >= p_event else 0
            if run[i] >= nmin[i] and (best_event < 0 or p[i] > p[best_event]):
                best_event = i
        if best_state >= 0:
            hist[hist_pos] = best_state
            hist_pos = (hist_pos + 1) % majority_len
            hist_count = min(hist_count + 1, majority_len)
        if best_event >= 0:
            out[t] = class_ids[best_event]
            continue
        counts = [0] * k
        for j in range(hist_count):
            counts[hist[j]] += 1
        best, best_count = -1, 0
        for j in range(hist_count):  # newest first: ties go to the most recent class
            c = hist[(hist_pos - 1 - j) % majority_len]
            if counts[c] > best_count:
                best, best_count = c, counts[c]
        out[t] = UNKNOWN if best < 0 else class_ids[best]
    return out


def runs(labels: np.ndarray, cls: int) -> list[tuple[int, int]]:
    """[start, end) of each run of `cls` in a label sequence."""
    m = np.r_[False, np.asarray(labels) == cls, False]
    d = np.flatnonzero(np.diff(m.astype(np.int8)))
    return list(zip(d[::2].tolist(), d[1::2].tolist(), strict=True))


@dataclass(frozen=True)
class EventScore:
    true_events: int
    pred_events: int
    hits_true: int  # true events overlapped by a prediction
    hits_pred: int  # predicted events that overlap a true one
    hours: float

    @property
    def recall(self) -> float:
        return self.hits_true / self.true_events if self.true_events else float("nan")

    @property
    def precision(self) -> float:
        return self.hits_pred / self.pred_events if self.pred_events else float("nan")

    @property
    def f1(self) -> float:
        p, r = self.precision, self.recall
        if np.isnan(p) or np.isnan(r) or p + r == 0:
            return 0.0
        return 2 * p * r / (p + r)

    @property
    def false_per_hour(self) -> float:
        return (self.pred_events - self.hits_pred) / self.hours if self.hours else float("nan")


def _overlaps(a: tuple[int, int], b: tuple[int, int]) -> bool:
    return a[0] < b[1] and b[0] < a[1]


def event_score(
    sequences: Iterable[tuple[np.ndarray, np.ndarray]], cls: int, step_s: float = 1.0
) -> EventScore:
    """Score over several (true_labels, smoothed) sequences of windows."""
    nt = npred = ht = hp = 0
    n_windows = 0
    for true, pred in sequences:
        te, pe = runs(true, cls), runs(pred, cls)
        nt += len(te)
        npred += len(pe)
        ht += sum(any(_overlaps(t, p) for p in pe) for t in te)
        hp += sum(any(_overlaps(p, t) for t in te) for p in pe)
        n_windows += len(true)
    return EventScore(nt, npred, ht, hp, n_windows * step_s / 3600)


@dataclass(frozen=True)
class Calibration:
    p_event: float
    n_min: dict[int, int]
    scores: dict[int, EventScore]

    @property
    def mean_f1(self) -> float:
        return float(np.mean([s.f1 for s in self.scores.values()]))


def calibrate(
    sequences: Sequence[tuple[np.ndarray, np.ndarray]],
    class_ids: Sequence[int],
    event_classes: Sequence[int],
    p_grid: Sequence[float] = (0.4, 0.5, 0.6, 0.7, 0.8, 0.9),
    n_grid: Sequence[int] = (1, 2, 3),
    majority_len: int = 5,
) -> list[Calibration]:
    """Grid search over the shared `p_event` and per-class `n_min` (the firmware's knobs).

    `sequences`: (probs (n, k), true window labels (n,)) per contiguous stretch. Returns all
    candidates, best first: highest mean event F1, then fewest false events per hour.
    """
    event_classes = [c for c in event_classes if c in class_ids]
    if not event_classes:
        raise ValueError("the model has none of the event classes")
    combos = np.array(np.meshgrid(*[n_grid] * len(event_classes))).T.reshape(-1, len(event_classes))
    out = []
    for p in p_grid:
        for combo in combos:
            nmin = dict(zip(event_classes, (int(v) for v in combo), strict=True))
            smoothed = [
                (true, smooth_sequence(probs, class_ids, nmin, p, majority_len))
                for probs, true in sequences
            ]
            scores = {c: event_score(smoothed, c) for c in event_classes}
            out.append(Calibration(float(p), nmin, scores))
    out.sort(
        key=lambda c: (-c.mean_f1, sum(s.false_per_hour for s in c.scores.values()), c.p_event)
    )
    return out
