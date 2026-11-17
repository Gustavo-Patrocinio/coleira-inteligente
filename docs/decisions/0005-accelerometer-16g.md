# ADR 0005: Accelerometer at ±16 g

- **Status:** accepted
- **Date:** 2026-11-16
- **Contract affected:** section 4.2

## Context

The contract set the accelerometer to ±8 g. In the public dataset (collar, resampled to
50 Hz), **35% of `shaking` samples exceed 8 g** on some axis, peaking at ~19 g. In other
classes this barely happens: 105 samples in `running` and 2 in `still`. At ±8 g the sensor
would saturate during exactly the event class we most want to detect.

The gyroscope exceeds 2000 °/s in ~9% of shaking samples. Both the LSM6DS3TR-C (XIAO) and
the LSM6DSOX (Phase 5) top out at 2000 °/s, so there is no higher range to pick.

## Decision

- Accelerometer at **±16 g** (0.488 mg/LSB as int16).
- Gyroscope stays at **±2000 dps**; we accept saturation in part of the shaking samples.
  A saturated signal is still very distinct from the other classes.
- The public-dataset loader **simulates our IMU's saturation** (clip at ±16 g and
  ±2000 dps, before and after resampling), so training data looks like the collar's.

## Alternatives

- **Keep ±8 g:** 0.24 mg resolution, which does not help (sensor noise is larger than
  that), and loses the shape of the shake peak.
- **LSM6DSV16X (gyro up to 4000 dps) in Phase 5:** possible. Revisit if gyro saturation
  hurts the F1 of `shaking`.

## Consequences

`accel_range` in `meta.json` becomes 16. The logger firmware and the app use the ±16 g
scale. The MLC (Phase 5) must also be configured at ±16 g, since the tree's features and
thresholds depend on the scale.
