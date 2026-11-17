"""Loader for the public dataset (Vehkaoja et al., 2022): collar sensor only.

It does three things:
1. Reads only the neck (collar) columns and the labels from the ~2 GB CSV.
2. Maps up to 3 simultaneous labels to ONE of our class IDs (contract 4.1).
3. Resamples 100 Hz → 50 Hz (contract 4.2) with anti-aliasing, saturating at our
   IMU's full scale (ADR 0005).

See docs/public-dataset.md for the analysis behind the mapping rules.
"""

from __future__ import annotations

from collections.abc import Iterable
from pathlib import Path

import numpy as np
import pandas as pd
from scipy.signal import resample_poly

from coleira_ml.classes import Behavior

SOURCE_HZ = 100
TARGET_HZ = 50
SENSOR_COLS = ["ax", "ay", "az", "gx", "gy", "gz"]  # accel in g, gyro in °/s
ACCEL_COLS = SENSOR_COLS[:3]
GYRO_COLS = SENSOR_COLS[3:]

# OUR IMU's full scale (contract 4.2 / ADR 0005).
ACCEL_RANGE_G = 16.0
GYRO_RANGE_DPS = 2000.0

# CSV header names (these win over the order given in Data_description.txt).
_CSV_RENAME = {
    "DogID": "dog_id",
    "TestNum": "test_num",
    "t_sec": "t_s",
    "ANeck_x": "ax",
    "ANeck_y": "ay",
    "ANeck_z": "az",
    "GNeck_x": "gx",
    "GNeck_y": "gy",
    "GNeck_z": "gz",
}
_LABEL_COLS = ["Behavior_1", "Behavior_2", "Behavior_3"]
_UNDEFINED = "<undefined>"

# ---------------------------------------------------------------------------
# Label mapping
# ---------------------------------------------------------------------------

# Labels that say nothing about collar motion: simply ignored.
IGNORED = frozenset({_UNDEFINED, "Panting", "Synchronization", "Extra_Synchronization"})
# Context: ignored when a gait is present; on its own (no gait) → unknown.
CONTEXT = frozenset({"Playing", "Carrying object"})
# Distinct movements that are not one of our classes: any occurrence → unknown.
EXCLUDE = frozenset({"Tugging", "Jumping", "Bowing"})

POSTURE = frozenset({"Lying chest", "Sitting", "Standing"})
GAIT = {
    "Walking": Behavior.WALKING,
    "Pacing": Behavior.WALKING,
    "Trotting": Behavior.RUNNING,
    "Galloping": Behavior.RUNNING,
}


def map_label_set(labels: Iterable[str]) -> Behavior:
    """Turn a set of simultaneous dataset labels into one of our classes.

    Priority (the first matching rule wins):
    1. Tugging/Jumping/Bowing → unknown
    2. Shaking → shaking (short, strong event that dominates the signal)
    3. Drinking → drinking
    4. Eating → eating (with a posture or alone); with a gait → unknown
    5. Gait (walking/pacing → walking; trotting/galloping → running);
       two different gaits, or gait + posture → unknown
    6. Playing without a gait → unknown
    7. Posture (lying/sitting/standing) → still
    8. Sniffing alone → unknown: the dataset never labels sniffing together with a
       posture or gait, so still and walking cannot be told apart (ADR 0004)
    9. Nothing → unknown
    """
    s = set(labels) - IGNORED
    gaits = {GAIT[b] for b in s if b in GAIT}
    has_posture = bool(s & POSTURE)

    if s & EXCLUDE:
        return Behavior.UNKNOWN
    if "Shaking" in s:
        return Behavior.SHAKING
    if "Drinking" in s:
        return Behavior.DRINKING
    if "Eating" in s:
        return Behavior.UNKNOWN if gaits else Behavior.EATING
    if gaits:
        if len(gaits) > 1 or has_posture:
            return Behavior.UNKNOWN
        return next(iter(gaits))
    if "Playing" in s:
        return Behavior.UNKNOWN
    if has_posture:
        return Behavior.STILL
    return Behavior.UNKNOWN


