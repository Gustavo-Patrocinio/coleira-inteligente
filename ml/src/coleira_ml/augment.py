"""Data augmentation for IMU windows (training only, never test).

- Random 3D rotation: simulates the collar rotating on the neck or being mounted
  differently. The SAME rotation applies to accelerometer and gyroscope (they are the
  same rigid body); |a| is recomputed, though a rotation does not change it.
- Scale: small gain variation (different sensors, looser collar).
- Small Gaussian noise.

Expected channels: ax, ay, az, gx, gy, gz [, acc_mag], in that order.
"""

from __future__ import annotations

import numpy as np
from scipy.spatial.transform import Rotation


def random_rotations(n: int, rng: np.random.Generator, max_deg: float | None = None) -> np.ndarray:
    """n 3×3 matrices. `max_deg=None` → uniform rotation in SO(3); else up to max_deg degrees."""
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
    """X: (n, W, 6 or 7) → augmented copy, same shape."""
    n, _, c = X.shape
    if c not in (6, 7):
        raise ValueError("expected 6 (ax..gz) or 7 (+acc_mag) channels")
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
