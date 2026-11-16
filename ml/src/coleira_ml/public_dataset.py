"""Loader do dataset público (Vehkaoja et al., 2022): só o sensor da coleira.

Faz três coisas:
1. Lê do CSV de ~2 GB apenas as colunas do pescoço (coleira) e os rótulos.
2. Mapeia os até 3 rótulos simultâneos para UM class_id nosso (contrato 4.1).
3. Reamostra de 100 Hz para 50 Hz (contrato 4.2), com filtro anti-aliasing.

Ver docs/dataset-publico.md para a análise que justifica as regras de mapeamento.
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
SENSOR_COLS = ["ax", "ay", "az", "gx", "gy", "gz"]  # acel. em g, giro em °/s
ACCEL_COLS = SENSOR_COLS[:3]
GYRO_COLS = SENSOR_COLS[3:]

# Fundo de escala do NOSSO IMU (contrato 4.2 / ADR 0005).
ACCEL_RANGE_G = 16.0
GYRO_RANGE_DPS = 2000.0

# Nomes do cabeçalho do CSV (valem estes, não a ordem do Data_description.txt).
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
# Mapeamento de rótulos
# ---------------------------------------------------------------------------

# Rótulos que não dizem nada sobre o movimento da coleira: simplesmente ignorados.
IGNORED = frozenset({_UNDEFINED, "Panting", "Synchronization", "Extra_Synchronization"})
# Contexto: ignorado quando há andadura; sozinho (sem andadura) → desconhecido.
CONTEXT = frozenset({"Playing", "Carrying object"})
# Movimentos próprios que não são classe nossa: qualquer ocorrência → desconhecido.
EXCLUDE = frozenset({"Tugging", "Jumping", "Bowing"})

POSTURE = frozenset({"Lying chest", "Sitting", "Standing"})
GAIT = {
    "Walking": Behavior.ANDANDO,
    "Pacing": Behavior.ANDANDO,
    "Trotting": Behavior.CORRENDO,
    "Galloping": Behavior.CORRENDO,
}


def map_label_set(labels: Iterable[str]) -> Behavior:
    """Converte um conjunto de rótulos simultâneos do dataset em uma classe nossa.

    Prioridade (a primeira regra que casar vence):
    1. Tugging/Jumping/Bowing → desconhecido
    2. Shaking → chacoalhando (evento curto e forte, domina o sinal)
    3. Drinking → bebendo
    4. Eating → comendo (com postura ou sozinho); com andadura → desconhecido
    5. Andadura (walking/pacing → andando; trotting/galloping → correndo);
       duas andaduras diferentes ou andadura + postura → desconhecido
    6. Playing sem andadura → desconhecido
    7. Postura (deitado/sentado/em pé) → parado
    8. Sniffing sozinho → desconhecido: o dataset nunca rotula farejar junto com
       postura ou andadura, então não dá para separar parado de andando (ADR 0004)
    9. Nada → desconhecido
    """
    s = set(labels) - IGNORED
    gaits = {GAIT[b] for b in s if b in GAIT}
    has_posture = bool(s & POSTURE)

    if s & EXCLUDE:
        return Behavior.DESCONHECIDO
    if "Shaking" in s:
        return Behavior.CHACOALHANDO
    if "Drinking" in s:
        return Behavior.BEBENDO
    if "Eating" in s:
        return Behavior.DESCONHECIDO if gaits else Behavior.COMENDO
    if gaits:
        if len(gaits) > 1 or has_posture:
            return Behavior.DESCONHECIDO
        return next(iter(gaits))
    if "Playing" in s:
        return Behavior.DESCONHECIDO
    if has_posture:
        return Behavior.PARADO
    return Behavior.DESCONHECIDO


def map_behaviors(b1: pd.Series, b2: pd.Series, b3: pd.Series) -> pd.Series:
    """Versão vetorizada: mapeia cada combinação única uma vez só (há poucas dezenas)."""
    key = b1.astype(str) + "|" + b2.astype(str) + "|" + b3.astype(str)
    lookup = {k: int(map_label_set(k.split("|"))) for k in key.unique()}
    return key.map(lookup).astype(np.uint8)


# ---------------------------------------------------------------------------
# Leitura e reamostragem
# ---------------------------------------------------------------------------


def read_collar_csv(csv_path: Path) -> pd.DataFrame:
    """Lê só a coleira e devolve 100 Hz com `class_id` já mapeado."""
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
    """Simula a saturação do nosso IMU (ADR 0005). Aplicar ANTES de reamostrar,
    porque no sensor real a saturação acontece antes do filtro digital."""
    out = df.copy()
    out[ACCEL_COLS] = out[ACCEL_COLS].clip(-accel_g, accel_g)
    out[GYRO_COLS] = out[GYRO_COLS].clip(-gyro_dps, gyro_dps)
    return out


def resample_to_50hz(df: pd.DataFrame) -> pd.DataFrame:
    """100 Hz → 50 Hz por teste (dog_id, test_num).

    Sensores: `resample_poly(1, 2)` aplica um filtro passa-baixa FIR antes de
    descartar amostras, então frequências acima de 25 Hz não "dobram" no sinal.
    Rótulos: amostra sim, amostra não (erro de borda de no máximo 10 ms).
    """
    parts = []
    for (dog, test), g in df.groupby(["dog_id", "test_num"], sort=True):
        x = resample_poly(g[SENSOR_COLS].to_numpy(np.float64), up=1, down=2, axis=0)
        labels = g["class_id"].to_numpy()[::2]
        t = g["t_s"].to_numpy()[::2]
        out = pd.DataFrame(x.astype(np.float32), columns=SENSOR_COLS)
        out.insert(0, "t_s", t)
        out.insert(0, "test_num", np.int8(test))
        out.insert(0, "dog_id", np.int16(dog))
        out["class_id"] = labels
        parts.append(out)
    return pd.concat(parts, ignore_index=True)


def collar_pipeline(df_100hz: pd.DataFrame) -> pd.DataFrame:
    """Satura → reamostra → satura de novo.

    O segundo clip existe porque o filtro FIR da reamostragem "repica" (overshoot de
    Gibbs) nas bordas de um trecho saturado e passaria do fundo de escala, coisa que a
    saída de um IMU real nunca faz.
    """
    return clip_to_imu_range(resample_to_50hz(clip_to_imu_range(df_100hz)))


def load_collar(data_dir: Path, *, use_cache: bool = True) -> pd.DataFrame:
    """Coleira a 50 Hz, saturada na faixa do nosso IMU, com `class_id`.

    Primeira chamada ~30 s; depois lê do cache parquet (<1 s). O nome do cache inclui
    as faixas do IMU, então mudar o contrato 4.2 gera um cache novo automaticamente.
    """
    cache = data_dir / f"collar_50hz_{ACCEL_RANGE_G:g}g_{GYRO_RANGE_DPS:g}dps.parquet"
    if use_cache and cache.exists():
        return pd.read_parquet(cache)
    df = collar_pipeline(read_collar_csv(data_dir / "DogMoveData.csv"))
    if use_cache:
        df.to_parquet(cache, index=False)
    return df
