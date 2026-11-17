"""Small 1D CNN (Keras) + conversion to TFLite int8 (ADR 0006).

Architecture (Phase 0 checklist):
    input (100, 7) → 3× [Conv1D k=5 → ReLU → MaxPool 2] (16/32/32 filters)
                   → GlobalAveragePooling → Dense softmax

The output is softmax because contract 4.3 asks for per-class probabilities (event
detection in ADR 0002 uses a probability threshold).
"""

from __future__ import annotations

import os
import tempfile
from collections.abc import Callable

import numpy as np

os.environ.setdefault("TF_CPP_MIN_LOG_LEVEL", "2")
import keras  # noqa: E402
import tensorflow as tf  # noqa: E402
from keras import layers  # noqa: E402

# Fixed per-channel scale (ax, ay, az, gx, gy, gz, |a|), applied before the network.
# Fixed (not computed from data) so the firmware uses the same constants. Puts the
# channels on the same order of magnitude: acceleration in g, gyro in hundreds of °/s.
INPUT_SCALE = np.array([1, 1, 1, 100, 100, 100, 1], dtype=np.float32)


def scale_inputs(X: np.ndarray) -> np.ndarray:
    return (X / INPUT_SCALE).astype(np.float32)


def build_cnn(
    n_classes: int,
    window: int = 100,
    channels: int = 7,
    filters: tuple[int, ...] = (16, 32, 32),
    kernel: int = 5,
    seed: int = 0,
) -> keras.Model:
    keras.utils.set_random_seed(seed)
    inp = keras.Input((window, channels), name="imu")
    x = inp
    for f in filters:
        x = layers.Conv1D(f, kernel, padding="same", activation="relu")(x)
        x = layers.MaxPooling1D(2)(x)
    x = layers.GlobalAveragePooling1D()(x)
    out = layers.Dense(n_classes, activation="softmax", name="probs")(x)
    model = keras.Model(inp, out)
    model.compile(
        optimizer=keras.optimizers.Adam(3e-3),
        loss="sparse_categorical_crossentropy",
        metrics=["accuracy"],
    )
    return model


def balanced_class_weight(y: np.ndarray) -> dict[int, float]:
    classes, counts = np.unique(y, return_counts=True)
    w = len(y) / (len(classes) * counts)
    return {int(c): float(v) for c, v in zip(classes, w, strict=True)}


def train_cnn(
    X: np.ndarray,
    y_idx: np.ndarray,
    n_classes: int,
    *,
    epochs: int = 25,
    batch_size: int = 256,
    augment_fn: Callable[[np.ndarray, np.random.Generator], np.ndarray] | None = None,
    seed: int = 0,
) -> keras.Model:
    """Train from scratch. `y_idx` are indices 0..n_classes-1 (not contract IDs).

    With `augment_fn`, every epoch sees a fresh (random) version of the training windows.
    """
    rng = np.random.default_rng(seed)
    model = build_cnn(n_classes, X.shape[1], X.shape[2], seed=seed)
    cw = balanced_class_weight(y_idx)
    lr = keras.optimizers.schedules.CosineDecay(3e-3, decay_steps=epochs)
    for epoch in range(epochs):
        model.optimizer.learning_rate = float(lr(epoch))
        Xe = augment_fn(X, rng) if augment_fn else X
        model.fit(
            scale_inputs(Xe), y_idx, batch_size=batch_size, epochs=1,
            class_weight=cw, shuffle=True, verbose=0,
        )  # fmt: skip
    return model


def predict_float(model: keras.Model, X: np.ndarray) -> np.ndarray:
    return model.predict(scale_inputs(X), batch_size=2048, verbose=0).argmax(axis=1)


# ---------------------------------------------------------------------------
# TFLite int8
# ---------------------------------------------------------------------------


def to_tflite_int8(model: keras.Model, representative: np.ndarray, n_rep: int = 500) -> bytes:
    """Full int8 quantization (weights, activations, input and output), as TFLM needs.

    `representative`: windows (UNscaled) from the training set, used to measure each
    activation's range. Never use test data here.
    """
    rng = np.random.default_rng(0)
    idx = rng.choice(len(representative), size=min(n_rep, len(representative)), replace=False)
    rep = scale_inputs(representative[idx])

    with tempfile.TemporaryDirectory() as d:
        model.export(d, format="tf_saved_model", verbose=False)
        conv = tf.lite.TFLiteConverter.from_saved_model(d)
        conv.optimizations = [tf.lite.Optimize.DEFAULT]
        conv.representative_dataset = lambda: ([rep[i : i + 1]] for i in range(len(rep)))
        conv.target_spec.supported_ops = [tf.lite.OpsSet.TFLITE_BUILTINS_INT8]
        conv.inference_input_type = tf.int8
        conv.inference_output_type = tf.int8
        return conv.convert()


def predict_int8(tflite_model: bytes, X: np.ndarray) -> np.ndarray:
    """Run the int8 model the way the chip would: quantize the input, infer, argmax."""
    it = tf.lite.Interpreter(model_content=tflite_model)
    inp, out = it.get_input_details()[0], it.get_output_details()[0]
    scale, zero = inp["quantization"]
    Xq = np.clip(np.round(scale_inputs(X) / scale + zero), -128, 127).astype(np.int8)
    it.resize_tensor_input(inp["index"], Xq.shape)
    it.allocate_tensors()
    it.set_tensor(inp["index"], Xq)
    it.invoke()
    return it.get_tensor(out["index"]).argmax(axis=1)


def activation_ram_estimate(model: keras.Model) -> int:
    """Estimated int8 activation RAM: the largest (input + output) of consecutive layers,
    which is what the TFLM arena must keep alive at the same time."""
    sizes = [int(np.prod(model.input.shape[1:]))]
    sizes += [int(np.prod(layer.output.shape[1:])) for layer in model.layers[1:]]
    return max(a + b for a, b in zip(sizes, sizes[1:], strict=False))
