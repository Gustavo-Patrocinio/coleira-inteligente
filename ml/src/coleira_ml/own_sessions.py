"""Our own labeled sessions (Phase 1) → the same 50 Hz DataFrame the public loaders return.

Input per session (contracts 4.5–4.6):
    ml/data/raw/<session_id>/imu.csv     phone_ts_ms, device_ms, seq, ax..gz (raw int16)
    ml/data/raw/<session_id>/meta.json   dog_id, accel_range, gyro_range, sync_taps, ...
    ml/data/labels/<session_id>.csv      start_ms, end_ms, class_id, annotator, confidence

The timing is the labeler's (tools/labeler/core.js), so a label lands on the same samples
here as on the screen where it was drawn:
- device time of each sample from a regression of device_ms on the sample index, counting
  the samples of lost packets (ADR 0003: the real ODR is estimated, never assumed);
- video time = a + b × device time, from the start/end sync taps (offset + drift).

Output columns: ax, ay, az (g), gx, gy, gz (dps), class_id (255 = no label), dog_id,
session_id, day (local date of the session), segment (a new one after each packet loss, so
windows never span a gap).
"""

from __future__ import annotations

import json
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path

import numpy as np
import pandas as pd

from coleira_ml.classes import Behavior

SAMPLES_PER_PACKET = 10  # contract 4.4
UNKNOWN = int(Behavior.UNKNOWN)
AXES = ["ax", "ay", "az", "gx", "gy", "gz"]


def unwrap_seq(seq: np.ndarray) -> np.ndarray:
    """uint16 packet counter → monotonic (wraps at 65535)."""
    seq = np.asarray(seq, dtype=np.int64)
    jumps = np.r_[0, (np.diff(seq) < -32768).astype(np.int64)]
    return seq + 65536 * np.cumsum(jumps)


def sample_index(seq: np.ndarray) -> np.ndarray:
    """Global index of each sample, counting the samples of lost packets."""
    useq = unwrap_seq(seq)
    new_pkt = np.r_[True, useq[1:] != useq[:-1]]
    pkt_start = np.flatnonzero(new_pkt)
    pos = np.arange(len(useq)) - np.repeat(pkt_start, np.diff(np.r_[pkt_start, len(useq)]))
    return (useq - useq[0]) * SAMPLES_PER_PACKET + pos


@dataclass(frozen=True)
class Timeline:
    device_ms: np.ndarray  # fitted device time of each received sample
    index: np.ndarray  # global sample index (gaps where packets were lost)
    odr_hz: float
    packet_loss: float


def build_timeline(device_ms: np.ndarray, seq: np.ndarray) -> Timeline:
    k = sample_index(seq).astype(np.float64)
    b, a = np.polyfit(k, np.asarray(device_ms, dtype=np.float64), 1)
    useq = unwrap_seq(seq)
    expected = useq[-1] - useq[0] + 1
    received = 1 + int(np.count_nonzero(useq[1:] != useq[:-1]))
    return Timeline(
        device_ms=a + b * k,
        index=k.astype(np.int64),
        odr_hz=1000.0 / b,
        packet_loss=1.0 - received / expected,
    )


def sync_from_taps(taps: dict | None) -> tuple[float, float]:
    """(a, b) with video_ms = a + b × device_ms. Needs at least the start taps."""
    taps = taps or {}
    if taps.get("start_video_ms") is None or taps.get("start_device_ms") is None:
        raise ValueError("session has no sync taps: align it in the labeler first")
    if taps.get("end_video_ms") is None or taps.get("end_device_ms") is None:
        return taps["start_video_ms"] - taps["start_device_ms"], 1.0
    dd = taps["end_device_ms"] - taps["start_device_ms"]
    if abs(dd) < 1:
        raise ValueError("start and end taps at the same instant")
    b = (taps["end_video_ms"] - taps["start_video_ms"]) / dd
    return taps["start_video_ms"] - b * taps["start_device_ms"], b


def labels_per_sample(video_ms: np.ndarray, labels: pd.DataFrame) -> np.ndarray:
    """Class of each sample from label intervals [start_ms, end_ms); later rows win."""
    out = np.full(len(video_ms), UNKNOWN, dtype=np.uint8)
    for row in labels.itertuples(index=False):
        out[(video_ms >= row.start_ms) & (video_ms < row.end_ms)] = int(row.class_id)
    return out


def load_session(session_dir: Path, labels_csv: Path) -> pd.DataFrame:
    meta = json.loads((session_dir / "meta.json").read_text(encoding="utf-8"))
    imu = pd.read_csv(session_dir / "imu.csv")
    tl = build_timeline(imu.device_ms.to_numpy(), imu.seq.to_numpy())
    a, b = sync_from_taps(meta.get("sync_taps"))
    video_ms = a + b * tl.device_ms
    ka = float(meta.get("accel_range", 16)) / 32768
    kg = float(meta.get("gyro_range", 2000)) / 32768
    df = pd.DataFrame(
        {
            **{c: (imu[c].to_numpy(np.float32) * ka) for c in AXES[:3]},
            **{c: (imu[c].to_numpy(np.float32) * kg) for c in AXES[3:]},
        }
    ).astype(np.float32)
    df["class_id"] = labels_per_sample(video_ms, pd.read_csv(labels_csv))
    df["dog_id"] = str(meta.get("dog_id", "unknown"))
    df["session_id"] = str(meta.get("session_id", session_dir.name))
    start = meta.get("start_phone_ts") or int(imu.phone_ts_ms.iloc[0])
    df["day"] = datetime.fromtimestamp(start / 1000).date().isoformat()
    df["segment"] = np.cumsum(np.r_[0, np.diff(tl.index) != 1])
    df.attrs = {"odr_hz": tl.odr_hz, "packet_loss": tl.packet_loss}
    return df


