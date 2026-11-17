# ADR 0004: Class for stationary sniffing

- **Status:** accepted
- **Date:** 2026-11-16
- **Contract affected:** section 4.1

## Context

Class 1 (`walking`) includes sniffing while walking, but sniffing in place (dog standing
still, head down, moving its nose) had no class. The public dataset labels sniffing
separately, so the mapping has to be explicit.

## Decision

Stationary sniffing goes to class **0 (`still`)**. The criterion for class 0 is "no
displacement", not "no head movement". In the public dataset, sniffing with displacement
goes to 1 and sniffing without displacement goes to 0. When they cannot be told apart,
it goes to 255.

**Update (2026-11-16):** in the public dataset, `Sniffing` never appears together with a
posture or gait label (171 min, always alone). By the rule above, all of it goes to 255.
In our own data, label stationary sniffing as 0 from the start.

## Alternatives

- **A new `sniffing` class:** useful later (environmental enrichment), but one more hard
  class right at the start. If created, it gets a new ID (7+) and does not change 0/1.
- **Send it to 255:** loses a lot of data, since dogs sniff all the time.

## Consequences

Class 0 becomes more varied, and the model has to tolerate head movement in it. This may
bring it closer to `eating`/`drinking` (5–6) in Phase 6; revisit then.
