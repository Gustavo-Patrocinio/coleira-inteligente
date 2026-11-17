"""Phase 2: pre-train on public data, fine-tune on our dogs, evaluate on dogs never seen.

    uv run python scripts/finetune_lodo.py            # full run
    uv run python scripts/finetune_lodo.py --quick    # smoke test (few epochs, 2 folds)

1. Pre-train the CNN on both public datasets (V + M; scratching is not in them, but the
   output exists so fine-tuning can teach it). Cached in ml/models/pretrained_public.keras.
2. Leave-one-dog-out over our dogs (ADR 0009): for each dog, fine-tune on the other dogs'
   sessions plus a replay sample of public windows (so the model does not forget the public
   dogs), test on the held-out dog. Compared with the pre-trained model alone on the same dog.
3. Split by day (CLAUDE.md rule 2): GroupKFold by recording day, same procedure.
4. Final model fine-tuned on all our sessions → ml/models/cnn_finetuned_int8.tflite, ready
   for `scripts/export_model.py --classes 0,1,2,3,4`.

Out-of-fold probabilities of the dog split go to ml/models/finetune_oof.npz:
`scripts/calibrate_events.py` uses them to calibrate p_event / n_min on unseen dogs.
Writes docs/results/finetune.md (rule 5: balanced accuracy, per-class F1, confusion matrix,
size, RAM) with the Phase 2 done criterion.
"""

from __future__ import annotations

import argparse
from functools import partial
from pathlib import Path

import numpy as np
from sklearn.model_selection import GroupKFold

from coleira_ml import cnn
from coleira_ml.augment import augment
from coleira_ml.features import CHANNELS_7, add_acc_magnitude
from coleira_ml.marcato_dataset import load_neck
from coleira_ml.own_sessions import load_sessions, own_windows
from coleira_ml.public_dataset import load_collar
from coleira_ml.report import confusion_md, f1_text, name, save_confusion, scores
from coleira_ml.windows import make_windows

ROOT = Path(__file__).resolve().parents[2]
ML = ROOT / "ml"
PUBLIC = ML / "data" / "public"
PRETRAINED = ML / "models" / "pretrained_public.keras"
FINAL = ML / "models" / "cnn_finetuned_int8.tflite"
OOF = ML / "models" / "finetune_oof.npz"
OUT = ROOT / "docs" / "results" / "finetune.md"
FIG = OUT.parent / "figures" / "finetune_lodo_confusion.png"
CLASSES = [0, 1, 2, 3, 4]
REPLAY = 20_000  # public windows mixed into each fine-tuning run
QUICK_NOTE = " (--quick: smoke test, numbers meaningless)"
TARGET_F1 = {0: 0.85, 1: 0.85, 2: 0.85, 3: 0.70, 4: 0.70}  # Phase 2 done criterion


def public_windows() -> tuple[np.ndarray, np.ndarray]:
    xs, ys = [], []
    for df in (load_collar(PUBLIC), load_neck(PUBLIC / "marcato")):
        w = make_windows(add_acc_magnitude(df), CHANNELS_7)
        keep = np.isin(w.y, CLASSES)
        xs.append(w.X[keep])
        ys.append(w.y[keep])
    return np.concatenate(xs), np.concatenate(ys)


def pretrained(Xp, yp, epochs, quick):
    import keras

    if PRETRAINED.exists() and not quick:
        print(f"using cached {PRETRAINED.name}")
        return keras.models.load_model(PRETRAINED)
    model = cnn.train_cnn(
        Xp, np.searchsorted(CLASSES, yp), len(CLASSES), epochs=epochs, augment_fn=partial(augment)
    )
    # the dense layer has an output for scratching even though the public data has none
    if not quick:
        PRETRAINED.parent.mkdir(parents=True, exist_ok=True)
        model.save(PRETRAINED)
    return model


def probs_float(model, X):
    return model.predict(cnn.scale_inputs(X), batch_size=2048, verbose=0)


def run_split(base, w, groups, Xp, yp, epochs, rng, max_folds, *, lodo):
    """Out-of-fold predictions: fine-tuned and pre-trained-only."""
    n_groups = len(set(groups))
    k = n_groups if lodo else min(n_groups, 5)
    folds = list(GroupKFold(n_splits=k).split(w.X, w.y, groups))[:max_folds]
    p_ft = np.full((len(w.y), len(CLASSES)), np.nan, dtype=np.float32)
    p_pre = probs_float(base, w.X)
    for i, (tr, te) in enumerate(folds):
        assert not set(groups[tr]) & set(groups[te])
        rep = rng.choice(len(yp), size=min(REPLAY, len(yp)), replace=False)
        X = np.concatenate([w.X[tr], Xp[rep]])
        y = np.concatenate([w.y[tr], yp[rep]])
        tuned = cnn.fine_tune(
            base, X, np.searchsorted(CLASSES, y), epochs=epochs, augment_fn=partial(augment)
        )
        p_ft[te] = probs_float(tuned, w.X[te])
        print(f"  fold {i + 1}/{len(folds)}: test {sorted(set(groups[te]))}")
    done = ~np.isnan(p_ft[:, 0])
    return p_ft, p_pre, done


