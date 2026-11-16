"""Avaliação honesta: validação cruzada por grupo (regra 2 do CLAUDE.md).

Cada fold deixa cachorros inteiros de fora, então o modelo é sempre testado em
cachorros que ele nunca viu. Divisão aleatória por janela é proibida: janelas vizinhas
do mesmo cachorro são quase iguais e inflariam a acurácia.
"""

from __future__ import annotations

from collections.abc import Callable
from dataclasses import dataclass

import numpy as np
from sklearn.metrics import balanced_accuracy_score, confusion_matrix, f1_score
from sklearn.model_selection import GroupKFold


@dataclass
class CVResult:
    labels: list[int]
    fold_balanced_acc: list[float]
    f1_per_class: dict[int, float]
    confusion: np.ndarray  # linhas = verdade, colunas = predito (out-of-fold, somado)
    y_true: np.ndarray
    y_pred: np.ndarray

    @property
    def balanced_acc_mean(self) -> float:
        return float(np.mean(self.fold_balanced_acc))

    @property
    def balanced_acc_std(self) -> float:
        return float(np.std(self.fold_balanced_acc))


def group_cv(
    make_model: Callable[[], object],
    F: np.ndarray,
    y: np.ndarray,
    groups: np.ndarray,
    n_splits: int = 5,
) -> CVResult:
    labels = sorted(int(c) for c in np.unique(y))
    y_pred = np.empty_like(y)
    fold_bacc = []
    for train, test in GroupKFold(n_splits=n_splits).split(F, y, groups):
        assert not set(groups[train]) & set(groups[test]), "vazamento de grupo entre folds"
        model = make_model()
        model.fit(F[train], y[train])
        y_pred[test] = model.predict(F[test])
        fold_bacc.append(balanced_accuracy_score(y[test], y_pred[test]))
    f1 = f1_score(y, y_pred, labels=labels, average=None)
    return CVResult(
        labels=labels,
        fold_balanced_acc=fold_bacc,
        f1_per_class=dict(zip(labels, map(float, f1), strict=True)),
        confusion=confusion_matrix(y, y_pred, labels=labels),
        y_true=y,
        y_pred=y_pred,
    )


def tree_nodes(model: object) -> int:
    """Total de nós de uma árvore ou floresta do scikit-learn."""
    trees = getattr(model, "estimators_", [model])
    return int(sum(t.tree_.node_count for t in trees))


# Estimativa até exportarmos de verdade: por nó, índice da feature (1 B) + limiar
# float32 (4 B) + 2 filhos int16 (4 B) + folga/alinhamento → ~10 B.
BYTES_PER_NODE_ESTIMATE = 10
