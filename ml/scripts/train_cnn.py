"""Fase 0: CNN 1D (float e int8), avaliada com GroupKFold por cachorro.

Uso (de dentro de ml/):
    uv run python scripts/train_cnn.py            # completo (~20 min em CPU)
    uv run python scripts/train_cnn.py --quick    # 1 fold, poucas épocas (teste do script)

Para cada fold treina duas variantes:
- `aug`:   rotação 3D aleatória + escala + ruído a cada época
- `noaug`: sem augmentation
e avalia cada uma no teste original e no teste ROTACIONADO (coleira girada no pescoço),
em float e em int8.

Gera docs/results/fase0_cnn.md e salva o modelo final int8 em ml/models/ (fora do git).
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
OUT_MD = ROOT / "docs" / "results" / "fase0_cnn.md"
FIG_DIR = OUT_MD.parent / "figures"
MODEL_OUT = ROOT / "ml" / "models" / "cnn_fase0_int8.tflite"
CLASSES = [0, 1, 2]
MAIN = ("aug", "orig", "int8")  # resultado "oficial" da Fase 0


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
    X_rot = rotate_only(X, seed=123)  # teste rotacionado fixo (mesma rotação p/ todos os modelos)
    print(f"{len(y)} janelas, {len(np.unique(groups))} cães, {epochs} épocas")

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

    # ---- modelo final (todos os cães) → tamanho real do .tflite
    final = cnn.train_cnn(X, y_idx, len(CLASSES), epochs=epochs, augment_fn=augment)
    tfl_final = cnn.to_tflite_int8(final, X)
    MODEL_OUT.parent.mkdir(parents=True, exist_ok=True)
    MODEL_OUT.write_bytes(tfl_final)
    size_kb = len(tfl_final) / 1024
    ram_kb = cnn.activation_ram_estimate(final) / 1024
    params = final.count_params()

    # ---- relatório
    def mean_std(key):
        a = np.array(fold_bacc[key])
        return f"{a.mean():.3f} ± {a.std():.3f}"

    rows = [
        f"| {v} | {'original' if t == 'orig' else 'rotacionado'} | {mean_std((v, t, 'float'))} "
        f"| {mean_std((v, t, 'int8'))} |"
        for v in variants
        for t in ("orig", "rot")
    ]
    yt, yp = y_idx[evaluated], pred[MAIN][evaluated]
    f1 = f1_score(yt, yp, average=None, labels=range(len(CLASSES)))
    names = [Behavior(c).name for c in CLASSES]

    FIG_DIR.mkdir(parents=True, exist_ok=True)
    cm = confusion_matrix(yt, yp, labels=range(len(CLASSES)), normalize="true")
    fig, ax = plt.subplots(figsize=(5, 4.3))
    ConfusionMatrixDisplay(cm, display_labels=names).plot(
        ax=ax, values_format=".2f", cmap="Blues", colorbar=False
    )
    ax.set_title("CNN int8 (com augmentation), cães não vistos", fontsize=10)
    ax.set_xlabel("predito")
    ax.set_ylabel("verdade")
    fig.tight_layout()
    fig.savefig(FIG_DIR / "D_cnn_int8.png", dpi=110)
    plt.close(fig)

    md = [
        "# Fase 0: CNN 1D (float × int8), dataset público, só coleira",
        "",
        "> Gerado por `ml/scripts/train_cnn.py`. Não editar à mão.",
        "",
        "Arquitetura: 3× [Conv1D k=5 → ReLU → MaxPool 2] (16/32/32) → GAP → Dense softmax. "
        f"{params} parâmetros. Treino: {epochs} épocas, Adam com cosine decay, "
        "class_weight balanceado. Avaliação: **GroupKFold 5× por cachorro**. "
        "Quantização: int8 completa (pesos, ativações, entrada e saída), calibrada só com "
        "janelas de treino de cada fold.",
        "",
        "- `aug`: rotação 3D uniforme + escala ±10% + ruído, sorteados de novo a cada época",
        "- `noaug`: sem augmentation",
        "- teste *rotacionado*: as mesmas janelas de teste com uma rotação 3D aleatória fixa "
        "por janela (simula a coleira girada ou montada diferente)",
        "",
        "## Acurácia balanceada (média ± desvio entre folds)",
        "",
        "| Variante | Teste | float | int8 |",
        "|---|---|---:|---:|",
        *rows,
        "",
        "## Modelo oficial: `aug`, int8, teste original",
        "",
        f"- **Acurácia balanceada: {mean_std(MAIN)}**",
        f"- Tamanho do `.tflite` int8 (modelo final): **{size_kb:.1f} KB**",
        f"- RAM de ativações (estimativa, int8): ~{ram_kb:.1f} KB. O arena real do TFLM "
        "inclui overhead e será medido na Fase 2",
        "",
        "| Classe | F1 |",
        "|---|---:|",
        *[f"| {n} | {v:.3f} |" for n, v in zip(names, f1, strict=True)],
        "",
        "![CNN int8](figures/D_cnn_int8.png)",
        "",
    ]
    OUT_MD.write_text("\n".join(md), encoding="utf-8")
    print("\n".join(rows))
    print(f"main {mean_std(MAIN)}  size {size_kb:.1f} KB  ram~{ram_kb:.1f} KB  F1 {f1.round(3)}")


if __name__ == "__main__":
    main()
