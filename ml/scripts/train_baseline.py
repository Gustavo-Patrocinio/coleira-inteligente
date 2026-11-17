"""Phase 0: features + trees baseline, evaluated with GroupKFold by dog.

Usage (from ml/):
    uv run python scripts/train_baseline.py

Writes docs/results/phase0_baseline.md and the confusion matrices in docs/results/figures/.
"""

from __future__ import annotations

from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402
import numpy as np  # noqa: E402
from sklearn.ensemble import RandomForestClassifier  # noqa: E402
from sklearn.metrics import ConfusionMatrixDisplay  # noqa: E402
from sklearn.tree import DecisionTreeClassifier  # noqa: E402

from coleira_ml.classes import Behavior  # noqa: E402
from coleira_ml.evaluate import BYTES_PER_NODE_ESTIMATE, CVResult, group_cv, tree_nodes  # noqa: E402
from coleira_ml.features import CHANNELS_7, add_acc_magnitude, window_features  # noqa: E402
from coleira_ml.public_dataset import TARGET_HZ, load_collar  # noqa: E402
from coleira_ml.windows import WINDOW, make_windows  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
OUT_MD = ROOT / "docs" / "results" / "phase0_baseline.md"
FIG_DIR = OUT_MD.parent / "figures"
SEED = 0
MOVING = 100  # internal label for the binary experiment (not a contract ID)


def rf_shallow():
    return RandomForestClassifier(
        n_estimators=50,
        max_depth=8,
        min_samples_leaf=20,
        class_weight="balanced",
        n_jobs=-1,
        random_state=SEED,
    )


def mlc_tree():
    # ST's MLC accepts small trees; depth 4 = at most 31 nodes.
    return DecisionTreeClassifier(max_depth=4, class_weight="balanced", random_state=SEED)


def name(c: int) -> str:
    return "moving" if c == MOVING else Behavior(c).name.lower()


def save_confusion(res: CVResult, title: str, fname: str) -> str:
    fig, ax = plt.subplots(figsize=(4.5 + 0.4 * len(res.labels), 4 + 0.3 * len(res.labels)))
    cm = res.confusion / res.confusion.sum(axis=1, keepdims=True)
    ConfusionMatrixDisplay(cm, display_labels=[name(c) for c in res.labels]).plot(
        ax=ax, values_format=".2f", cmap="Blues", colorbar=False
    )
    ax.set_title(title, fontsize=10)
    ax.set_xlabel("predicted")
    ax.set_ylabel("true")
    plt.setp(ax.get_xticklabels(), rotation=30, ha="right")
    fig.tight_layout()
    FIG_DIR.mkdir(parents=True, exist_ok=True)
    fig.savefig(FIG_DIR / fname, dpi=110)
    plt.close(fig)
    return f"figures/{fname}"


def report(title, res, model, F, y, n_feat, fig_rel, notes) -> str:
    final = model.fit(F, y)  # trained on everything, only to measure size
    nodes = tree_nodes(final)
    kb = nodes * BYTES_PER_NODE_ESTIMATE / 1024
    # Inference RAM (estimate): int16 6-axis window + float |a| + feature vector
    ram_b = WINDOW * 6 * 2 + WINDOW * 4 + n_feat * 4
    counts = {name(c): int((y == c).sum()) for c in res.labels}
    lines = [
        f"## {title}",
        "",
        notes,
        "",
        f"- Windows per class: {counts}",
        f"- **Balanced accuracy (GroupKFold 5×, by dog): "
        f"{res.balanced_acc_mean:.3f} ± {res.balanced_acc_std:.3f}**",
        f"- Per fold: {', '.join(f'{v:.3f}' for v in res.fold_balanced_acc)}",
        f"- Size: {nodes} nodes ≈ **{kb:.1f} KB** (estimate, ~{BYTES_PER_NODE_ESTIMATE} B/node)",
        f"- Inference RAM: ≈ {ram_b / 1024:.1f} KB (estimate: window + features)",
        "",
        "| Class | F1 |",
        "|---|---:|",
        *[f"| {name(c)} | {f:.3f} |" for c, f in res.f1_per_class.items()],
        "",
        f"![{title}]({fig_rel})",
        "",
    ]
    return "\n".join(lines)


