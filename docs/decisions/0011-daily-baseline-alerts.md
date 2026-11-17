# ADR 0011: Alerts on daily totals against a same-day-type baseline

- **Status:** accepted
- **Date:** 2026-11-17
- **Affects:** Phase 4 (baseline job and alerts)

## Context

The plan described a baseline "per dog × hour of day × (weekday/weekend), 28 days, median +
MAD" and alerts by robust z-score for total activity, scratching and night restlessness.
The alerts themselves are about **days** ("scratched 3× more than usual today"), and an
hourly baseline does not turn into a daily z-score cleanly (summing hourly medians is not
the median of daily totals, and hourly spreads do not add).

## Decision

- **Daily metrics** per dog and local day (dog's IANA time zone): coverage (minutes with
  data), active seconds (walking + running), scratching seconds, and night wake-ups (episodes
  of ≥ 20 s/min walking or running between 23:00 and 06:00, credited to the morning).
- **Baseline** for a day: median and MAD of the same metric over the previous 28 days, using
  only days of the same type (weekday / weekend) when there are ≥ 6 of them, else all days.
- **Alert:** robust z = (x − median) / max(1.4826 · MAD, floor) with |z| > 3 for activity (both
  directions) and z > 3 for scratching and night wake-ups. Floors: 15 min, 1 min, 1 wake-up.
- **Guards:** ≥ 14 days of history with ≥ 20 h of data each; the evaluated day must also have
  ≥ 20 h of data, so a sync gap never looks like a lethargic dog.
- The hourly continuous aggregate stays (it feeds the app's per-hour views); an hourly
  "normal band" for the timeline can be added later from it.

## Alternatives

- **Hourly baseline as planned:** better for "unusual at this hour" views, but not what the
  alerts need; more data required before it is stable.
- **Mean + standard deviation:** simpler, but one wild day (a trip, a party) distorts it;
  median + MAD resists that.

## Consequences

Simple, testable rules (`backend/src/metrics.ts`, unit-tested). Floors and thresholds will be
tuned with real data and the "false alarm" feedback stored on each alert.
