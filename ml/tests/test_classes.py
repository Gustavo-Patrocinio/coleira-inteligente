"""Guards contract 4.1: if this test breaks, someone changed a stable ID."""

from coleira_ml.classes import (
    EVENT_CLASSES,
    N_SUMMARY_CLASSES,
    STATE_CLASSES,
    Behavior,
)


def test_class_ids_are_stable():
    assert {b.name: b.value for b in Behavior} == {
        "STILL": 0,
        "WALKING": 1,
        "RUNNING": 2,
        "SCRATCHING": 3,
        "SHAKING": 4,
        "EATING": 5,
        "DRINKING": 6,
        "UNKNOWN": 255,
    }


def test_event_and_state_classes_partition_known_classes():
    known = {b for b in Behavior if b is not Behavior.UNKNOWN}
    assert EVENT_CLASSES | STATE_CLASSES == known
    assert not EVENT_CLASSES & STATE_CLASSES


def test_summary_covers_all_known_classes():
    assert N_SUMMARY_CLASSES == len([b for b in Behavior if b is not Behavior.UNKNOWN])
