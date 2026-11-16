"""Protege o contrato 4.1: se este teste quebrar, alguém mudou um ID estável."""

from coleira_ml.classes import (
    EVENT_CLASSES,
    N_SUMMARY_CLASSES,
    STATE_CLASSES,
    Behavior,
)


def test_class_ids_are_stable():
    assert {b.name: b.value for b in Behavior} == {
        "PARADO": 0,
        "ANDANDO": 1,
        "CORRENDO": 2,
        "COCANDO": 3,
        "CHACOALHANDO": 4,
        "COMENDO": 5,
        "BEBENDO": 6,
        "DESCONHECIDO": 255,
    }


def test_event_and_state_classes_partition_known_classes():
    known = {b for b in Behavior if b is not Behavior.DESCONHECIDO}
    assert EVENT_CLASSES | STATE_CLASSES == known
    assert not EVENT_CLASSES & STATE_CLASSES


def test_summary_covers_all_known_classes():
    assert N_SUMMARY_CLASSES == len([b for b in Behavior if b is not Behavior.DESCONHECIDO])
