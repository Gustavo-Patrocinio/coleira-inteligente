# ADR 0013: Per-minute summary storage and BLE sync protocol

- **Status:** accepted
- **Date:** 2026-11-17
- **Contracts affected:** new section 4.8 (sync GATT service); 4.7 `flags` bits defined

## Context

Phase 3 stores the per-minute summary (contract 4.7) in flash and lets a client (the phone
app or the home base station, ADR 0007) fetch "everything since minute X". The collar has no
battery-backed clock: it only knows the time after a client tells it.

## Decision

**Time.** The client writes the current epoch time on every connection. Until then the collar
keeps the last 2 h of per-second labels in RAM and stamps them when the time arrives, so a
reboot away from home loses at most what happened more than 2 h before the next sync.

**Storage.** One flash element per minute (FCB, Zephyr's flash circular buffer) on a 416 KB
storage partition (code 0x27000–0x8BFFF, storage 0x8C000–0xF3FFF, Adafruit UF2 bootloader
untouched): about 13–14 days of minutes. When full, the oldest sector is dropped. Phase 3's
MCUboot work will redo this layout (Partition Manager) and must keep ≥ 7 days of storage.

**GATT sync service** (contract 4.8):

| Characteristic | UUID | Properties | Payload (little-endian) |
|---|---|---|---|
| Service | `c01a0100-7e3b-4c5e-9d2a-5f1e8b6a2c10` | | |
| Time | `c01a0101-…` | write | `uint32 epoch_s` |
| Control | `c01a0102-…` | write | `0x01, uint32 since_minute_ts` → send records with `minute_ts ≥ since`; `0x02` → send status |
| Data | `c01a0103-…` | notify | `k × 15-byte records` (contract 4.7), `k = min(16, ⌊(MTU−3)/15⌋)` |
| Status | `c01a0104-…` | read, notify | 16 bytes: `uint8 kind` (0x80 info, 0x81 sync done), `uint8 clock_set`, `uint8 battery_pct`, `uint8 reserved`, `uint32 count`, `uint32 oldest_minute_ts`, `uint32 newest_minute_ts` |

A sync is: connect → write Time → subscribe to Data and Status → write Control `0x01, X` →
receive Data notifications → Status `0x81` with the number of records sent. The client then
uploads the raw records to `POST /v1/ingest` (idempotent, so re-sending is harmless) and
remembers the newest `minute_ts` it uploaded as the next X.

**Flags (contract 4.7 `flags`):** bit 0 = battery level not measured (until the fuel gauge,
Phase 5); other bits reserved (0).

## Alternatives

- **Zephyr settings / NVS / ZMS key-value storage:** designed for configuration, not for a
  stream of thousands of small records.
- **Batching several minutes per flash element:** less overhead (~20%), but loses the
  unflushed batch on reset and complicates "since X".
- **Collar keeps its own clock across reboots (RTC battery, or saving time to flash):** adds
  hardware or drift handling; the 2 h RAM buffer covers the realistic gap.

## Consequences

Clients need the same sequence (app now, base station in Phase 4). The firmware never
re-emits a minute it already stored, even if the clock is corrected later.
