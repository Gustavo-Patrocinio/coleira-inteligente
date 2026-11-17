"""Summary sync protocol (contract 4.8 / ADR 0013) and the 15-byte record (contract 4.7).

Shared by the PC base-station emulator (scripts/sync_ble.py) and tests; mirrors
firmware/app/src/ble_sync.c, backend/src/summary.ts and app/lib/core/summary_record.dart.
"""

from __future__ import annotations

import struct
from dataclasses import dataclass

SERVICE_UUID = "c01a0100-7e3b-4c5e-9d2a-5f1e8b6a2c10"
TIME_UUID = "c01a0101-7e3b-4c5e-9d2a-5f1e8b6a2c10"
CONTROL_UUID = "c01a0102-7e3b-4c5e-9d2a-5f1e8b6a2c10"
DATA_UUID = "c01a0103-7e3b-4c5e-9d2a-5f1e8b6a2c10"
STATUS_UUID = "c01a0104-7e3b-4c5e-9d2a-5f1e8b6a2c10"
DEVICE_NAME = "Collar"

RECORD_SIZE = 15
KIND_INFO = 0x80
KIND_SYNC_DONE = 0x81
FLAG_BATTERY_NOT_MEASURED = 0x01

_RECORD = struct.Struct("<BI7BBBB")
_STATUS = struct.Struct("<BBBBIII")


@dataclass(frozen=True)
class MinuteRecord:
    minute_ts: int
    seconds: tuple[int, ...]  # 7 values, class IDs 0..6
    unknown_s: int
    battery_pct: int
    flags: int

    @property
    def total(self) -> int:
        return sum(self.seconds) + self.unknown_s


@dataclass(frozen=True)
class Status:
    kind: int
    clock_set: bool
    battery_pct: int
    count: int
    oldest_minute_ts: int
    newest_minute_ts: int


def time_payload(epoch_s: int) -> bytes:
    return struct.pack("<I", epoch_s)


def send_since_payload(since_minute_ts: int) -> bytes:
    return struct.pack("<BI", 0x01, since_minute_ts)


STATUS_REQUEST = b"\x02"


def parse_status(buf: bytes) -> Status:
    if len(buf) != _STATUS.size:
        raise ValueError(f"status must be {_STATUS.size} bytes, got {len(buf)}")
    kind, clock, battery, _, count, oldest, newest = _STATUS.unpack(buf)
    return Status(kind, bool(clock), battery, count, oldest, newest)


def split_records(buf: bytes) -> list[bytes]:
    """One Data notification → its 15-byte records (raw bytes, as uploaded to the backend)."""
    if len(buf) % RECORD_SIZE:
        raise ValueError(f"data notification of {len(buf)} bytes is not whole records")
    return [buf[i : i + RECORD_SIZE] for i in range(0, len(buf), RECORD_SIZE)]


def decode_record(raw: bytes) -> MinuteRecord:
    version, ts, *rest = _RECORD.unpack(raw)
    if version != 1:
        raise ValueError(f"unsupported record version {version}")
    return MinuteRecord(ts, tuple(rest[:7]), rest[7], rest[8], rest[9])


def encode_record(r: MinuteRecord) -> bytes:
    return _RECORD.pack(1, r.minute_ts, *r.seconds, r.unknown_s, r.battery_pct, r.flags)
