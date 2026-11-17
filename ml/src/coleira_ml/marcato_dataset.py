"""Loader for Marcato et al. (2023), *Inertial sensor dataset for Dog Posture Recognition*.

42 assistance dogs (Labradors, Goldens and crosses), ActiGraph GT9X at 100 Hz on the neck
(on a harness strap), back and chest. We use only the neck IMU (accel + gyro).

Differences from the Vehkaoja dataset that matter here:
- One label per sample (`Position`), no simultaneous labels.
- Transitions were removed by the authors, so time has gaps. Each continuous stretch
  becomes its own `test_num`, so windows never cross a gap.
- The sensor's full scale is already ±16 g / ±2000 dps, the same as ours (ADR 0005).
- Dog IDs are offset by DOG_ID_OFFSET so they never collide with Vehkaoja's IDs.
"""

from __future__ import annotations

from pathlib import Path

import numpy as np
import pandas as pd

from coleira_ml.classes import Behavior
from coleira_ml.public_dataset import SENSOR_COLS, collar_pipeline

DOG_ID_OFFSET = 1000
POSITION_MAP = {
    "standing": Behavior.STILL,
    "sitting": Behavior.STILL,
    "lying down": Behavior.STILL,
    "walking": Behavior.WALKING,
    "body shake": Behavior.SHAKING,
}
_NECK = {
    "Neck.Acc.X": "ax",
    "Neck.Acc.Y": "ay",
    "Neck.Acc.Z": "az",
    "Neck.Gyr.X": "gx",
    "Neck.Gyr.Y": "gy",
    "Neck.Gyr.Z": "gz",
}
_GAP_S = 0.015  # anything longer than one 10 ms sample (plus jitter) starts a new stretch


def read_neck_csv(csv_path: Path) -> pd.DataFrame:
    """Neck IMU at 100 Hz with `dog_id`, `test_num` (continuous stretch) and `class_id`."""
    usecols = ["Timestamp", "Position", "Subject", *_NECK]
    raw = pd.read_csv(csv_path, usecols=usecols, dtype={c: "float32" for c in _NECK})
    ts = pd.to_datetime(raw["Timestamp"])
    codes = {code: DOG_ID_OFFSET + i for i, code in enumerate(sorted(raw["Subject"].unique()))}

    df = raw.rename(columns=_NECK)
    df["dog_id"] = raw["Subject"].map(codes).astype(np.int32)
    dt = ts.groupby(df["dog_id"]).diff().dt.total_seconds()
    new_stretch = dt.isna() | (dt > _GAP_S)
    df["test_num"] = new_stretch.cumsum().astype(np.int32)
    first = ts.groupby(df["test_num"]).transform("min")
    df["t_s"] = (ts - first).dt.total_seconds()
    ids = {k: int(v) for k, v in POSITION_MAP.items()}
    df["class_id"] = raw["Position"].map(ids).fillna(255).astype(np.uint8)
    return df[["dog_id", "test_num", "t_s", *SENSOR_COLS, "class_id"]]


def load_neck(data_dir: Path, *, use_cache: bool = True) -> pd.DataFrame:
    """Neck IMU at 50 Hz, saturated to our IMU's range, with `class_id` (cached as parquet)."""
    cache = data_dir / "neck_50hz.parquet"
    if use_cache and cache.exists():
        return pd.read_parquet(cache)
    df = collar_pipeline(read_neck_csv(data_dir / "df_raw.csv"))
    if use_cache:
        df.to_parquet(cache, index=False)
    return df
