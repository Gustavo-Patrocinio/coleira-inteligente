"""Event smoothing port (= firmware smoothing.c) and p_event / n_min calibration."""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

import numpy as np
import pytest

from coleira_ml.events import calibrate, event_score, runs, smooth_sequence

ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / "firmware" / "app"
IDS = [0, 1, 3, 4]


def test_runs():
    assert runs(np.array([0, 4, 4, 0, 4]), 4) == [(1, 3), (4, 5)]
    assert runs(np.array([0, 0]), 4) == []


def test_event_needs_n_min_consecutive_windows():
    p = np.array([[0.9, 0.0, 0.1, 0.0]] * 3 + [[0.2, 0.0, 0.8, 0.0]] * 2 + [[0.9, 0, 0.1, 0]])
    out = smooth_sequence(p, IDS, {3: 2, 4: 1}, p_event=0.6)
    assert out.tolist() == [0, 0, 0, 0, 3, 0]


def test_event_score_counts_overlaps_and_false_alarms():
    true = np.array([0, 4, 4, 0, 0, 0, 4, 0])
    pred = np.array([0, 0, 4, 0, 4, 0, 0, 0])
    s = event_score([(true, pred)], 4, step_s=1800)  # 8 windows of 30 min = 4 h
    assert (s.true_events, s.pred_events, s.hits_true, s.hits_pred) == (2, 2, 1, 1)
    assert s.recall == 0.5 and s.precision == 0.5
    assert s.false_per_hour == pytest.approx(1 / 4)


def test_calibration_finds_the_threshold_that_separates_events():
    rng = np.random.default_rng(0)
    seqs = []
    for _ in range(20):
        true = np.zeros(60, dtype=np.uint8)
        start = rng.integers(5, 50)
        true[start : start + 3] = 4  # 3 s shake
        p = np.zeros((60, 4), dtype=np.float32)
        p[:, 0] = 1
        p[true == 4] = [0.25, 0, 0, 0.75]  # true shakes at 0.75
        noise = rng.choice(np.flatnonzero(true == 0), 2, replace=False)
        p[noise] = [0.45, 0, 0, 0.55]  # isolated false bumps at 0.55
        seqs.append((p, true))
    best = calibrate(seqs, IDS, [3, 4], p_grid=(0.5, 0.7), n_grid=(1, 2))[0]
    assert best.scores[4].f1 == 1.0
    assert best.scores[4].false_per_hour == 0
    assert best.p_event == 0.7 or best.n_min[4] == 2


@pytest.fixture(scope="module")
def host_test(tmp_path_factory) -> Path:
    pytest.importorskip("ziglang")
    exe = tmp_path_factory.mktemp("ev") / ("h.exe" if sys.platform == "win32" else "h")
    cmd = [
        sys.executable, "-m", "ziglang", "cc", "-std=c99", "-O1", "-Wall", "-Werror",
        "-o", str(exe), str(APP / "tests" / "host_test.c"),
        str(APP / "src" / "preprocess.c"), str(APP / "src" / "smoothing.c"),
        str(APP / "src" / "summary_builder.c"), "-lm",
    ]  # fmt: skip
    res = subprocess.run(cmd, capture_output=True, text=True)
    assert res.returncode == 0, res.stderr
    return exe


@pytest.mark.parametrize("p_event,nmin", [(0.6, {3: 2, 4: 1}), (0.4, {3: 3, 4: 2})])
def test_python_smoothing_equals_firmware_c(host_test, tmp_path, p_event, nmin):
    rng = np.random.default_rng(1)
    logits = rng.normal(size=(3000, 4)) * 2
    logits[rng.random(3000) < 0.1, 2:] += 3  # some event-looking windows
    p = np.exp(logits) / np.exp(logits).sum(axis=1, keepdims=True)
    p = p.astype(np.float32)
    fin, fout = tmp_path / "p.bin", tmp_path / "o.bin"
    p.tofile(fin)
    ids = ",".join(map(str, IDS))
    nm = ",".join(str(nmin.get(c, 0)) for c in IDS)
    res = subprocess.run(
        [
            str(host_test),
            "smooth",
            str(fin),
            str(fout),
            str(len(p)),
            "4",
            str(p_event),
            "5",
            ids,
            nm,
        ],  # fmt: skip
        capture_output=True,
    )
    assert res.returncode == 0, res.stderr
    c_out = np.fromfile(fout, dtype=np.uint8)
    py_out = smooth_sequence(p, IDS, nmin, p_event)
    assert (c_out == py_out).all()
    assert len(set(py_out.tolist())) >= 3
