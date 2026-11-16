"""Janelamento (contrato 4.3) e rótulo da janela (ADR 0002).

- 2 s = 100 amostras a 50 Hz, passo de 1 s (50% de sobreposição).
- Janelas nunca cruzam a fronteira entre testes/sessões (`group_cols`).
- Rótulo: classe com ≥ 70% das amostras; para classes de evento (coçar, chacoalhar),
  basta ≥ 50% das amostras OU ≥ 1 s contínuo. Fora disso → 255 (descartada no treino).
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
EVENT_MIN_RUN = 50  # 1 s a 50 Hz
# Obs.: com janela de 100 amostras, "≥ 1 s contínuo" implica "≥ 50%", então hoje o
# critério de sequência é redundante. Ele volta a valer se a janela crescer (ADR 0002).

UNKNOWN = int(Behavior.DESCONHECIDO)
_EVENT_IDS = np.array(sorted(int(b) for b in EVENT_CLASSES), dtype=np.uint8)


@dataclass(frozen=True)
class Windows:
    X: np.ndarray  # (n, WINDOW, canais) float32
    y: np.ndarray  # (n,) uint8, já com 255 para janelas sem rótulo claro
    groups: np.ndarray  # (n,) id do grupo (cachorro / sessão) para GroupKFold
    channels: tuple[str, ...]


def _longest_run(mask: np.ndarray) -> np.ndarray:
    """Maior sequência de True em cada linha de uma matriz booleana (n, W)."""
    n, w = mask.shape
    run = np.zeros(n, dtype=np.int32)
    best = np.zeros(n, dtype=np.int32)
    for j in range(w):
        run = np.where(mask[:, j], run + 1, 0)
        best = np.maximum(best, run)
    return best


def label_windows(labels: np.ndarray) -> np.ndarray:
    """Rótulo de cada janela a partir da matriz (n, WINDOW) de rótulos por amostra."""
    n, w = labels.shape
    out = np.full(n, UNKNOWN, dtype=np.uint8)

    # 1) qualquer classe conhecida (0..6) com maioria forte; 255 nunca "vence"
    counts = np.stack([(labels == c).sum(axis=1) for c in range(N_SUMMARY_CLASSES)], axis=1)
    top = counts.argmax(axis=1)
    strong = counts[np.arange(n), top] >= STATE_MIN_FRACTION * w
    out[strong] = top[strong]

    # 2) classes de evento têm regra mais frouxa e prioridade (eventos curtos não podem sumir)
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
    """Corta o DataFrame contínuo em janelas, sem cruzar fronteiras de `group_cols`."""
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
