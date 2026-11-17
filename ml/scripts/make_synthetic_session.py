"""Gera uma sessão sintética no formato da coleira (contratos 4.4–4.5) para testar o labeler.

Uso (de dentro de ml/):
    uv run python scripts/make_synthetic_session.py

Saída em ml/data/raw/synthetic_demo/ (fora do git):
    imu.csv, meta.json, video.mp4 e labels_truth.csv (gabarito, para conferir a rotulagem)

O sinal vem do dataset público (coleira, 50 Hz), montado em trechos de classes conhecidas.
Problemas reais simulados de propósito:
- o vídeo começa VIDEO_LATE_S depois da primeira amostra (offset)
- o relógio da coleira anda CLOCK_DRIFT mais devagar que o do vídeo (deriva, ADR 0003)
- PACKET_LOSS dos pacotes BLE se perdem; `seq` começa perto de 65535 para dar a volta
- 3 batidinhas no início e 3 no fim, visíveis no vídeo (tela pisca) e no sinal (pico)
"""

from __future__ import annotations

import json
from pathlib import Path

import imageio_ffmpeg
import numpy as np
import pandas as pd
from PIL import Image, ImageDraw, ImageFont

from coleira_ml.classes import Behavior
from coleira_ml.public_dataset import ACCEL_RANGE_G, GYRO_RANGE_DPS, load_collar

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "ml" / "data" / "raw" / "synthetic_demo"
FS = 50
FPS = 30
VIDEO_LATE_S = 1.7
CLOCK_DRIFT = 0.003  # 0,3%: exagerado para ficar visível (cristal real ~20–50 ppm)
PACKET_LOSS = 0.005
SEQ0 = 65530
DEVICE_BOOT_MS = 734_000
TAP_TIMES_S = (0.0, 0.45, 0.9)

# (classe, segundos). Chacoalhões são eventos curtos entre estados.
PLAN = [
    (Behavior.PARADO, 6), (Behavior.ANDANDO, 30), (Behavior.CORRENDO, 15),
    (Behavior.PARADO, 10), (Behavior.CHACOALHANDO, 1.5), (Behavior.PARADO, 10),
    (Behavior.ANDANDO, 20), (Behavior.CHACOALHANDO, 1.8), (Behavior.ANDANDO, 10),
    (Behavior.CORRENDO, 10), (Behavior.PARADO, 12),
]  # fmt: skip


def pick_chunks(df: pd.DataFrame, rng: np.random.Generator) -> tuple[np.ndarray, list]:
    """Para cada item do plano, pega um trecho contínuo daquela classe no dataset."""
    seg = ((df.class_id != df.class_id.shift()) | (df.dog_id != df.dog_id.shift())).cumsum()
    runs = (
        df.assign(seg=seg)
        .groupby("seg")
        .agg(
            cls=("class_id", "first"),
            start=("class_id", lambda s: s.index[0]),
            n=("class_id", "size"),
        )
    )
    cols = ["ax", "ay", "az", "gx", "gy", "gz"]
    parts, truth, t = [], [], 0.0
    for cls, secs in PLAN:
        n = int(round(secs * FS))
        cand = runs[(runs.cls == cls) & (runs.n >= n)]
        r = cand.iloc[rng.integers(len(cand))]
        off = rng.integers(0, r.n - n + 1)
        parts.append(df.loc[r.start + off : r.start + off + n - 1, cols].to_numpy())
        truth.append((t, t + n / FS, int(cls)))
        t += n / FS
    return np.concatenate(parts), truth


def add_taps(x: np.ndarray, start_s: float) -> list[float]:
    """Picos curtos e fortes em az (a mão batendo na caixa). Devolve os instantes."""
    times = []
    for dt in TAP_TIMES_S:
        k = int((start_s + dt) * FS)
        x[k : k + 2, 2] += [7.0, -3.0]
        times.append(start_s + dt)
    return times


