"""Respiration from collar IMU windows (experimental, see docs/product/indicators.md).

Idea: while the dog is still, breathing moves the neck slightly and periodically. For each
window we look for the strongest spectral peak inside a breathing band, on every channel,
and keep the channel where that peak stands out most (SNR = peak power / median power of
the rest of the band).

A peak always exists, even in pure noise, so a result only counts if it beats a null
model: AR(1) "red noise" surrogates with the same lag-1 autocorrelation as the real window
(slow drift and posture shifts look like red noise, not like a clean oscillation).
"""

from __future__ import annotations

from dataclasses import dataclass

import numpy as np
from scipy.signal import butter, detrend, sosfiltfilt, welch


@dataclass(frozen=True)
class RatePeak:
    freq_hz: float
    snr: float
    channel: int

    @property
    def per_min(self) -> float:
        return self.freq_hz * 60


def bandpass(x: np.ndarray, fs: float, lo: float, hi: float, order: int = 2) -> np.ndarray:
    sos = butter(order, [lo, hi], btype="band", fs=fs, output="sos")
    return sosfiltfilt(sos, x, axis=0)


def dominant_rate(
    window: np.ndarray, fs: float, band: tuple[float, float], exclude_hz: float = 0.08
) -> RatePeak:
    """Strongest in-band peak across channels. window: (n, channels)."""
    n = window.shape[0]
    best = RatePeak(float("nan"), -np.inf, -1)
    for c in range(window.shape[1]):
        y = detrend(window[:, c])
        f, p = welch(y, fs=fs, nperseg=n, nfft=8 * n, window="hann")
        m = (f >= band[0]) & (f <= band[1])
        k = int(np.argmax(p[m]))
        fpk = float(f[m][k])
        ref = m & (np.abs(f - fpk) > exclude_hz)
        snr = float(p[m][k] / np.median(p[ref]))
        if snr > best.snr:
            best = RatePeak(fpk, snr, c)
    return best


def fit_ar1(x: np.ndarray) -> float:
    """Lag-1 autocorrelation coefficient of a 1D signal (after removing the mean)."""
    x = x - x.mean()
    return float(np.dot(x[1:], x[:-1]) / np.dot(x, x))


def ar1_surrogate(like: np.ndarray, rng: np.random.Generator) -> np.ndarray:
    """Red-noise window with each channel's AR(1) coefficient matching `like` (n, channels)."""
    n, ch = like.shape
    out = np.empty((n, ch))
    for c in range(ch):
        phi = min(fit_ar1(like[:, c]), 0.9999)
        e = rng.normal(size=n)
        y = np.empty(n)
        y[0] = e[0]
        for t in range(1, n):
            y[t] = phi * y[t - 1] + e[t]
        out[:, c] = y
    return out