def table(w, label, p_ft, p_pre, done):
    cls = np.asarray(CLASSES)
    rows = []
    for variant, p in (("pre-trained only", p_pre), ("fine-tuned", p_ft)):
        pred = cls[np.nan_to_num(p).argmax(1)]
        b, f = scores(w.y[done], pred[done], CLASSES)
        rows.append(f"| {label} | {variant} | {b:.3f} | {f1_text(f)} |")
    return rows


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument(
        "--data", type=Path, default=ROOT / "ml" / "data", help="folder with raw/ and labels/"
    )
    ap.add_argument("--quick", action="store_true")
    args = ap.parse_args()
    quick = args.quick
    ep_pre, ep_ft, max_folds = (2, 1, 2) if quick else (25, 10, 99)
    rng = np.random.default_rng(0)

    df, stats, skipped = load_sessions(args.data / "raw", args.data / "labels")
    w = own_windows(df)
    w = w.subset(np.isin(w.y, CLASSES))
    print(f"own: {len(w.y)} windows, {len(set(w.dog))} dogs, {len(set(w.day))} days")
    Xp, yp = public_windows()
    print(f"public: {len(yp)} windows")
    base = pretrained(Xp, yp, ep_pre, quick)

    rows = []
    print("leave-one-dog-out")
    p_ft, p_pre, done = run_split(base, w, w.dog, Xp, yp, ep_ft, rng, max_folds, lodo=True)
    rows += table(w, "unseen dog (LODO)", p_ft, p_pre, done)
    cls = np.asarray(CLASSES)
    pred = cls[np.nan_to_num(p_ft).argmax(1)]
    _, f1_dog = scores(w.y[done], pred[done], CLASSES)
    save_confusion(w.y[done], pred[done], CLASSES, FIG, "fine-tuned, unseen dogs (LODO)")
    conf = confusion_md(w.y[done], pred[done], CLASSES)
    np.savez_compressed(OOF, probs=p_ft[done], y=w.y[done], stretch=w.stretch[done], class_ids=cls)
    if len(set(w.day)) >= 2:
        print("by day")
        d_ft, d_pre, d_done = run_split(base, w, w.day, Xp, yp, ep_ft, rng, max_folds, lodo=False)
        rows += table(w, "unseen day", d_ft, d_pre, d_done)

    print("final model on all our data")
    rep = rng.choice(len(yp), size=min(REPLAY, len(yp)), replace=False)
    X = np.concatenate([w.X, Xp[rep]])
    y = np.concatenate([w.y, yp[rep]])
    final = cnn.fine_tune(
        base, X, np.searchsorted(CLASSES, y), epochs=ep_ft, augment_fn=partial(augment)
    )
    tfl = cnn.to_tflite_int8(final, w.X)
    FINAL.write_bytes(tfl)
    ram = cnn.activation_ram_estimate(final)

    crit = "\n".join(
        f"| {name(c)} | {f1_dog.get(c, float('nan')):.2f} | ≥ {t:.2f} | "
        f"{'✅' if f1_dog.get(c, 0) >= t else '❌'} |"
        for c, t in TARGET_F1.items()
    )
    md = f"""# Fine-tuning on our dogs (Phase 2)

> Generated by `ml/scripts/finetune_lodo.py`{QUICK_NOTE if quick else ""}. Do not edit by hand.

Pre-trained on both public datasets ({len(yp)} windows), fine-tuned on our {len(stats)} sessions
({len(set(w.dog))} dogs, {len(set(w.day))} days, {len(w.y)} windows) with {REPLAY} public windows
replayed per run. {ep_pre} pre-training and {ep_ft} fine-tuning epochs, rotation augmentation.
Float model in the folds; final int8 model below.

| Test split | Model | Balanced acc. | F1 |
|---|---|---:|---|
{chr(10).join(rows)}

## Unseen dogs (LODO), fine-tuned

{conf}

![Confusion matrix](figures/finetune_lodo_confusion.png)

## Phase 2 done criterion (F1 on never-seen dogs, window level before smoothing)

| Class | F1 | Target | |
|---|---:|---:|---|
{crit}

Also needed: the same on a never-seen session against video on the chip, and inference
< 50 ms (board log).

## Final model

`ml/models/cnn_finetuned_int8.tflite`: **{len(tfl) / 1024:.1f} KB** int8, estimated activation
RAM {ram / 1024:.1f} KB (tensor arena 16 KB; check the board log). To ship it:

    uv run python scripts/export_model.py --model models/cnn_finetuned_int8.tflite \\
        --classes 0,1,2,3,4
    uv run python scripts/calibrate_events.py
"""
    if skipped:
        md += "\nSkipped sessions: " + "; ".join(skipped) + "\n"
    OUT.write_text(md, encoding="utf-8")
    print(md)


if __name__ == "__main__":
    main()
