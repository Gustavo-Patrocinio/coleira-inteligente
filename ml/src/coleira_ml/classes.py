"""Behavior classes: contract 4.1 in CLAUDE.md (names: ADR 0008).

IDs are stable: never reuse or reorder them. A new class gets a new ID (and an ADR).
"""

from enum import IntEnum


class Behavior(IntEnum):
    STILL = 0  # lying, sitting, standing, sleeping, stationary sniffing (ADR 0004)
    WALKING = 1  # includes sniffing while walking
    RUNNING = 2  # trot and gallop
    SCRATCHING = 3
    SHAKING = 4
    EATING = 5
    DRINKING = 6
    UNKNOWN = 255  # transition / not labelable


# Short-event classes: smoothed by event detection (ADR 0002).
EVENT_CLASSES: frozenset[Behavior] = frozenset({Behavior.SCRATCHING, Behavior.SHAKING})

# State classes: smoothed by majority over the last 5 windows (ADR 0002).
STATE_CLASSES: frozenset[Behavior] = frozenset(
    b for b in Behavior if b is not Behavior.UNKNOWN and b not in EVENT_CLASSES
)

# Number of class counters in the v1 per-minute summary (contract 4.7 / ADR 0001).
N_SUMMARY_CLASSES = 7
