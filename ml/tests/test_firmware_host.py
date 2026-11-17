"""Firmware ↔ training consistency, tested on the PC.

The firmware's pure-C logic (firmware/app/src/preprocess.c, smoothing.c) is compiled with
zig cc and checked here:
- smoothing and ring buffer behave as ADR 0002 / contract 4.3 say;
- C preprocessing produces the same int8 model input as the Python training path;
- the int8 model gives the same class on C-preprocessed and Python-preprocessed windows.
"""

from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

import numpy as np
import pytest

ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / "firmware" / "app"
CONFIG = APP / "src" / "model" / "model_config.h"


@pytest.fixture(scope="session")
def host_test(tmp_path_factory) -> Path:
    pytest.importorskip("ziglang")
    exe = tmp_path_factory.mktemp("host") / (
        "host_test.exe" if sys.platform == "win32" else "host_test"
    )
    cmd = [
        sys.executable, "-m", "ziglang", "cc", "-std=c99", "-O1", "-Wall", "-Werror",
        "-o", str(exe), str(APP / "tests" / "host_test.c"),
        str(APP / "src" / "preprocess.c"), str(APP / "src" / "smoothing.c"), "-lm",
    ]  # fmt: skip
    res = subprocess.run(cmd, capture_output=True, text=True)
    assert res.returncode == 0, res.stderr
    return exe


def _config() -> dict:
    text = CONFIG.read_text()

    def num(name):
        return float(re.search(rf"#define {name}\s+\(?(-?[\d.]+)", text).group(1))

    scales = re.search(r"#define MODEL_CH_SCALE\s+\{([^}]*)\}", text).group(1)
    return {
        "in_scale": num("MODEL_IN_SCALE"),
        "in_zp": int(num("MODEL_IN_ZERO_POINT")),
        "accel_fs": num("MODEL_ACCEL_FS_G"),
        "gyro_fs": num("MODEL_GYRO_FS_DPS"),
        "ch_scale": np.array([float(s.strip().rstrip("f")) for s in scales.split(",")]),
    }


def _python_preprocess(raw: np.ndarray, cfg: dict) -> np.ndarray:
    """The training path (cnn.scale_inputs + int8 quantization), starting from raw int16."""
    phys = np.empty((raw.shape[0], 7), dtype=np.float32)
    phys[:, :3] = raw[:, :3].astype(np.float32) * np.float32(cfg["accel_fs"] / 32768)
    phys[:, 3:6] = raw[:, 3:6].astype(np.float32) * np.float32(cfg["gyro_fs"] / 32768)
    phys[:, 6] = np.linalg.norm(phys[:, :3], axis=1)
    x = phys / cfg["ch_scale"].astype(np.float32)
    return np.clip(np.round(x / np.float32(cfg["in_scale"])) + cfg["in_zp"], -128, 127).astype(
        np.int8
    )


def _c_preprocess(exe: Path, raw: np.ndarray, tmp_path: Path) -> np.ndarray:
    fin, fout = tmp_path / "raw.bin", tmp_path / "q.bin"
    raw.astype("<i2").tofile(fin)
    res = subprocess.run(
        [str(exe), "preprocess", str(fin), str(fout), str(len(raw))], capture_output=True
    )
    assert res.returncode == 0, res.stderr
    return np.fromfile(fout, dtype=np.int8).reshape(len(raw), 7)


@pytest.mark.parametrize("mode", ["smoothing", "ring"])
def test_c_logic(host_test, mode):
    res = subprocess.run([str(host_test), mode], capture_output=True, text=True)
    assert res.returncode == 0, res.stderr


def test_generated_config_matches_training_constants():
    from coleira_ml.cnn import INPUT_SCALE
    from coleira_ml.public_dataset import ACCEL_RANGE_G, GYRO_RANGE_DPS

    cfg = _config()
    assert np.allclose(cfg["ch_scale"], INPUT_SCALE)
    assert cfg["accel_fs"] == ACCEL_RANGE_G and cfg["gyro_fs"] == GYRO_RANGE_DPS


def test_c_preprocessing_matches_python(host_test, tmp_path):
    rng = np.random.default_rng(0)
    raw = (
        np.concatenate(
            [
                rng.normal(0, 3000, size=(5000, 6)),  # typical activity
                rng.uniform(-32768, 32767, size=(2000, 6)),  # full range incl. saturation
                np.tile([0, 0, 2048, 0, 0, 0], (100, 1)),  # still, 1 g on z
            ]
        )
        .round()
        .clip(-32768, 32767)
        .astype(np.int16)
    )
    c = _c_preprocess(host_test, raw, tmp_path)
    py = _python_preprocess(raw, _config())
    diff = np.abs(c.astype(int) - py.astype(int))
    # float32 rounding at exact .5 boundaries may differ by one step, nothing more
    assert diff.max() <= 1
    assert (diff > 0).mean() < 0.001


def test_int8_model_agrees_on_c_and_python_inputs(host_test, tmp_path):
    tflite = ROOT / "ml" / "models" / "cnn_multi_int8.tflite"
    data = ROOT / "ml" / "data" / "public" / "collar_50hz_16g_2000dps.parquet"
    if not tflite.exists() or not data.exists():
        pytest.skip("needs the trained model and the public dataset cache")
    tf = pytest.importorskip("tensorflow")
    import pandas as pd

    from coleira_ml.windows import make_windows

    df = pd.read_parquet(data)
    df = df[df.dog_id.isin(sorted(df.dog_id.unique())[:6])]
    w = make_windows(df, ["ax", "ay", "az", "gx", "gy", "gz"])
    w_x = w.X[w.y != 255][::5][:300]
    raw = np.empty_like(w_x, dtype=np.int16)
    raw[..., :3] = np.clip(np.round(w_x[..., :3] / 16 * 32768), -32768, 32767)
    raw[..., 3:] = np.clip(np.round(w_x[..., 3:] / 2000 * 32768), -32768, 32767)

    c_in = _c_preprocess(host_test, raw.reshape(-1, 6), tmp_path).reshape(len(raw), 100, 7)
    py_in = np.stack([_python_preprocess(r, _config()) for r in raw])

    it = tf.lite.Interpreter(model_path=str(tflite))
    inp, out = it.get_input_details()[0], it.get_output_details()[0]
    it.resize_tensor_input(inp["index"], c_in.shape)
    it.allocate_tensors()

    def classify(x):
        it.set_tensor(inp["index"], x)
        it.invoke()
        return it.get_tensor(out["index"]).argmax(axis=1)

    agree = (classify(c_in) == classify(py_in)).mean()
    assert agree >= 0.99, agree
