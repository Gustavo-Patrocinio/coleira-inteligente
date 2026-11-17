import numpy as np
import pytest

from coleira_ml.breathing import ar1_surrogate, bandpass, dominant_rate, fit_ar1

FS = 100.0


def test_dominant_rate_recovers_breathing_like_sine_on_the_right_channel():
    rng = np.random.default_rng(0)
    t = np.arange(int(30 * FS)) / FS
    x = rng.normal(0, 1.0, size=(len(t), 3))
    x[:, 1] += 3 * np.sin(2 * np.pi * 0.33 * t)  # 20 breaths/min on channel 1
    peak = dominant_rate(bandpass(x, FS, 0.1, 1.5), FS, (0.13, 1.2))
    assert peak.channel == 1
    assert peak.per_min == pytest.approx(20, abs=0.5)
    assert peak.snr > 50


def test_fit_ar1_and_surrogate_match_autocorrelation():
    rng = np.random.default_rng(1)
    like = np.cumsum(rng.normal(size=(5000, 1)), axis=0) * 0.01 + rng.normal(size=(5000, 1))
    phi = fit_ar1(like[:, 0])
    s = ar1_surrogate(like, rng)
    assert s.shape == like.shape
    assert fit_ar1(s[:, 0]) == pytest.approx(phi, abs=0.05)


def test_pure_red_noise_rarely_looks_like_strong_breathing():
    rng = np.random.default_rng(2)
    like = rng.normal(size=(3000, 1))
    snrs = [
        dominant_rate(bandpass(ar1_surrogate(like, rng), FS, 0.1, 1.5), FS, (0.13, 1.2)).snr
        for _ in range(20)
    ]
    sine = np.sin(2 * np.pi * 0.3 * np.arange(3000) / FS)[:, None] * 3 + like
    clean = dominant_rate(bandpass(sine, FS, 0.1, 1.5), FS, (0.13, 1.2)).snr
    assert clean > 3 * np.median(snrs)
