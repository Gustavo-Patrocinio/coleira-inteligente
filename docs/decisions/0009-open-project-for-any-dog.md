# ADR 0009: Open project for any dog first, product later

- **Status:** accepted
- **Date:** 2026-11-16
- **Affects:** goals (section 1), Phases 1, 2, 4, 6 and 7, data collection

## Context

The project started as a collar for one dog. The goal is now for **anyone** to be able to
use it. Two paths were considered:

- **A, open project:** anyone can build it from the docs (parts list, build guide,
  prebuilt firmware, published app) and use it with their own dog.
- **B, product:** a ready-made device sold to owners (custom PCB at volume, molded
  enclosure, Anatel certification, company, support, paid hosting).

## Decision

**A now, B later.** The project is developed as an open, DIY-buildable system (MIT
license) that must work for **any dog**, not just the author's. Path B stays a goal: when
choices are cheap to make product-ready (component availability, certifiable modules,
cost per unit), we prefer the product-ready option.

What "works for any dog" requires, and what changes in the plan:

1. **Data from many dogs.** A model trained on one dog learns that dog. Phase 1 collects
   from the author's dog **and at least 4 others** of different sizes; the app's
   collection mode lets any user contribute labeled sessions (opt-in, with consent) to
   reach 10–20+ dogs over time.
2. **Evaluation by dog on our own data too** (leave-one-dog-out), not only by session.
3. **Hardware that fits any collar and size:** universal clip, sealed case, simple
   charging, documented build.
4. **An app a non-technical owner can set up:** onboarding (pair collar, dog profile,
   base-station Wi-Fi), several dogs per account, iOS and Android.
5. **Privacy (LGPD):** consent for data use, export and deletion of one's data.
6. **No medical claims:** indicators are framed as "talk to your vet", never as diagnosis.
7. **A beta with other owners** before calling it done (new Phase 6).

## Alternatives

- **Personal project only:** simplest, but the user wants others to benefit.
- **Product first (B):** needs funding, certification and manufacturing before anything
  is proven; high risk of building the wrong thing.

## Consequences

- Phase 6 becomes "open release + beta"; the former Phase 6 (product hardening) becomes
  Phase 7 (path B).
- More collection effort in Phase 1 (other dogs, consent from their owners).
- Docs become a deliverable: build guide, flashing guide, troubleshooting.
- The backend must be self-hostable (Docker Compose) and also runnable as a shared
  instance for beta users.
