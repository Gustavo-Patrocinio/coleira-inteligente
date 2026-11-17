# ADR 0014: Raw dump mode in the collar firmware

- **Status:** accepted
- **Date:** 2026-11-17
- **Contracts affected:** none (reuses 4.4 and the ADR 0010 GATT service unchanged)

## Context

The model keeps improving only if we keep collecting labeled sessions (Phase 1 protocol), from
more dogs and from users who opt in (Phase 6). Until now that needed the logger firmware: flash
the logger, collect, flash the collar firmware back. Owners will never do that, and with
MCUboot (Phase 3) every reflash is an OTA round trip.

## Decision

The collar firmware (`firmware/app`) also serves the logger's raw data service (ADR 0010,
service `c01a0000-…`, notify `c01a0001-…`, contract 4.4 packets). **Streaming runs only while
a client is subscribed to the notify characteristic.** Subscribing is the "on" switch, so the
phone app's collection mode works unchanged with either firmware; it now scans for the logger
service or the sync service (the collar advertises only the sync service: two 128-bit UUIDs do
not fit in one advertising packet; the raw service is found by GATT discovery).

- Recognition and the per-minute summary keep running during a dump: the sampler thread packs
  each 20 ms sample into packets as well as the model's ring buffer, and a lowest-priority
  sender thread notifies them, so a busy radio never delays sampling or inference.
- 5 s of packets are buffered; when full the oldest packet is dropped and the receiver sees a
  `seq` gap, exactly like a radio loss (ADR 0010).
- An I2C read error now repeats the previous sample in both paths instead of skipping it, so
  packet timing (`device_ms` + i × 20 ms) stays valid.

## Alternatives

- **A Control command (`0x03`/`0x04`) on the sync service** to start/stop: one more contract
  change, and the logger-based tools (`ml/scripts/record_ble.py`, the app) would need two code
  paths. Subscription already means "I want the data".
- **Keep the logger only:** simplest firmware, but kills opt-in collection from owners.

## Consequences

- Cost: ~2 KB flash, ~4 KB RAM (queue + sender stack). Power while streaming is higher
  (5 notifications/s); it only happens during supervised collection sessions.
- The logger firmware stays useful for bring-up and as the Arduino plan B reference.
