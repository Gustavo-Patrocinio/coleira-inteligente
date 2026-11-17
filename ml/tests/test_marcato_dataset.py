import numpy as np

from coleira_ml.classes import Behavior as B
from coleira_ml.marcato_dataset import DOG_ID_OFFSET, read_neck_csv
from coleira_ml.public_dataset import SENSOR_COLS

HEADER = (
    "Timestamp,Neck.Acc.X,Neck.Acc.Y,Neck.Acc.Z,Neck.Gyr.X,Neck.Gyr.Y,Neck.Gyr.Z,Position,Subject"
)


def _rows(subject, n, position, t0_ms=0):
    out = []
    for i in range(n):
        ms = t0_ms + i * 10
        ts = f"2019-05-20 14:46:{28 + ms // 1000:02d}.{ms % 1000:03d}"
        out.append(f"{ts},0.1,0.2,0.9,1,2,3,{position},{subject}")
    return out


def test_read_neck_csv_maps_labels_splits_gaps_and_offsets_ids(tmp_path):
    lines = [HEADER]
    lines += _rows("04-02-B", 50, "standing")  # 0.00–0.49 s
    lines += _rows("04-02-B", 30, "walking", t0_ms=2000)  # gap → new stretch
    lines += _rows("04-01-A", 20, "body shake")  # another dog
    csv = tmp_path / "df_raw.csv"
    csv.write_text("\n".join(lines) + "\n")

    df = read_neck_csv(csv)
    assert list(df.columns) == ["dog_id", "test_num", "t_s", *SENSOR_COLS, "class_id"]
    # IDs: sorted codes → 04-01-A = 1000, 04-02-B = 1001
    assert set(df.dog_id) == {DOG_ID_OFFSET, DOG_ID_OFFSET + 1}
    assert df.test_num.nunique() == 3  # stretch 1, stretch after the gap, other dog
    assert df.groupby("test_num").t_s.min().eq(0).all()
    assert np.allclose(df[df.class_id == B.WALKING].t_s.diff().dropna(), 0.01)
    assert set(df.class_id) == {B.STILL, B.WALKING, B.SHAKING}
