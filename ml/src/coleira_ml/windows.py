"""Windowing (contract 4.3) and window labels (ADR 0002).

- 2 s = 100 samples at 50 Hz, 1 s step (50% overlap).
- Windows never cross the boundary between tests/sessions (`group_cols`).
- Label: the class covering ≥ 70% of the samples; for event classes (scratching,
  shaking), ≥ 50% of the samples OR ≥ 1 s contiguous is enough. Otherwise → 255
  (dropped from training).
"""

from __future__ import annotations

from dataclasses import dataclass

import numpy as np
import pandas as pd

from coleira_ml.classes import EVENT_CLASSES, N_SUMMARY_CLASSES, Behavior

WINDOW = 100
STEP = 50
STATE_MIN_FRACTION = 0.70
EVENT_MIN_FRACTION = 0.50
EVENT_MIN_RUN = 50  # 1 s at 50 Hz
# Note: with a 100-sample window, "≥ 1 s contiguous" implies "≥ 50%", so the run
# criterion is redundant today. It matters again if the window grows (ADR 0002).

UNKNOWN = int(Behavior.UNKNOWN)
_EVENT_IDS = np.array(sorted(int(b) for b in EVENT_CLASSES), dtype=np.uint8)


@dataclass(frozen=True)
class Windows:
    X: np.ndarray  # (n, WINDOW, channels) float32
    y: np.ndarray  # (n,) uint8, 255 for windows without a clear label
    groups: np.ndarray  # (n,) group id (dog / session) for GroupKFold
    channels: tuple[str, ...]


def _longest_run(mask: np.ndarray) -> np.ndarray:
    """Longest run of True in each row of a boolean (n, W) matrix."""
    n, w = mask.shape
    run = np.zeros(n, dtype=np.int32)
    best = np.zeros(n, dtype=np.int32)
    for j in range(w):
        run = np.where(mask[:, j], run + 1, 0)
        best = np.maximum(best, run)
    return best


def label_windows(labels: np.ndarray) -> np.ndarray:
    """Label each window from the (n, WINDOW) matrix of per-sample labels."""
    n, w = labels.shape
    out = np.full(n, UNKNOWN, dtype=np.uint8)

    # 1) any known class (0..6) with a strong majority; 255 never "wins"
    counts = np.stack([(labels == c).sum(axis=1) for c in range(N_SUMMARY_CLASSES)], axis=1)
    top = counts.argmax(axis=1)
    strong = counts[np.arange(n), top] >= STATE_MIN_FRACTION * w
    out[strong] = top[strong]

    # 2) event classes get a looser rule and priority (short events must not vanish)
    best_event_count = np.zeros(n, dtype=np.int32)
    for c in _EVENT_IDS:
        mask = labels == c
        cnt = mask.sum(axis=1)
        ok = (cnt >= EVENT_MIN_FRACTION * w) | (_longest_run(mask) >= EVENT_MIN_RUN)
        take = ok & (cnt > best_event_count)
        out[take] = c
        best_event_count = np.where(take, cnt, best_event_count)
    return out


def make_windows(
    df: pd.DataFrame,
    channels: list[str],
    group_cols: tuple[str, ...] = ("dog_id", "test_num"),
    split_group: str = "dog_id",
    label_col: str = "class_id",
) -> Windows:
    """Cut the continuous DataFrame into windows, never crossing `group_cols` boundaries."""
    xs, ys, gs = [], [], []
    for keys, g in df.groupby(list(group_cols), sort=True):
        n = len(g)
        if n < WINDOW:
            continue
        starts = np.arange(0, n - WINDOW + 1, STEP)
        idx = starts[:, None] + np.arange(WINDOW)[None, :]
        data = g[channels].to_numpy(np.float32)
        lab = g[label_col].to_numpy(np.uint8)
        xs.append(data[idx])
        ys.append(label_windows(lab[idx]))
        key = dict(zip(group_cols, keys if isinstance(keys, tuple) else (keys,), strict=True))
        gs.append(np.full(len(starts), key[split_group]))
    return Windows(
        X=np.concatenate(xs),
        y=np.concatenate(ys),
        groups=np.concatenate(gs),
        channels=tuple(channels),
    )