def main() -> None:
    df = add_acc_magnitude(load_collar(ROOT / "ml" / "data" / "public"))
    w = make_windows(df, CHANNELS_7)
    print(f"{len(w.y)} windows; labeled: {(w.y != 255).sum()}")

    F_full, names_full = window_features(w.X, CHANNELS_7, fs=TARGET_HZ, kind="full")
    F_mlc, names_mlc = window_features(w.X, CHANNELS_7, fs=TARGET_HZ, kind="mlc")

    sections = []

    # A) Phase 0 target: 3 classes
    m = np.isin(w.y, [0, 1, 2])
    res = group_cv(rf_shallow, F_full[m], w.y[m], w.groups[m])
    fig = save_confusion(res, "A: shallow RF, 3 classes", "A_rf_3classes.png")
    sections.append(
        report(
            "A: Shallow Random Forest, classes 0–2 (Phase 0 target)",
            res, rf_shallow(), F_full[m], w.y[m], len(names_full), fig,
            "50 trees, depth ≤ 8, class_weight=balanced. "
            "Features: mean, std, min, max, energy and dominant frequency × 7 channels.",
        )
    )  # fmt: skip
    print("A", round(res.balanced_acc_mean, 3), res.f1_per_class)

    # B) with shaking
    m = np.isin(w.y, [0, 1, 2, 4])
    res = group_cv(rf_shallow, F_full[m], w.y[m], w.groups[m])
    fig = save_confusion(res, "B: shallow RF, 0–2 + shaking", "B_rf_4classes.png")
    sections.append(
        report(
            "B: Shallow Random Forest, classes 0–2 + shaking (informative)",
            res, rf_shallow(), F_full[m], w.y[m], len(names_full), fig,
            "Same model as A. Shaking has very few windows in the public dataset.",
        )
    )  # fmt: skip
    print("B", round(res.balanced_acc_mean, 3), res.f1_per_class)

    # C) MLC tree: still vs moving, only features the MLC computes
    m = np.isin(w.y, [0, 1, 2, 4])
    y_bin = np.where(w.y[m] == 0, 0, MOVING)
    res = group_cv(mlc_tree, F_mlc[m], y_bin, w.groups[m])
    fig = save_confusion(res, "C: MLC tree, still × moving", "C_mlc_binary.png")
    sections.append(
        report(
            "C: Single MLC-compatible tree: still × moving (level 1, Phase 5)",
            res, mlc_tree(), F_mlc[m], y_bin, len(names_mlc), fig,
            "Depth ≤ 4. Only feature types the MLC computes (mean, variance, energy, "
            "peak-to-peak, min, max); no FFT. Moving = walking + running + shaking.",
        )
    )  # fmt: skip
    print("C", round(res.balanced_acc_mean, 3), res.f1_per_class)
    tree = mlc_tree().fit(F_mlc[m], y_bin)
    used = sorted({names_mlc[i] for i in tree.tree_.feature if i >= 0})
    sections.append(f"Features used by tree C: {', '.join(used)}\n")

    header = (
        "# Phase 0: features + trees baseline (public dataset, collar only)\n\n"
        "> Generated by `ml/scripts/train_baseline.py`. Do not edit by hand.\n\n"
        "Evaluation: **GroupKFold (5 folds) by dog**: every fold is tested on dogs the model "
        "has never seen (rule 2). 2 s windows with a 1 s step (contract 4.3), labeled with the "
        "ADR 0002 rule; windows without a clear label are dropped. Data saturated at "
        "±16 g / ±2000 dps (ADR 0005). Confusion matrices are row-normalized.\n\n"
    )
    OUT_MD.parent.mkdir(parents=True, exist_ok=True)
    OUT_MD.write_text(header + "\n".join(sections), encoding="utf-8")
    print("wrote:", OUT_MD)


if __name__ == "__main__":
    main()
