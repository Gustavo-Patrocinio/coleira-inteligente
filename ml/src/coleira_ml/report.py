"""Metrics in the shape CLAUDE.md rule 5 asks for: balanced accuracy, per-class F1 and a
confusion matrix, as Markdown + a PNG."""

from __future__ import annotations

from collections.abc import Sequence
from pathlib import Path

import numpy as np
from sklearn.metrics import balanced_accuracy_score, confusion_matrix, f1_score

from coleira_ml.classes import Behavior


def name(c: int) -> str:
    return Behavior(c).name.lower()


def scores(
    y: np.ndarray, pred: np.ndarray, classes: Sequence[int]
) -> tuple[float, dict[int, float]]:
    present = [c for c in classes if (y == c).any()]
    if not present:
        return float("nan"), {}
    f1 = f1_score(y, pred, labels=present, average=None, zero_division=0)
    return float(balanced_accuracy_score(y, pred)), dict(zip(present, map(float, f1), strict=True))


def f1_text(f1: dict[int, float]) -> str:
    return " · ".join(f"{name(c)} {v:.2f}" for c, v in f1.items())


def confusion_md(y: np.ndarray, pred: np.ndarray, classes: Sequence[int]) -> str:
    """Row-normalized confusion matrix (rows: true, columns: predicted) + window counts."""
    cm = confusion_matrix(y, pred, labels=list(classes))
    head = r"| true \ predicted | " + " | ".join(name(c) for c in classes) + " | windows |"
    lines = [head, "|---|" + "---:|" * (len(classes) + 1)]
    for c, row in zip(classes, cm, strict=True):
        n = row.sum()
        cells = " | ".join(f"{v / n:.2f}" if n else "–" for v in row)
        lines.append(f"| {name(c)} | {cells} | {n} |")
    return "\n".join(lines)


def save_confusion(
    y: np.ndarray, pred: np.ndarray, classes: Sequence[int], path: Path, title: str
) -> None:
    import matplotlib

    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    from sklearn.metrics import ConfusionMatrixDisplay

    cm = confusion_matrix(y, pred, labels=list(classes), normalize="true")
    fig, ax = plt.subplots(figsize=(1.2 * len(classes) + 2, 1.1 * len(classes) + 1.5))
    ConfusionMatrixDisplay(np.nan_to_num(cm), display_labels=[name(c) for c in classes]).plot(
        ax=ax, values_format=".2f", cmap="Blues", colorbar=False
    )
    ax.set_title(title, fontsize=10)
    ax.set_xlabel("predicted")
    ax.set_ylabel("true")
    fig.tight_layout()
    path.parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(path, dpi=110)
    plt.close(fig)
