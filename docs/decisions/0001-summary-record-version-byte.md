# ADR 0001: Version byte in the per-minute summary

- **Status:** accepted
- **Date:** 2026-11-16
- **Contract affected:** section 4.7

## Context

The per-minute summary was specified as "15 bytes/min", but its fields added up to 14
(4 + 7 + 1 + 1 + 1). The layout also had exactly 7 class counters. If a new class (ID 7+)
were added, the backend would have no way to tell whether an old record used the 7- or
8-class layout. Records stay in flash for days and can arrive after an OTA update.

## Decision

Add `version (uint8)` at offset 0. A v1 record is 15 bytes:

| Offset | Type | Field |
|--------|------|-------|
| 0 | uint8 | `version` (=1) |
| 1 | uint32 | `minute_ts` (epoch s, UTC) |
| 5 | uint8 × 7 | `seconds_per_class[0..6]` |
| 12 | uint8 | `unknown_s` |
| 13 | uint8 | `battery_pct` |
| 14 | uint8 | `flags` |

Invariant: `sum(seconds_per_class) + unknown_s <= 60`.
Size: 15 B × 1440 = 21,600 B/day (~21 KB).

## Alternatives

- **Just fix the text to say 14 bytes:** simpler, but locks the format to 7 classes.
- **Version per sync batch instead of per record:** saves 1 B/min, but breaks when flash
  holds records from before and after an OTA update in the same batch.

## Consequences

+1 B/min (~1.4 KB/day). The backend picks the parser by `version`. A new class (or a new
field, such as the sleeping respiratory rate) becomes `version = 2` with another layout,
and old records stay readable.
