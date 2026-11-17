# ADR 0010: Logger sampling clock and GATT service

- **Status:** accepted
- **Date:** 2026-11-16
- **Contracts affected:** sections 4.2 and 4.4 (implementation details added, formats unchanged)

## Context

Contract 4.2 asks for 50 Hz, but the XIAO's LSM6DS3TR-C only offers 12.5 / 26 / 52 /
104 Hz (and higher) output data rates, not 50 Hz. The raw packet (4.4) also needs a GATT service and
characteristic that the app, the PC recorder and later the base station can find.

## Decision

**Sampling:**
- The IMU runs at **104 Hz** (accel ±16 g, gyro ±2000 dps) with its internal filtering.
- A kernel timer on the MCU reads the latest sample every **20 ms**. The 50 Hz rate comes
  from the nRF52840's 32.768 kHz crystal (±20 ppm), not from the IMU's oscillator.
- With the default 32768 Hz tick, 20 ms is 655 ticks = 19.989 ms (≈ 50.03 Hz). We accept
  this: `device_ms` is the real uptime of the first sample of each packet, and downstream
  code estimates the real rate by regression (ADR 0003).
- Samples go through Zephyr's generic sensor API (m/s², rad/s) and are converted back to
  int16 at the contract's full scale, so swapping the IMU (Phase 5) does not change the
  packet code.
- The logger samples only while a client is subscribed to notifications (saves power).

**GATT:**

| Item | UUID |
|---|---|
| Raw data service | `c01a0000-7e3b-4c5e-9d2a-5f1e8b6a2c10` |
| Raw data characteristic (notify, contract 4.4 packets) | `c01a0001-7e3b-4c5e-9d2a-5f1e8b6a2c10` |

- Device name in advertising: `Collar-Logger`; the service UUID is in the scan response so
  clients can filter.
- On connect the logger requests MTU 247, data length 251, 2M PHY and a 15–30 ms connection
  interval. A packet (128 B) is only sent if the negotiated MTU allows it (≥ 131).
- `seq` increments for every packet **created**, so packets dropped on the collar (queue
  full) also show up as gaps on the receiving side.

## Alternatives

- **IMU at 52 Hz, data-ready interrupt:** simpler timing, but 4% faster than the contract
  and paced by the IMU's less accurate oscillator.
- **Resample 52 → 50 Hz on the MCU:** more code and CPU for no real benefit.
- **Read raw IMU registers directly:** a bit cheaper, but ties the code to one IMU model.

## Consequences

The ≈ 50.03 Hz rate is visible in the labeler's "measured ODR" and handled by ADR 0003.
The UUIDs are now part of the raw-data interface: changing them needs an ADR.
