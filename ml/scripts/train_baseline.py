"""Fase 0: baseline de features + árvores, avaliado com GroupKFold por cachorro.

Uso (de dentro de ml/):
    uv run python scripts/train_baseline.py

Gera docs/results/fase0_baseline.md e as matrizes de confusão em docs/results/figures/.
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
OUT_MD = ROOT / "docs" / "results" / "fase0_baseline.md"
FIG_DIR = OUT_MD.parent / "figures"
SEED = 0
MOVING = 100  # rótulo interno do experimento binário (não é um ID do contrato)


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
    # O MLC da ST aceita árvores pequenas; profundidade 4 = no máximo 31 nós.
    return DecisionTreeClassifier(max_depth=4, class_weight="balanced", random_state=SEED)


def name(c: int) -> str:
    return "MOVIMENTO" if c == MOVING else Behavior(c).name


def save_confusion(res: CVResult, title: str, fname: str) -> str:
    fig, ax = plt.subplots(figsize=(4.5 + 0.4 * len(res.labels), 4 + 0.3 * len(res.labels)))
    cm = res.confusion / res.confusion.sum(axis=1, keepdims=True)
    ConfusionMatrixDisplay(cm, display_labels=[name(c) for c in res.labels]).plot(
        ax=ax, values_format=".2f", cmap="Blues", colorbar=False
    )
    ax.set_title(title, fontsize=10)
    ax.set_xlabel("predito")
    ax.set_ylabel("verdade")
    plt.setp(ax.get_xticklabels(), rotation=30, ha="right")
    fig.tight_layout()
    FIG_DIR.mkdir(parents=True, exist_ok=True)
    fig.savefig(FIG_DIR / fname, dpi=110)
    plt.close(fig)
    return f"figures/{fname}"


def report(title, res, model, F, y, n_feat, fig_rel, notes) -> str:
    final = model.fit(F, y)  # modelo treinado em tudo, só para medir tamanho
    nodes = tree_nodes(final)
    kb = nodes * BYTES_PER_NODE_ESTIMATE / 1024
    # RAM de inferência (estimativa): janela int16 6 eixos + |a| float + vetor de features
    ram_b = WINDOW * 6 * 2 + WINDOW * 4 + n_feat * 4
    counts = {name(c): int((y == c).sum()) for c in res.labels}
    lines = [
        f"## {title}",
        "",
        notes,
        "",
        f"- Janelas por classe: {counts}",
        f"- **Acurácia balanceada (GroupKFold 5×, por cachorro): "
        f"{res.balanced_acc_mean:.3f} ± {res.balanced_acc_std:.3f}**",
        f"- Por fold: {', '.join(f'{v:.3f}' for v in res.fold_balanced_acc)}",
        f"- Tamanho: {nodes} nós ≈ **{kb:.1f} KB** (estimativa, ~{BYTES_PER_NODE_ESTIMATE} B/nó)",
        f"- RAM de inferência: ≈ {ram_b / 1024:.1f} KB (estimativa: janela + features)",
        "",
        "| Classe | F1 |",
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
    print(f"{len(w.y)} janelas; rotuladas: {(w.y != 255).sum()}")

    F_full, names_full = window_features(w.X, CHANNELS_7, fs=TARGET_HZ, kind="full")
    F_mlc, names_mlc = window_features(w.X, CHANNELS_7, fs=TARGET_HZ, kind="mlc")

    sections = []

    # A) meta da Fase 0: 3 classes
    m = np.isin(w.y, [0, 1, 2])
    res = group_cv(rf_shallow, F_full[m], w.y[m], w.groups[m])
    fig = save_confusion(res, "A: RF raso, 3 classes", "A_rf_3classes.png")
    sections.append(
        report(
            "A: Random Forest raso, classes 0–2 (meta da Fase 0)",
            res, rf_shallow(), F_full[m], w.y[m], len(names_full), fig,
            "50 árvores, profundidade ≤ 8, class_weight=balanced. "
            "Features: média, desvio, mín, máx, energia e frequência dominante × 7 canais.",
        )
    )  # fmt: skip
    print("A", round(res.balanced_acc_mean, 3), res.f1_per_class)

    # B) com chacoalhar
    m = np.isin(w.y, [0, 1, 2, 4])
    res = group_cv(rf_shallow, F_full[m], w.y[m], w.groups[m])
    fig = save_confusion(res, "B: RF raso, 0–2 + chacoalhar", "B_rf_4classes.png")
    sections.append(
        report(
            "B: Random Forest raso, classes 0–2 + chacoalhar (informativo)",
            res, rf_shallow(), F_full[m], w.y[m], len(names_full), fig,
            "Mesmo modelo de A. Chacoalhar tem pouquíssimas janelas no dataset público.",
        )
    )  # fmt: skip
    print("B", round(res.balanced_acc_mean, 3), res.f1_per_class)

    # C) árvore do MLC: parado vs movimento, só features que o MLC calcula
    m = np.isin(w.y, [0, 1, 2, 4])
    y_bin = np.where(w.y[m] == 0, 0, MOVING)
    res = group_cv(mlc_tree, F_mlc[m], y_bin, w.groups[m])
    fig = save_confusion(res, "C: árvore MLC, parado × movimento", "C_mlc_binary.png")
    sections.append(
        report(
            "C: Árvore única compatível com MLC: parado × movimento (nível 1, Fase 5)",
            res, mlc_tree(), F_mlc[m], y_bin, len(names_mlc), fig,
            "Profundidade ≤ 4. Features só do tipo que o MLC calcula (média, variância, "
            "energia, pico a pico, mín, máx); sem FFT. Movimento = andando + correndo + "
            "chacoalhando.",
        )
    )  # fmt: skip
    print("C", round(res.balanced_acc_mean, 3), res.f1_per_class)
    tree = mlc_tree().fit(F_mlc[m], y_bin)
    used = sorted({names_mlc[i] for i in tree.tree_.feature if i >= 0})
    sections.append(f"Features usadas pela árvore C: {', '.join(used)}\n")

    header = (
        "# Fase 0: baseline com features + árvores (dataset público, só coleira)\n\n"
        "> Gerado por `ml/scripts/train_baseline.py`. Não editar à mão.\n\n"
        "Avaliação: **GroupKFold (5 folds) por cachorro**, ou seja, cada fold testa em cachorros "
        "que o modelo nunca viu (regra 2). Janelas de 2 s com passo de 1 s (contrato 4.3), rótulo "
        "pela regra do ADR 0002; janelas sem rótulo claro são descartadas. Dados saturados em "
        "±16 g / ±2000 dps (ADR 0005). Matrizes de confusão normalizadas por linha.\n\n"
    )
    OUT_MD.parent.mkdir(parents=True, exist_ok=True)
    OUT_MD.write_text(header + "\n".join(sections), encoding="utf-8")
    print("escrito:", OUT_MD)


if __name__ == "__main__":
    main()
