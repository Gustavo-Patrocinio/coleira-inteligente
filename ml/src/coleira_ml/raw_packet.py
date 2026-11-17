"""Raw BLE data packet (contract 4.4) and the session CSV rows built from it (contract 4.5).

Packet, little-endian:
    offset 0  uint8   version (=1)
    offset 1  uint8   type (0x01 = raw)
    offset 2  uint16  seq (wraps around)
    offset 4  uint32  device_ms (uptime of the first sample)
    offset 8  int16 × 6 × 10  samples (ax, ay, az, gx, gy, gz)
"""

from __future__ import annotations

import struct
from dataclasses import dataclass

import numpy as np

VERSION = 1
TYPE_RAW = 0x01
SAMPLES_PER_PACKET = 10
CHANNELS = 6
HEADER = struct.Struct("<BBHI")
PACKET_SIZE = HEADER.size + SAMPLES_PER_PACKET * CHANNELS * 2  # 128
SAMPLE_PERIOD_MS = 20  # nominal; the real rate is estimated downstream (ADR 0003)

# GATT (ADR 0010)
SERVICE_UUID = "c01a0000-7e3b-4c5e-9d2a-5f1e8b6a2c10"
RAW_CHAR_UUID = "c01a0001-7e3b-4c5e-9d2a-5f1e8b6a2c10"
DEVICE_NAME = "Collar-Logger"

CSV_HEADER = ["phone_ts_ms", "device_ms", "seq", "ax", "ay", "az", "gx", "gy", "gz"]


@dataclass(frozen=True)
class RawPacket:
    seq: int
    device_ms: int
    samples: np.ndarray  # (10, 6) int16


def parse(buf: bytes) -> RawPacket:
    """Parse one packet; raises ValueError on anything that does not match contract 4.4."""
    if len(buf) != PACKET_SIZE:
        raise ValueError(f"expected {PACKET_SIZE} bytes, got {len(buf)}")
    version, ptype, seq, device_ms = HEADER.unpack_from(buf, 0)
    if version != VERSION:
        raise ValueError(f"unsupported packet version {version}")
    if ptype != TYPE_RAW:
        raise ValueError(f"unexpected packet type 0x{ptype:02x}")
    samples = np.frombuffer(buf, dtype="<i2", offset=HEADER.size).reshape(
        SAMPLES_PER_PACKET, CHANNELS
    )
    return RawPacket(seq=seq, device_ms=device_ms, samples=samples.astype(np.int16))


def pack(seq: int, device_ms: int, samples: np.ndarray) -> bytes:
    """Build a packet (used by tests and simulators; the firmware does the same in C)."""
    s = np.asarray(samples, dtype="<i2").reshape(SAMPLES_PER_PACKET, CHANNELS)
    return HEADER.pack(VERSION, TYPE_RAW, seq & 0xFFFF, device_ms & 0xFFFFFFFF) + s.tobytes()


def csv_rows(pkt: RawPacket, phone_ts_ms: int) -> list[list[int]]:
    """Contract 4.5 rows: one per sample, device_ms = packet device_ms + i × 20 ms."""
    return [
        [phone_ts_ms, pkt.device_ms + i * SAMPLE_PERIOD_MS, pkt.seq, *map(int, row)]
        for i, row in enumerate(pkt.samples)
    ]


class LossCounter:
    """Counts received vs expected packets from `seq` (handles the uint16 wrap-around)."""

    def __init__(self) -> None:
        self.first: int | None = None
        self.last_unwrapped = 0
        self.received = 0

    def add(self, seq: int) -> None:
        if self.first is None:
            self.first = self.last_unwrapped = seq
        else:
            prev = self.last_unwrapped
            cand = (prev & ~0xFFFF) | seq
            if cand < prev - 0x8000:
                cand += 0x10000
            self.last_unwrapped = cand
        self.received += 1

    @property
    def expected(self) -> int:
        return 0 if self.first is None else self.last_unwrapped - self.first + 1

    @property
    def loss(self) -> float:
        return 0.0 if not self.expected else 1 - self.received / self.expected
