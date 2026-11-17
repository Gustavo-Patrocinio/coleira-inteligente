import numpy as np
import pandas as pd
import pytest

from coleira_ml.classes import Behavior as B
from coleira_ml.public_dataset import (
    SENSOR_COLS,
    clip_to_imu_range,
    collar_pipeline,
    map_behaviors,
    map_label_set,
    read_collar_csv,
    resample_to_50hz,
)

U = "<undefined>"


@pytest.mark.parametrize(
    ("labels", "expected"),
    [
        # postures → still; panting is ignored
        (["Sitting"], B.STILL),
        (["Lying chest", "Panting"], B.STILL),
        # gaits
        (["Walking"], B.WALKING),
        (["Pacing"], B.WALKING),
        (["Trotting"], B.RUNNING),
        # galloping almost always comes with Playing/Carrying object: must not become unknown
        (["Galloping", "Playing"], B.RUNNING),
        (["Carrying object", "Galloping", "Playing"], B.RUNNING),
        # events and Phase 6 classes
        (["Shaking"], B.SHAKING),
        (["Playing", "Shaking"], B.SHAKING),
        (["Drinking"], B.DRINKING),
        (["Eating", "Standing"], B.EATING),
        (["Eating", "Walking"], B.UNKNOWN),
        # unknown
        (["Sniffing"], B.UNKNOWN),  # ADR 0004: cannot tell still from walking
        (["Playing"], B.UNKNOWN),
        (["Playing", "Tugging"], B.UNKNOWN),
        (["Jumping", "Playing"], B.UNKNOWN),
        (["Walking", "Trotting"], B.UNKNOWN),
        (["Standing", "Walking"], B.UNKNOWN),
        ([U, U, U], B.UNKNOWN),
        (["Synchronization"], B.UNKNOWN),
    ],
)
def test_map_label_set(labels, expected):
    assert map_label_set(labels) == expected


def test_map_behaviors_is_order_independent_and_vectorized():
    b1 = pd.Series(["Sitting", U, "Galloping"])
    b2 = pd.Series([U, "Sitting", "Playing"])
    b3 = pd.Series([U, U, U])
    out = map_behaviors(b1, b2, b3)
    assert out.dtype == np.uint8
    assert out.tolist() == [B.STILL, B.STILL, B.RUNNING]


def _fake_100hz(n: int, dog: int, test: int, freq_hz: float) -> pd.DataFrame:
    t = np.arange(n) / 100
    sig = np.sin(2 * np.pi * freq_hz * t).astype(np.float32)
    df = pd.DataFrame({c: sig for c in SENSOR_COLS})
    df.insert(0, "t_s", t)
    df.insert(0, "test_num", np.int8(test))
    df.insert(0, "dog_id", np.int16(dog))
    df["class_id"] = np.where(t < n / 200, B.STILL, B.WALKING).astype(np.uint8)
    return df


def test_resample_halves_length_per_test_and_keeps_labels():
    df = pd.concat([_fake_100hz(1000, 1, 1, 2.0), _fake_100hz(601, 2, 1, 2.0)])
    out = resample_to_50hz(df)
    assert (out.groupby("dog_id").size() == [500, 301]).all()
    first = out[out.dog_id == 1]
    assert first.class_id.iloc[0] == B.STILL
    assert first.class_id.iloc[-1] == B.WALKING
    assert np.allclose(np.diff(first.t_s), 0.02)


def test_resample_keeps_low_freq_and_blocks_alias():
    # 2 Hz (stride) passes almost untouched; 40 Hz (> 25 Hz Nyquist) must not leak in
    low = resample_to_50hz(_fake_100hz(2000, 1, 1, 2.0))
    high = resample_to_50hz(_fake_100hz(2000, 1, 1, 40.0))
    core = slice(100, -100)  # skip filter edge transients
    assert low.ax.iloc[core].abs().max() > 0.95
    assert high.ax.iloc[core].abs().max() < 0.05


def test_clip_to_imu_range_saturates_like_our_sensor():
    df = pd.DataFrame({c: [-30.0, 0.5, 30.0] for c in SENSOR_COLS})
    df[["gx", "gy", "gz"]] *= 100  # -3000, 50, 3000 dps
    out = clip_to_imu_range(df, accel_g=16, gyro_dps=2000)
    assert out.ax.tolist() == [-16, 0.5, 16]
    assert out.gz.tolist() == [-2000, 50, 2000]
    assert df.ax.iloc[0] == -30  # input is not modified


def test_collar_pipeline_never_exceeds_full_scale():
    # ±30 g square wave: saturates, and the resampling filter would overshoot
    df = _fake_100hz(2000, 1, 1, 3.0)
    df[SENSOR_COLS] = np.sign(df[SENSOR_COLS]) * 30.0
    df[["gx", "gy", "gz"]] *= 100
    out = collar_pipeline(df)
    assert out[["ax", "ay", "az"]].abs().max().max() <= 16
    assert out[["gx", "gy", "gz"]].abs().max().max() <= 2000


def test_read_collar_csv_uses_neck_columns(tmp_path):
    header = (
        "DogID,TestNum,t_sec,ABack_x,ABack_y,ABack_z,ANeck_x,ANeck_y,ANeck_z,"
        "GBack_x,GBack_y,GBack_z,GNeck_x,GNeck_y,GNeck_z,Task,"
        "Behavior_1,Behavior_2,Behavior_3,PointEvent"
    )
    row = f"16,1,0,9,9,9,0.1,0.2,0.3,9,9,9,1,2,3,<undefined>,Walking,{U},{U},{U}"
    csv = tmp_path / "DogMoveData.csv"
    csv.write_text(f"{header}\n{row}\n")
    df = read_collar_csv(csv)
    assert df.loc[0, SENSOR_COLS].tolist() == pytest.approx([0.1, 0.2, 0.3, 1, 2, 3])
    assert df.loc[0, "class_id"] == B.WALKING
