"""Per-window features for the baseline (Random Forest) and for the MLC tree.

"Full" set (per channel): mean, std, min, max, energy, dominant frequency.
"MLC" set: only what ST's Machine Learning Core computes in hardware (mean, variance,
energy, peak-to-peak, min, max). No FFT, because the MLC cannot do FFT.
"""

from __future__ import annotations

import numpy as np
import pandas as pd

CHANNELS_7 = ["ax", "ay", "az", "gx", "gy", "gz", "acc_mag"]  # contract 4.3


def add_acc_magnitude(df: pd.DataFrame) -> pd.DataFrame:
    """7th channel: |a|. Orientation-independent, which helps when the collar rotates."""
    out = df.copy()
    out["acc_mag"] = np.sqrt(out.ax**2 + out.ay**2 + out.az**2).astype(np.float32)
    return out


def dominant_freq(X: np.ndarray, fs: float) -> np.ndarray:
    """Frequency of the largest spectral peak (excluding DC). X: (n, W, C) → (n, C) in Hz."""
    spec = np.abs(np.fft.rfft(X - X.mean(axis=1, keepdims=True), axis=1))
    k = spec[:, 1:, :].argmax(axis=1) + 1
    return (k * fs / X.shape[1]).astype(np.float32)


def window_features(
    X: np.ndarray, channels: list[str] | tuple[str, ...], fs: float, kind: str = "full"
) -> tuple[np.ndarray, list[str]]:
    """X: (n, W, C) → (n, F) matrix and feature names."""
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
        raise ValueError(f"unknown kind: {kind}")

    names = [f"{ch}_{f}" for f in feats for ch in channels]
    return np.concatenate(list(feats.values()), axis=1).astype(np.float32), names
