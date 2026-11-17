"""Phase 0: 1D CNN (float and int8), evaluated with GroupKFold by dog.

Usage (from ml/):
    uv run python scripts/train_cnn.py            # full run (~10 min on CPU)
    uv run python scripts/train_cnn.py --quick    # 1 fold, few epochs (script smoke test)

For each fold it trains two variants:
- `aug`:   random 3D rotation + scale + noise every epoch
- `noaug`: no augmentation
and evaluates each one on the original test set and on a ROTATED test set (collar turned
on the neck), in float and in int8.

Writes docs/results/phase0_cnn.md and saves the final int8 model to ml/models/ (not in git).
"""

from __future__ import annotations

import argparse
import time
from functools import partial
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402
import numpy as np  # noqa: E402
from sklearn.metrics import (  # noqa: E402
    ConfusionMatrixDisplay,
    balanced_accuracy_score,
    confusion_matrix,
    f1_score,
)
from sklearn.model_selection import GroupKFold  # noqa: E402

from coleira_ml import cnn  # noqa: E402
from coleira_ml.augment import augment  # noqa: E402
from coleira_ml.classes import Behavior  # noqa: E402
from coleira_ml.features import CHANNELS_7, add_acc_magnitude  # noqa: E402
from coleira_ml.public_dataset import load_collar  # noqa: E402
from coleira_ml.windows import make_windows  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
OUT_MD = ROOT / "docs" / "results" / "phase0_cnn.md"
FIG_DIR = OUT_MD.parent / "figures"
MODEL_OUT = ROOT / "ml" / "models" / "cnn_phase0_int8.tflite"
CLASSES = [0, 1, 2]
MAIN = ("aug", "orig", "int8")  # the "official" Phase 0 result


