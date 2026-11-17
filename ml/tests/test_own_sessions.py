"""Loader for our own labeled sessions: timing must match the labeler (tools/labeler/core.js)."""

from __future__ import annotations

import json

import numpy as np
import pandas as pd
import pytest

from coleira_ml import own_sessions as own


def _write_session(root, sid="s1", dog="rex", *, lose_packet=None, drift=1.0, n_pkts=60):
    """A session with 20 ms samples, the video starting 1000 ms after device_ms 5000,
    the video clock running `drift` × the device clock, and labels in video time."""
    raw = root / "raw" / sid
    raw.mkdir(parents=True)
    rows = []
    for p in range(n_pkts):
        if p == lose_packet:
            continue
        for i in range(10):
            k = p * 10 + i
            dev = 5000 + 20 * k
            rows.append([1_700_000_000_000 + dev, dev, (65530 + p) % 65536,
                         2048, 0, -2048, 3277, 0, 0])  # fmt: skip
    df = pd.DataFrame(rows, columns="phone_ts_ms device_ms seq ax ay az gx gy gz".split())
    df.to_csv(raw / "imu.csv", index=False)
    taps = {
        "start_device_ms": 5000 + 1000,
        "start_video_ms": 0,
        "end_device_ms": 5000 + 11000,
        "end_video_ms": 10000 * drift,
    }
    meta = {"session_id": sid, "dog_id": dog, "accel_range": 16, "gyro_range": 2000,
            "start_phone_ts": 1_700_000_005_000, "sync_taps": taps}  # fmt: skip
    (raw / "meta.json").write_text(json.dumps(meta))
    lab = root / "labels"
    lab.mkdir(exist_ok=True)
    pd.DataFrame(
        {
            "start_ms": [0, 4000],
            "end_ms": [4000, 6000],
            "class_id": [1, 4],
            "annotator": "t",
            "confidence": 1.0,
        }  # fmt: skip
    ).to_csv(lab / f"{sid}.csv", index=False)
    return raw, lab / f"{sid}.csv"


def test_seq_unwrap_and_sample_index_count_lost_packets():
    seq = np.array([65534, 65534, 65535, 65535, 1, 1])  # packet 0 lost (wrap) between
    k = own.sample_index(seq)
    # 10 samples per packet in the format, 2 received per packet here
    assert own.unwrap_seq(seq).tolist() == [65534, 65534, 65535, 65535, 65537, 65537]
    assert k.tolist() == [0, 1, 10, 11, 30, 31]


def test_session_scales_labels_and_segments(tmp_path):
    raw, lab = _write_session(tmp_path, lose_packet=30)
    df = own.load_session(raw, lab)
    assert df.ax.iloc[0] == pytest.approx(1.0)  # 2048 LSB at ±16 g
    assert df.az.iloc[0] == pytest.approx(-1.0)
    assert df.gx.iloc[0] == pytest.approx(3277 * 2000 / 32768)
    assert df.attrs["packet_loss"] == pytest.approx(1 / 60)
    assert df.attrs["odr_hz"] == pytest.approx(50.0)
    assert df.segment.nunique() == 2
    # video 0–4000 ms = device 6000–10000 ms = samples 50..249 → walking
    cls = df.class_id.to_numpy()
    assert (cls[:50] == 255).all()
    assert (cls[50:250] == 1).all()
    assert (cls[250:300] == 4).all()  # shaking from video 4000 (sample 250) to the gap
    assert len(df.day.iloc[0]) == 10  # local YYYY-MM-DD


def test_drift_correction_moves_labels(tmp_path):
    raw, lab = _write_session(tmp_path, drift=1.01)  # video clock 1% fast
    cls = own.load_session(raw, lab).class_id.to_numpy()
    # video 4000 ms = device 6000 + 4000 / 1.01 = 9960.4 ms: sample 249 (not 250) starts the shake
    assert cls[248] == 1 and cls[249] == 4


def test_no_taps_is_skipped_with_a_reason(tmp_path):
    raw, _ = _write_session(tmp_path)
    meta = json.loads((raw / "meta.json").read_text())
    meta["sync_taps"] = {}
    (raw / "meta.json").write_text(json.dumps(meta))
    _write_session(tmp_path, sid="s2", dog="bob")
    df, stats, skipped = own.load_sessions(tmp_path / "raw", tmp_path / "labels")
    assert [s.session_id for s in stats] == ["s2"]
    assert skipped and "sync taps" in skipped[0]


def test_phase1_check_reports_each_criterion(tmp_path):
    for i in range(5):
        _write_session(tmp_path, sid=f"s{i}", dog=f"dog{i}")
    df, stats, _ = own.load_sessions(tmp_path / "raw", tmp_path / "labels")
    check = dict((name, ok) for name, ok, _ in own.phase1_check(df, stats))
    assert check["≥ 5 dogs"] is True
    assert check["≥ 2 h labeled"] is False
    assert check["≥ 3 min still"] is False
