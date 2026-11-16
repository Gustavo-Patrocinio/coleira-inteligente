import numpy as np
import pytest

from coleira_ml.augment import augment, random_rotations


def _windows(n=8, w=100, seed=0):
    rng = np.random.default_rng(seed)
    X = rng.normal(size=(n, w, 7)).astype(np.float32)
    X[:, :, 6] = np.linalg.norm(X[:, :, :3], axis=2)
    return X


def test_rotations_are_proper_rotation_matrices():
    R = random_rotations(50, np.random.default_rng(0))
    eye = np.broadcast_to(np.eye(3), R.shape)
    assert np.allclose(R @ R.transpose(0, 2, 1), eye, atol=1e-6)
    assert np.allclose(np.linalg.det(R), 1.0)


def test_limited_rotation_respects_max_angle():
    R = random_rotations(200, np.random.default_rng(0), max_deg=20)
    angles = np.degrees(np.arccos(np.clip((np.trace(R, axis1=1, axis2=2) - 1) / 2, -1, 1)))
    assert angles.max() <= 20 + 1e-6


def test_rotation_only_preserves_magnitudes_and_is_shared_by_acc_and_gyro():
    X = _windows()
    rng = np.random.default_rng(1)
    out = augment(X, rng, scale_range=(1, 1), accel_noise_g=0, gyro_noise_dps=0)
    # módulos preservados
    for sl in (slice(0, 3), slice(3, 6)):
        assert np.allclose(
            np.linalg.norm(out[:, :, sl], axis=2), np.linalg.norm(X[:, :, sl], axis=2), atol=1e-4
        )
    assert np.allclose(out[:, :, 6], X[:, :, 6], atol=1e-4)

    # mesma rotação: o ângulo entre o vetor de aceleração e o de giro não muda
    def cos(a, g):
        return (a * g).sum(-1) / (np.linalg.norm(a, axis=-1) * np.linalg.norm(g, axis=-1))

    assert np.allclose(cos(out[..., :3], out[..., 3:6]), cos(X[..., :3], X[..., 3:6]), atol=1e-4)


def test_augment_does_not_modify_input_and_recomputes_magnitude():
    X = _windows()
    before = X.copy()
    out = augment(X, np.random.default_rng(2))
    assert np.array_equal(X, before)
    assert np.allclose(out[:, :, 6], np.linalg.norm(out[:, :, :3], axis=2), atol=1e-5)


def test_augment_rejects_wrong_channel_count():
    with pytest.raises(ValueError):
        augment(np.zeros((1, 100, 3), np.float32), np.random.default_rng(0))
