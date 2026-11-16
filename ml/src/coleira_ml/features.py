"""Features por janela para o baseline (Random Forest) e para a árvore do MLC.

Conjunto "completo" (por canal): média, desvio, mín, máx, energia, frequência dominante.
Conjunto "MLC": só o que o Machine Learning Core da ST calcula em hardware (média,
variância, energia, pico a pico, mín, máx). Sem FFT, já que o MLC não faz FFT.
"""

from __future__ import annotations

import numpy as np
import pandas as pd

CHANNELS_7 = ["ax", "ay", "az", "gx", "gy", "gz", "acc_mag"]  # contrato 4.3


def add_acc_magnitude(df: pd.DataFrame) -> pd.DataFrame:
    """7º canal: |a|. Não depende da orientação, o que ajuda quando a coleira gira."""
    out = df.copy()
    out["acc_mag"] = np.sqrt(out.ax**2 + out.ay**2 + out.az**2).astype(np.float32)
    return out


def dominant_freq(X: np.ndarray, fs: float) -> np.ndarray:
    """Frequência do maior pico do espectro (sem o DC). X: (n, W, C) → (n, C) em Hz."""
    spec = np.abs(np.fft.rfft(X - X.mean(axis=1, keepdims=True), axis=1))
    k = spec[:, 1:, :].argmax(axis=1) + 1
    return (k * fs / X.shape[1]).astype(np.float32)


def window_features(
    X: np.ndarray, channels: list[str] | tuple[str, ...], fs: float, kind: str = "full"
) -> tuple[np.ndarray, list[str]]:
    """X: (n, W, C) → matriz (n, F) e nomes das features."""
    feats: dict[str, np.ndarray] = {
        "mean": X.mean(axis=1),
        "min": X.min(axis=1),
        "max": X.max(axis=1),
        "energy": (X**2).mean(axis=1),
    }
    if kind == "full":
        feats["std"] = X.std(axis=1)
        feats["domfreq"] = dominant_freq(X, fs)
    elif kind == "mlc":
        feats["var"] = X.var(axis=1)
        feats["p2p"] = feats["max"] - feats["min"]
    else:
        raise ValueError(f"kind desconhecido: {kind}")

    names = [f"{ch}_{f}" for f in feats for ch in channels]
    return np.concatenate(list(feats.values()), axis=1).astype(np.float32), names