def rotate_only(X, seed):
    return augment(
        X, np.random.default_rng(seed), scale_range=(1, 1), accel_noise_g=0, gyro_noise_dps=0
    )


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--quick", action="store_true")
    args = ap.parse_args()
    epochs = 3 if args.quick else 25

    df = add_acc_magnitude(load_collar(ROOT / "ml" / "data" / "public"))
    w = make_windows(df, CHANNELS_7)
    m = np.isin(w.y, CLASSES)
    X, y, groups = w.X[m], w.y[m], w.groups[m]
    y_idx = np.searchsorted(CLASSES, y)
    X_rot = rotate_only(X, seed=123)  # fixed rotated test set (same rotation for every model)
    print(f"{len(y)} windows, {len(np.unique(groups))} dogs, {epochs} epochs")

    variants = {"aug": partial(augment), "noaug": None}
    pred = {
        (v, t, q): np.full(len(y), -1)
        for v in variants
        for t in ("orig", "rot")
        for q in ("float", "int8")
    }
    fold_bacc = {k: [] for k in pred}

    folds = list(GroupKFold(n_splits=5).split(X, y, groups))
    if args.quick:
        folds = folds[:1]
    for k, (tr, te) in enumerate(folds):
        assert not set(groups[tr]) & set(groups[te])
        for v, aug_fn in variants.items():
            t0 = time.time()
            model = cnn.train_cnn(X[tr], y_idx[tr], len(CLASSES), epochs=epochs, augment_fn=aug_fn)
            tfl = cnn.to_tflite_int8(model, X[tr])
            for t, Xt in (("orig", X[te]), ("rot", X_rot[te])):
                p = {"float": cnn.predict_float(model, Xt), "int8": cnn.predict_int8(tfl, Xt)}
                for q, pq in p.items():
                    pred[(v, t, q)][te] = pq
                    fold_bacc[(v, t, q)].append(balanced_accuracy_score(y_idx[te], pq))
            print(
                f"fold {k} {v:5s} {time.time() - t0:5.0f}s  "
                + "  ".join(f"{t}/{q}={fold_bacc[(v, t, q)][-1]:.3f}"
                            for t in ("orig", "rot") for q in ("float", "int8"))
            )  # fmt: skip

    evaluated = np.concatenate([te for _, te in folds])

    # ---- final model (all dogs) → real .tflite size
    final = cnn.train_cnn(X, y_idx, len(CLASSES), epochs=epochs, augment_fn=augment)
    tfl_final = cnn.to_tflite_int8(final, X)
    MODEL_OUT.parent.mkdir(parents=True, exist_ok=True)
    MODEL_OUT.write_bytes(tfl_final)
    size_kb = len(tfl_final) / 1024
    ram_kb = cnn.activation_ram_estimate(final) / 1024
    params = final.count_params()

    # ---- report
    def mean_std(key):
        a = np.array(fold_bacc[key])
        return f"{a.mean():.3f} ± {a.std():.3f}"

    rows = [
        f"| {v} | {'original' if t == 'orig' else 'rotated'} | {mean_std((v, t, 'float'))} "
        f"| {mean_std((v, t, 'int8'))} |"
        for v in variants
        for t in ("orig", "rot")
    ]
    yt, yp = y_idx[evaluated], pred[MAIN][evaluated]
    f1 = f1_score(yt, yp, average=None, labels=range(len(CLASSES)))
    names = [Behavior(c).name.lower() for c in CLASSES]

    FIG_DIR.mkdir(parents=True, exist_ok=True)
    cm = confusion_matrix(yt, yp, labels=range(len(CLASSES)), normalize="true")
    fig, ax = plt.subplots(figsize=(5, 4.3))
    ConfusionMatrixDisplay(cm, display_labels=names).plot(
        ax=ax, values_format=".2f", cmap="Blues", colorbar=False
    )
    ax.set_title("int8 CNN (with augmentation), unseen dogs", fontsize=10)
    ax.set_xlabel("predicted")
    ax.set_ylabel("true")
    fig.tight_layout()
    fig.savefig(FIG_DIR / "D_cnn_int8.png", dpi=110)
    plt.close(fig)

    md = [
        "# Phase 0: 1D CNN (float × int8), public dataset, collar only",
        "",
        "> Generated by `ml/scripts/train_cnn.py`. Do not edit by hand.",
        "",
        "Architecture: 3× [Conv1D k=5 → ReLU → MaxPool 2] (16/32/32) → GAP → Dense softmax. "
        f"{params} parameters. Training: {epochs} epochs, Adam with cosine decay, "
        "balanced class weights. Evaluation: **GroupKFold 5× by dog**. "
        "Quantization: full int8 (weights, activations, input and output), calibrated only on "
        "each fold's training windows.",
        "",
        "- `aug`: uniform 3D rotation + ±10% scale + noise, re-drawn every epoch",
        "- `noaug`: no augmentation",
        "- *rotated* test: the same test windows with a fixed random 3D rotation per window "
        "(simulates a collar turned on the neck or mounted differently)",
        "",
        "## Balanced accuracy (mean ± std across folds)",
        "",
        "| Variant | Test | float | int8 |",
        "|---|---|---:|---:|",
        *rows,
        "",
        "## Official model: `aug`, int8, original test",
        "",
        f"- **Balanced accuracy: {mean_std(MAIN)}**",
        f"- int8 `.tflite` size (final model): **{size_kb:.1f} KB**",
        f"- Activation RAM (estimate, int8): ~{ram_kb:.1f} KB. The real TFLM arena "
        "includes overhead and will be measured in Phase 2",
        "",
        "| Class | F1 |",
        "|---|---:|",
        *[f"| {n} | {v:.3f} |" for n, v in zip(names, f1, strict=True)],
        "",
        "![int8 CNN](figures/D_cnn_int8.png)",
        "",
    ]
    OUT_MD.write_text("\n".join(md), encoding="utf-8")
    print("\n".join(rows))
    print(f"main {mean_std(MAIN)}  size {size_kb:.1f} KB  ram~{ram_kb:.1f} KB  F1 {f1.round(3)}")


if __name__ == "__main__":
    main()