@dataclass(frozen=True)
class SessionStats:
    session_id: str
    dog_id: str
    day: str
    minutes: float
    labeled_minutes: float
    packet_loss: float
    odr_hz: float


def load_sessions(
    raw_dir: Path, labels_dir: Path, *, only: list[str] | None = None
) -> tuple[pd.DataFrame, list[SessionStats], list[str]]:
    """Every session that has a label file and sync taps. Returns (data, stats, skipped)."""
    frames, stats, skipped = [], [], []
    for d in sorted(p for p in raw_dir.iterdir() if (p / "imu.csv").exists()):
        if not (d / "meta.json").exists():
            skipped.append(f"{d.name}: no meta.json")
            continue
        if only is not None and d.name not in only:
            continue
        lab = labels_dir / f"{d.name}.csv"
        if not lab.exists():
            skipped.append(f"{d.name}: no labels")
            continue
        try:
            df = load_session(d, lab)
        except ValueError as e:
            skipped.append(f"{d.name}: {e}")
            continue
        frames.append(df)
        stats.append(
            SessionStats(
                session_id=df.session_id.iloc[0],
                dog_id=df.dog_id.iloc[0],
                day=df.day.iloc[0],
                minutes=len(df) / 50 / 60,
                labeled_minutes=float((df.class_id != UNKNOWN).sum()) / 50 / 60,
                packet_loss=df.attrs["packet_loss"],
                odr_hz=df.attrs["odr_hz"],
            )
        )
    if not frames:
        raise SystemExit(
            f"no labeled sessions in {raw_dir} (need imu.csv + meta.json with sync taps "
            f"and {labels_dir}/<session_id>.csv)"
        )
    return pd.concat(frames, ignore_index=True), stats, skipped


def minutes_per_class(df: pd.DataFrame) -> dict[int, float]:
    counts = df.class_id.value_counts()
    return {int(c): float(n) / 50 / 60 for c, n in counts.items() if c != UNKNOWN}


def phase1_check(df: pd.DataFrame, stats: list[SessionStats]) -> list[tuple[str, bool, str]]:
    """Phase 1 done criterion: ≥ 2 h labeled, ≥ 5 dogs, ≥ 3 min of each class 0–4,
    packet loss < 1%."""
    labeled_h = sum(s.labeled_minutes for s in stats) / 60
    dogs = {s.dog_id for s in stats}
    per_class = minutes_per_class(df)
    loss = max((s.packet_loss for s in stats), default=0.0)
    out = [
        ("≥ 2 h labeled", labeled_h >= 2, f"{labeled_h:.2f} h"),
        ("≥ 5 dogs", len(dogs) >= 5, f"{len(dogs)} dogs"),
    ]
    for c in range(5):
        m = per_class.get(c, 0.0)
        out.append((f"≥ 3 min {Behavior(c).name.lower()}", m >= 3, f"{m:.1f} min"))
    out.append(("packet loss < 1% (worst session)", loss < 0.01, f"{loss:.2%}"))
    return out


@dataclass(frozen=True)
class OwnWindows:
    X: np.ndarray  # (n, 100, 7) float32: ax..gz, |a|
    y: np.ndarray  # (n,) window label (contract 4.3 rule), 255 = unclear
    dog: np.ndarray
    day: np.ndarray
    session: np.ndarray
    stretch: np.ndarray  # session#segment: consecutive windows with no packet gap

    def subset(self, mask: np.ndarray) -> OwnWindows:
        return OwnWindows(*(getattr(self, f)[mask] for f in self.__dataclass_fields__))


def own_windows(df: pd.DataFrame) -> OwnWindows:
    """2 s windows, 1 s step (contract 4.3), never across sessions or packet gaps.
    Window order inside each stretch is time order (needed to replay smoothing)."""
    from coleira_ml.features import CHANNELS_7, add_acc_magnitude
    from coleira_ml.windows import make_windows

    d = add_acc_magnitude(df)
    d["stretch"] = d.session_id + "#" + d.segment.astype(str).str.zfill(5)
    w = make_windows(d, CHANNELS_7, group_cols=("stretch",), split_group="stretch")
    session = np.array([s.split("#")[0] for s in w.groups])
    info = df.groupby("session_id")[["dog_id", "day"]].first()
    return OwnWindows(
        X=w.X,
        y=w.y,
        dog=info.dog_id.reindex(session).to_numpy(),
        day=info.day.reindex(session).to_numpy(),
        session=session,
        stretch=w.groups,
    )
