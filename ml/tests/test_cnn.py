"""Testes rápidos da CNN: formato, treino em dado trivial e fidelidade do int8."""

import numpy as np
import pytest

cnn = pytest.importorskip("coleira_ml.cnn")


def _toy(n=600, seed=0):
    # classe 0: parado (ruído pequeno), classe 1: oscilação forte em ax
    rng = np.random.default_rng(seed)
    y = rng.integers(0, 2, size=n)
    t = np.arange(100) / 50
    X = rng.normal(0, 0.02, size=(n, 100, 7)).astype(np.float32)
    X[y == 1, :, 0] += np.sin(2 * np.pi * 2 * t) * 1.0
    X[:, :, 6] = np.linalg.norm(X[:, :, :3], axis=2)
    return X, y


def test_build_cnn_shape_and_size():
    m = cnn.build_cnn(n_classes=3)
    assert m.output.shape[-1] == 3
    assert m.count_params() < 10_000  # cabe com folga em < 64 KB


def test_balanced_class_weight():
    w = cnn.balanced_class_weight(np.array([0, 0, 0, 1]))
    assert w[1] == pytest.approx(3 * w[0])


def test_train_and_int8_agree_on_easy_problem():
    X, y = _toy()
    m = cnn.train_cnn(X, y, n_classes=2, epochs=5)
    pred_f = cnn.predict_float(m, X)
    assert (pred_f == y).mean() > 0.95
    tfl = cnn.to_tflite_int8(m, X)
    assert len(tfl) < 64 * 1024
    pred_q = cnn.predict_int8(tfl, X)
    assert (pred_q == pred_f).mean() > 0.95


def test_activation_ram_estimate():
    m = cnn.build_cnn(n_classes=3)
    # maior par: conv1 (100×16) + maxpool1 (50×16) = 2400, maior que entrada+conv1 (2300)
    assert cnn.activation_ram_estimate(m) == 100 * 16 + 50 * 16