def map_behaviors(b1: pd.Series, b2: pd.Series, b3: pd.Series) -> pd.Series:
    """Vectorized version: maps each unique combination only once (there are a few dozen)."""
    key = b1.astype(str) + "|" + b2.astype(str) + "|" + b3.astype(str)
    lookup = {k: int(map_label_set(k.split("|"))) for k in key.unique()}
    return key.map(lookup).astype(np.uint8)


# ---------------------------------------------------------------------------
# Reading and resampling
# ---------------------------------------------------------------------------


def read_collar_csv(csv_path: Path) -> pd.DataFrame:
    """Read the collar sensor only; returns 100 Hz data with `class_id` already mapped."""
    usecols = list(_CSV_RENAME) + _LABEL_COLS
    dtypes = {c: "category" for c in _LABEL_COLS}
    dtypes |= {"DogID": "int16", "TestNum": "int8"}
    dtypes |= {c: "float32" for c in _CSV_RENAME if c[0] in "AG"}
    raw = pd.read_csv(csv_path, usecols=usecols, dtype=dtypes)

    df = raw.rename(columns=_CSV_RENAME)
    df["class_id"] = map_behaviors(raw["Behavior_1"], raw["Behavior_2"], raw["Behavior_3"])
    return df[["dog_id", "test_num", "t_s", *SENSOR_COLS, "class_id"]]


def clip_to_imu_range(
    df: pd.DataFrame,
    accel_g: float = ACCEL_RANGE_G,
    gyro_dps: float = GYRO_RANGE_DPS,
) -> pd.DataFrame:
    """Simulate our IMU's saturation (ADR 0005)."""
    out = df.copy()
    out[ACCEL_COLS] = out[ACCEL_COLS].clip(-accel_g, accel_g)
    out[GYRO_COLS] = out[GYRO_COLS].clip(-gyro_dps, gyro_dps)
    return out


def resample_to_50hz(df: pd.DataFrame) -> pd.DataFrame:
    """100 Hz → 50 Hz, per test (dog_id, test_num).

    Sensors: `resample_poly(1, 2)` applies an FIR low-pass filter before dropping
    samples, so frequencies above 25 Hz do not fold back into the signal.
    Labels: every other sample (boundary error of at most 10 ms).
    """
    parts = []
    for (dog, test), g in df.groupby(["dog_id", "test_num"], sort=True):
        x = resample_poly(g[SENSOR_COLS].to_numpy(np.float64), up=1, down=2, axis=0)
        labels = g["class_id"].to_numpy()[::2]
        t = g["t_s"].to_numpy()[::2]
        out = pd.DataFrame(x.astype(np.float32), columns=SENSOR_COLS)
        out.insert(0, "t_s", t)
        out.insert(0, "test_num", test)
        out.insert(0, "dog_id", dog)
        out["class_id"] = labels
        parts.append(out)
    return pd.concat(parts, ignore_index=True)


def collar_pipeline(df_100hz: pd.DataFrame) -> pd.DataFrame:
    """Saturate → resample → saturate again.

    The second clip exists because the resampling FIR filter rings (Gibbs overshoot)
    at the edges of a saturated stretch and would exceed full scale, which a real IMU's
    output never does.
    """
    return clip_to_imu_range(resample_to_50hz(clip_to_imu_range(df_100hz)))


def load_collar(data_dir: Path, *, use_cache: bool = True) -> pd.DataFrame:
    """Collar data at 50 Hz, saturated to our IMU's range, with `class_id`.

    First call ~30 s; afterwards it reads a parquet cache (<1 s). The cache name includes
    the IMU ranges, so changing contract 4.2 creates a new cache automatically.
    """
    cache = data_dir / f"collar_50hz_{ACCEL_RANGE_G:g}g_{GYRO_RANGE_DPS:g}dps.parquet"
    if use_cache and cache.exists():
        return pd.read_parquet(cache)
    df = collar_pipeline(read_collar_csv(data_dir / "DogMoveData.csv"))
    if use_cache:
        df.to_parquet(cache, index=False)
    return df
