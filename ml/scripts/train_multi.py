"""Two public datasets: does the model generalize across populations, and does more data help?

Usage (from ml/):
    uv run python scripts/train_multi.py           # full run (~15 min on CPU)
    uv run python scripts/train_multi.py --quick   # smoke test

Datasets (both neck IMU, 50 Hz, ±16 g / ±2000 dps after loading):
- V: Vehkaoja et al. 2022, 45 dogs, many breeds, indoor arena, collar.
- M: Marcato et al. 2023, 42 assistance dogs (Labrador/Golden), neck strap on a harness.

Experiment 1, cross-dataset (classes still / walking / shaking, which both have):
train on all of V → test on all of M, and the reverse. Nothing about the test population
is seen in training: different dogs, mounting, lab and annotators. The closest thing we
have to "put it on someone else's dog".

Experiment 2, more data (classes still / walking / running / shaking): GroupKFold by dog
over V ∪ M. In each fold, train (a) on the V dogs only and (b) on V + M dogs, then test both
on the same unseen dogs, reported separately for V and M test dogs.

Writes docs/results/multi_dataset.md and a figure; saves the combined int8 model.
"""

from __future__ import annotations

import argparse
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
from coleira_ml.marcato_dataset import load_neck  # noqa: E402
from coleira_ml.public_dataset import load_collar  # noqa: E402
from coleira_ml.windows import make_windows  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
PUBLIC = ROOT / "ml" / "data" / "public"
OUT_MD = ROOT / "docs" / "results" / "multi_dataset.md"
FIG = OUT_MD.parent / "figures" / "multi_dataset_cross.png"
MODEL_OUT = ROOT / "ml" / "models" / "cnn_multi_int8.tflite"
CROSS = [0, 1, 4]
ALL = [0, 1, 2, 4]


def windows(df):
    w = make_windows(add_acc_magnitude(df), CHANNELS_7)
    keep = w.y != 255
    return w.X[keep], w.y[keep], w.groups[keep]


def name(c):
    return Behavior(c).name.lower()


