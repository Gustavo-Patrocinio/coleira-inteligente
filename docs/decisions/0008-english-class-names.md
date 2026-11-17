# ADR 0008: English class names (IDs unchanged)

- **Status:** accepted
- **Date:** 2026-11-16
- **Contract affected:** section 4.1 (names only)

## Context

The whole project (code, docs, UI) is now written in English. Class names in contract 4.1
were Portuguese (`parado`, `andando`, ...), and the code used them as identifiers.

## Decision

Rename the classes. **IDs do not change**, so every stored record, label file and model
output stays valid.

| ID | Old name | New name |
|----|----------|----------|
| 0 | `parado` | `still` |
| 1 | `andando` | `walking` |
| 2 | `correndo` | `running` |
| 3 | `cocando` | `scratching` |
| 4 | `chacoalhando` | `shaking` |
| 5 | `comendo` | `eating` |
| 6 | `bebendo` | `drinking` |
| 255 | `desconhecido` | `unknown` |

## Consequences

Only names in code, docs and UI change. Data formats are keyed by ID, so nothing needs
migrating.
