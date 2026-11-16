# ADR 0001: byte de versão no resumo por minuto

- **Status:** aceito
- **Data:** 2026-11-16
- **Contrato afetado:** seção 4.7

## Contexto

O resumo por minuto foi especificado como "15 bytes/min", mas os campos somavam 14
(4 + 7 + 1 + 1 + 1). Além disso, o layout tinha exatamente 7 contadores de classe.
Se uma classe nova entrar (ID 7+), o backend não teria como saber se um registro
antigo usa o layout de 7 ou de 8 classes, já que os registros ficam dias na flash
e podem chegar depois de um OTA.

## Decisão

Adicionar `version (uint8)` no offset 0. O registro v1 tem 15 bytes:

| Offset | Tipo | Campo |
|--------|------|-------|
| 0 | uint8 | `version` (=1) |
| 1 | uint32 | `minute_ts` (epoch s, UTC) |
| 5 | uint8 × 7 | `seconds_per_class[0..6]` |
| 12 | uint8 | `unknown_s` |
| 13 | uint8 | `battery_pct` |
| 14 | uint8 | `flags` |

Invariante: `sum(seconds_per_class) + unknown_s <= 60`.
Tamanho: 15 B × 1440 = 21 600 B/dia (~21 KB).

## Alternativas

- **Corrigir só o texto para 14 bytes:** mais simples, mas trava o formato em 7 classes.
- **Versão por lote de sync, e não por registro:** economiza 1 B/min, mas quebra quando
  a flash tem registros de antes e de depois de um OTA no mesmo lote.

## Consequência

+1 B/min (~1,4 KB/dia). O backend escolhe o parser pelo `version`. Uma classe nova
vira `version = 2` com outro layout, e os registros antigos continuam legíveis.
