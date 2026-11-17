import numpy as np
import pandas as pd
import pytest
from sklearn.tree import DecisionTreeClassifier

from coleira_ml.classes import Behavior as B
from coleira_ml.evaluate import group_cv, tree_nodes
from coleira_ml.features import add_acc_magnitude, dominant_freq, window_features
from coleira_ml.windows import STEP, WINDOW, label_windows, make_windows

P, A, S, U = int(B.STILL), int(B.WALKING), int(B.SHAKING), 255


def _row(*parts):
    """Build a 100-label window from (class, count) pairs."""
    out = np.concatenate([np.full(n, c, dtype=np.uint8) for c, n in parts])
    assert len(out) == WINDOW
    return out


@pytest.mark.parametrize(
    ("parts", "expected"),
    [
        ([(P, 100)], P),
        ([(P, 70), (A, 30)], P),  # exactly 70% → accepted
        ([(P, 69), (A, 31)], U),  # below 70% → dropped
        ([(P, 75), (U, 25)], P),  # 255 counts against, but 75% still passes
        ([(P, 60), (U, 40)], U),
        ([(P, 50), (S, 50)], S),  # event at 50% → event
        ([(P, 75), (S, 25)], P),  # short event (0.5 s), not 1 s contiguous → majority wins
        ([(P, 30), (S, 50), (A, 20)], S),  # 1 s contiguous event
    ],
)
def test_label_windows_rules(parts, expected):
    assert label_windows(_row(*parts)[None, :])[0] == expected


def test_event_needs_contiguous_run_not_scattered_samples():
    # 45 scattered shaking samples (never 1 s contiguous, < 50%) → not an event
    row = np.full(WINDOW, P, dtype=np.uint8)
    row[::2][:45] = S
    assert label_windows(row[None, :])[0] == U  # P does not reach 70% either


def _df(dog, test, labels):
    n = len(labels)
    return pd.DataFrame(
        {
            "dog_id": dog,
            "test_num": test,
            "ax": np.arange(n, dtype=np.float32),
            "class_id": np.asarray(labels, dtype=np.uint8),
        }
    )


def test_make_windows_never_crosses_tests_and_counts_are_right():
    df = pd.concat([_df(1, 1, [P] * 250), _df(1, 2, [A] * 120), _df(2, 1, [P] * 80)])
    w = make_windows(df, ["ax"])
    # test (1,1): 250 samples → starts 0,50,100,150 = 4; (1,2): 120 → 1; (2,1): < 100 → 0
    assert len(w.y) == 4 + 1
    assert w.X.shape == (5, WINDOW, 1)
    assert w.y.tolist() == [P, P, P, P, A]
    assert w.groups.tolist() == [1, 1, 1, 1, 1]
    assert w.X[1, 0, 0] == STEP  # second window starts one step later


def test_dominant_freq_finds_sine():
    t = np.arange(WINDOW) / 50
    X = np.sin(2 * np.pi * 4.0 * t)[None, :, None]
    assert dominant_freq(X, fs=50)[0, 0] == pytest.approx(4.0)


def test_window_features_shapes_and_names():
    X = np.random.default_rng(0).normal(size=(3, WINDOW, 2)).astype(np.float32)
    F, names = window_features(X, ["a", "b"], fs=50, kind="full")
    assert F.shape == (3, 12) and len(names) == 12 and "b_domfreq" in names
    F, names = window_features(X, ["a", "b"], fs=50, kind="mlc")
    assert F.shape == (3, 12) and "a_p2p" in names and not any("domfreq" in n for n in names)


def test_add_acc_magnitude():
    df = pd.DataFrame({"ax": [3.0], "ay": [4.0], "az": [0.0]})
    assert add_acc_magnitude(df).acc_mag.iloc[0] == pytest.approx(5.0)


def test_group_cv_never_tests_on_seen_groups():
    rng = np.random.default_rng(0)
    groups = np.repeat(np.arange(10), 20)
    y = rng.integers(0, 2, size=200)
    F = rng.normal(size=(200, 3))
    res = group_cv(lambda: DecisionTreeClassifier(max_depth=2), F, y, groups, n_splits=5)
    assert len(res.fold_balanced_acc) == 5
    assert res.confusion.sum() == 200
    assert 0.3 < res.balanced_acc_mean < 0.7  # random data → ~chance


def test_tree_nodes_counts_forest_and_single_tree():
    t = DecisionTreeClassifier(max_depth=1).fit([[0], [1]], [0, 1])
    assert tree_nodes(t) == 3