def fit_predict(Xtr, ytr, Xte, classes, epochs):
    idx = np.searchsorted(classes, ytr)
    model = cnn.train_cnn(Xtr, idx, len(classes), epochs=epochs, augment_fn=partial(augment))
    return np.asarray(classes)[cnn.predict_float(model, Xte)], model


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--quick", action="store_true")
    epochs = 2 if ap.parse_args().quick else 25

    Xv, yv, gv = windows(load_collar(PUBLIC))
    Xm, ym, gm = windows(load_neck(PUBLIC / "marcato"))
    print(f"V: {len(yv)} windows, {len(set(gv))} dogs | M: {len(ym)} windows, {len(set(gm))} dogs")

    # ---------------- Experiment 1: cross-dataset
    cross = {}
    for src, dst, (Xa, ya), (Xb, yb) in [
        ("V", "M", (Xv, yv), (Xm, ym)),
        ("M", "V", (Xm, ym), (Xv, yv)),
    ]:
        ma, mb = np.isin(ya, CROSS), np.isin(yb, CROSS)
        pred, _ = fit_predict(Xa[ma], ya[ma], Xb[mb], CROSS, epochs)
        yt = yb[mb]
        cross[(src, dst)] = (yt, pred)
        bacc = balanced_accuracy_score(yt, pred)
        print(f"cross {src}->{dst}: balanced acc {bacc:.3f}")

    # ---------------- Experiment 2: V-only vs V+M, GroupKFold by dog over V ∪ M
    X = np.concatenate([Xv, Xm])
    y = np.concatenate([yv, ym])
    g = np.concatenate([gv, gm])
    src = np.array(["V"] * len(yv) + ["M"] * len(ym))
    m = np.isin(y, ALL)
    X, y, g, src = X[m], y[m], g[m], src[m]
    preds = {"V only": np.full(len(y), -1), "V + M": np.full(len(y), -1)}
    folds = list(GroupKFold(n_splits=5).split(X, y, g))
    for k, (tr, te) in enumerate(folds[:1] if epochs == 2 else folds):
        assert not set(g[tr]) & set(g[te])
        tr_v = tr[src[tr] == "V"]
        preds["V only"][te], _ = fit_predict(X[tr_v], y[tr_v], X[te], ALL, epochs)
        preds["V + M"][te], _ = fit_predict(X[tr], y[tr], X[te], ALL, epochs)
        print(f"fold {k} done")
    done = preds["V + M"] >= 0

    def score(p, s):
        sel = done & (src == s)
        return balanced_accuracy_score(y[sel], p[sel]), sel

    rows = []
    for s in ("V", "M"):
        for variant, p in preds.items():
            bacc, sel = score(p, s)
            present = [c for c in ALL if (y[sel] == c).any()]
            f1 = f1_score(y[sel], p[sel], labels=present, average=None)
            f1s = " · ".join(f"{name(c)} {v:.2f}" for c, v in zip(present, f1, strict=True))
            rows.append(f"| {s} test dogs | {variant} | {bacc:.3f} | {f1s} |")
            print(rows[-1])

    # ---------------- final combined model → int8 size
    idx = np.searchsorted(ALL, y)
    final = cnn.train_cnn(X, idx, len(ALL), epochs=epochs, augment_fn=partial(augment))
    tfl = cnn.to_tflite_int8(final, X)
    MODEL_OUT.parent.mkdir(parents=True, exist_ok=True)
    MODEL_OUT.write_bytes(tfl)

    # ---------------- figure: cross-dataset confusion matrices
    fig, ax = plt.subplots(1, 2, figsize=(10, 4.3))
    for a, (key, (yt, pred)) in zip(ax, cross.items(), strict=True):
        cm = confusion_matrix(yt, pred, labels=CROSS, normalize="true")
        ConfusionMatrixDisplay(cm, display_labels=[name(c) for c in CROSS]).plot(
            ax=a, values_format=".2f", cmap="Blues", colorbar=False
        )
        bacc = balanced_accuracy_score(yt, pred)
        a.set_title(f"train {key[0]} → test {key[1]}  (bal. acc {bacc:.3f})")
        a.set_xlabel("predicted")
        a.set_ylabel("true")
    fig.tight_layout()
    FIG.parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(FIG, dpi=110)
    plt.close(fig)

    cross_rows = []
    for (a, b), (yt, pred) in cross.items():
        f1 = f1_score(yt, pred, labels=CROSS, average=None)
        f1s = " · ".join(f"{name(c)} {v:.2f}" for c, v in zip(CROSS, f1, strict=True))
        cross_rows.append(
            f"| {a} ({'45' if a == 'V' else '42'} dogs) | {b} | "
            f"{balanced_accuracy_score(yt, pred):.3f} | {f1s} |"
        )

    md = f"""# Two public datasets: generalization and more data

> Generated by `ml/scripts/train_multi.py`. Do not edit by hand.

- **V**: Vehkaoja et al. 2022, {len(set(gv))} dogs of many breeds, collar, indoor arena.
- **M**: Marcato et al. 2023, {len(set(gm))} assistance dogs (Labrador/Golden), neck strap.

Both: neck IMU at 50 Hz, ±16 g / ±2000 dps, 2 s windows, the same 1D CNN as Phase 0
({epochs} epochs, 3D-rotation augmentation), float model. Balanced accuracy is computed over
the classes present in each test set.

## Experiment 1: train on one dataset, test on the other

Classes both datasets have: still, walking, shaking. Nothing about the test population is
seen during training (different dogs, mounting, lab and annotators).

| Train | Test | Balanced acc. | F1 |
|---|---|---:|---|
{chr(10).join(cross_rows)}

![Cross-dataset confusion matrices](figures/multi_dataset_cross.png)

## Experiment 2: does adding the second dataset help?

GroupKFold (5 folds) by dog over V ∪ M, classes still / walking / running / shaking. In
each fold both variants are tested on the same unseen dogs.

| Test dogs | Trained on | Balanced acc. | F1 |
|---|---|---:|---|
{chr(10).join(rows)}

Combined model (all {len(set(g))} dogs), int8: **{len(tfl) / 1024:.1f} KB**, saved to
`ml/models/cnn_multi_int8.tflite` (not versioned).
"""
    OUT_MD.write_text(md, encoding="utf-8")
    print(md)


if __name__ == "__main__":
    main()