def main() -> None:
    rng = np.random.default_rng(7)
    df = load_collar(ROOT / "ml" / "data" / "public").reset_index(drop=True)
    body, truth = pick_chunks(df, rng)

    lead, tail = 4.0, 4.0  # segundos sem rótulo para as batidas
    pad_start = np.repeat(body[:1], int(lead * FS), axis=0)
    pad_end = np.repeat(body[-1:], int(tail * FS), axis=0)
    x = np.concatenate([pad_start, body, pad_end])
    truth = [(a + lead, b + lead, c) for a, b, c in truth]
    taps_true = add_taps(x, 2.5) + add_taps(x, len(x) / FS - 2.5)

    # ---- int16 como o IMU entregaria (±16 g / ±2000 dps)
    raw = np.empty_like(x, dtype=np.int16)
    raw[:, :3] = np.clip(np.round(x[:, :3] / ACCEL_RANGE_G * 32768), -32768, 32767)
    raw[:, 3:] = np.clip(np.round(x[:, 3:] / GYRO_RANGE_DPS * 32768), -32768, 32767)

    # ---- pacotes BLE (10 amostras), relógios e perdas
    n = len(raw) - len(raw) % 10
    t_true_ms = np.arange(n) * 1000 / FS
    device_ms = DEVICE_BOOT_MS + t_true_ms * (1 - CLOCK_DRIFT)
    phone_start = 1_763_300_000_000
    rows = []
    for p in range(n // 10):
        if rng.random() < PACKET_LOSS:
            continue
        sl = slice(p * 10, p * 10 + 10)
        recv = phone_start + t_true_ms[sl][-1] + rng.uniform(15, 60)  # latência BLE
        for k in range(sl.start, sl.stop):
            rows.append((round(recv), round(device_ms[k]), (SEQ0 + p) % 65536, *raw[k]))
    OUT.mkdir(parents=True, exist_ok=True)
    csv_cols = ["phone_ts_ms", "device_ms", "seq", "ax", "ay", "az", "gx", "gy", "gz"]
    pd.DataFrame(rows, columns=csv_cols).to_csv(OUT / "imu.csv", index=False)

    meta = {
        "session_id": "synthetic_demo",
        "dog_id": "demo",
        "device_id": "synthetic",
        "start_phone_ts": phone_start,
        "video_file": "video.mp4",
        "video_start_phone_ts_ms": phone_start + int(VIDEO_LATE_S * 1000),
        "accel_range": ACCEL_RANGE_G,
        "gyro_range": GYRO_RANGE_DPS,
        "odr_hz": FS,
        "location": "sintético",
        "surface": "—",
        "notes": "Sessão sintética para testar o labeler. Gabarito em labels_truth.csv.",
        "sync_taps": {},
    }
    (OUT / "meta.json").write_text(json.dumps(meta, indent=2, ensure_ascii=False) + "\n", "utf-8")

    # ---- gabarito no tempo do vídeo (contrato 4.6)
    pd.DataFrame(
        [(round((a - VIDEO_LATE_S) * 1000), round((b - VIDEO_LATE_S) * 1000), c, "gabarito", 1.0)
         for a, b, c in truth],
        columns=["start_ms", "end_ms", "class_id", "annotator", "confidence"],
    ).to_csv(OUT / "labels_truth.csv", index=False)  # fmt: skip

    # ---- vídeo: nome do comportamento + relógio; pisca branco nas batidas
    dur = n / FS - VIDEO_LATE_S
    font_big = ImageFont.load_default(size=56)
    font_small = ImageFont.load_default(size=22)
    w, h = 640, 360
    writer = imageio_ffmpeg.write_frames(
        str(OUT / "video.mp4"), (w, h), fps=FPS, codec="libx264", pix_fmt_out="yuv420p",
        macro_block_size=8, ffmpeg_log_level="error",
    )  # fmt: skip
    writer.send(None)
    for f in range(int(dur * FPS)):
        tv = f / FPS
        tt = tv + VIDEO_LATE_S  # tempo "real" (mesmo relógio do vídeo)
        tap = any(0 <= tt - ts < 0.1 for ts in taps_true)
        cls = next((c for a, b, c in truth if a <= tt < b), None)
        img = Image.new("RGB", (w, h), (245, 245, 245) if tap else (30, 34, 40))
        d = ImageDraw.Draw(img)
        label = "BATIDA!" if tap else (Behavior(cls).name.lower() if cls is not None else "...")
        fg = (20, 20, 20) if tap else (240, 240, 240)
        d.text((w / 2, h / 2), label, font=font_big, anchor="mm", fill=fg)
        d.text((12, 12), f"video {tv:7.2f} s", font=font_small, fill=(150, 150, 150))
        d.text((12, h - 34), "sessao sintetica - coleira", font=font_small, fill=(110, 110, 110))
        writer.send(np.asarray(img).tobytes())
    writer.close()

    print(f"ok: {OUT}")
    print(f"  {len(rows)} amostras, {n // 10} pacotes, vídeo de {dur:.1f} s")
    print(f"  batidas (tempo do vídeo): {[round(t - VIDEO_LATE_S, 2) for t in taps_true]}")


if __name__ == "__main__":
    main()
