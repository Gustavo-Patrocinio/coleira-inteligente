"""Data augmentation para janelas do IMU (só no treino, nunca no teste).

- Rotação 3D aleatória: simula a coleira girando no pescoço ou montada de outro jeito.
  A MESMA rotação vale para acelerômetro e giroscópio (são o mesmo corpo rígido), e a
  magnitude |a| é recalculada, mas como rotação não muda módulo, ela fica igual.
- Escala: variação pequena de ganho (sensores diferentes, coleira mais frouxa).
- Ruído gaussiano pequeno.

Canais esperados: ax, ay, az, gx, gy, gz [, acc_mag], nessa ordem.
"""

from __future__ import annotations

import numpy as np
from scipy.spatial.transform import Rotation


def random_rotations(n: int, rng: np.random.Generator, max_deg: float | None = None) -> np.ndarray:
    """n matrizes 3×3. `max_deg=None` → rotação uniforme em SO(3); senão, até max_deg graus."""
    if max_deg is None:
        return Rotation.random(n, random_state=rng).as_matrix()
    axes = rng.normal(size=(n, 3))
    axes /= np.linalg.norm(axes, axis=1, keepdims=True)
    angles = np.deg2rad(rng.uniform(-max_deg, max_deg, size=(n, 1)))
    return Rotation.from_rotvec(axes * angles).as_matrix()


def augment(
    X: np.ndarray,
    rng: np.random.Generator,
    *,
    rotate_max_deg: float | None = None,
    scale_range: tuple[float, float] = (0.9, 1.1),
    accel_noise_g: float = 0.01,
    gyro_noise_dps: float = 1.0,
) -> np.ndarray:
    """X: (n, W, 6 ou 7) → cópia aumentada, mesmo formato."""
    n, _, c = X.shape
    if c not in (6, 7):
        raise ValueError("esperado 6 (ax..gz) ou 7 (+acc_mag) canais")
    out = X.astype(np.float32, copy=True)

    R = random_rotations(n, rng, rotate_max_deg).astype(np.float32)  # (n, 3, 3)
    out[:, :, 0:3] = np.einsum("nij,nwj->nwi", R, out[:, :, 0:3])
    out[:, :, 3:6] = np.einsum("nij,nwj->nwi", R, out[:, :, 3:6])

    scale = rng.uniform(*scale_range, size=(n, 1, 1)).astype(np.float32)
    out[:, :, 0:6] *= scale
    out[:, :, 0:3] += rng.normal(0, accel_noise_g, size=out[:, :, 0:3].shape)
    out[:, :, 3:6] += rng.normal(0, gyro_noise_dps, size=out[:, :, 3:6].shape)

    if c == 7:
        out[:, :, 6] = np.linalg.norm(out[:, :, 0:3], axis=2)
    return out
