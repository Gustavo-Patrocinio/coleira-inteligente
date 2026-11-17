# ADR 0003: Session time sync (IMU × video)

- **Status:** accepted
- **Date:** 2026-11-16
- **Contracts affected:** sections 4.4 and 4.5

## Context

Each sample's time was computed as `device_ms + i × 20 ms`, assuming the IMU ODR is
exactly 50 Hz. The IMU's internal oscillator can be off by a few percent, and the phone and
video clocks drift too. Over a 20-minute session, a 1% error is 12 s of drift, longer than
an entire shake.

`meta.json` was also missing the moment the video started on the phone's clock, even
though labels (4.6) are relative to the start of the video.

## Decision

1. **Measured rate:** the ML code and the labeler estimate the real IMU rate by linear
   regression of `device_ms` (from each packet) against the sample index. `i × 20 ms` is
   only used inside a packet. Lost packets are accounted for through `seq`.
2. **Taps at the start and at the end** of each session (3 at each end). The labeler aligns
   both and applies a linear correction (offset + scale) between IMU time and video time.
3. **New `meta.json` fields:**
   - `video_start_phone_ts_ms`: start of the video on the phone's clock.
   - `sync_taps`: `{ "start_video_ms", "end_video_ms", "start_device_ms", "end_device_ms" }`,
     filled in by the labeler after alignment (empty at collection time).

## Alternatives

- **Start taps only (fixed offset):** does not correct drift.
- **Per-sample timestamp from the IMU:** more precise, but makes the packet bigger and
  depends on driver support. A possible future improvement.

## Consequences

The collection protocol gets one more step at the end of each session. A session without
the end taps is still accepted, but marked `drift_corrected: false` in its notes and used
with care. Validated on a synthetic session: the labeler recovered a simulated 3009 ppm
drift exactly, with a 10 ms error at the taps.
