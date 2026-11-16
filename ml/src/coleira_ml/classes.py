"""Classes de comportamento: contrato 4.1 do CLAUDE.md.

IDs são estáveis: nunca reaproveitar nem reordenar. Classe nova ganha ID novo (e ADR).
"""

from enum import IntEnum


class Behavior(IntEnum):
    PARADO = 0  # deitado, sentado, em pé, dormindo, farejar parado (ADR 0004)
    ANDANDO = 1  # inclui farejar andando
    CORRENDO = 2  # trote e galope
    COCANDO = 3
    CHACOALHANDO = 4
    COMENDO = 5
    BEBENDO = 6
    DESCONHECIDO = 255  # transição / não rotulável


# Classes de evento curto: suavização por detecção de evento (ADR 0002).
EVENT_CLASSES: frozenset[Behavior] = frozenset({Behavior.COCANDO, Behavior.CHACOALHANDO})

# Classes de estado: suavização por maioria nas últimas 5 janelas (ADR 0002).
STATE_CLASSES: frozenset[Behavior] = frozenset(
    b for b in Behavior if b is not Behavior.DESCONHECIDO and b not in EVENT_CLASSES
)

# Número de contadores no resumo por minuto v1 (contrato 4.7 / ADR 0001).
N_SUMMARY_CLASSES = 7
