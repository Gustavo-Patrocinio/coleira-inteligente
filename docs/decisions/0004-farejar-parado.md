# ADR 0004: classe de "farejar parado"

- **Status:** aceito
- **Data:** 2026-11-16
- **Contrato afetado:** seção 4.1

## Contexto

A classe 1 (`andando`) inclui "farejar andando", mas "farejar parado" (cachorro
parado no lugar, cabeça baixa, mexendo o focinho) não tinha classe. O dataset público
rotula farejar separadamente, então o mapeamento precisa ser explícito.

## Decisão

"Farejar parado" vai para a classe **0 (`parado`)**. O critério da classe 0 é "sem
deslocamento", e não "sem movimento da cabeça". No dataset público, os trechos de
farejar com deslocamento vão para 1, e os sem deslocamento vão para 0. Quando não der
para separar, vão para 255.

## Alternativas

- **Classe nova `farejando`:** útil no futuro (enriquecimento ambiental), mas mais uma
  classe difícil logo de início. Se for criada, ganha ID novo (7+) e não altera 0/1.
- **Mandar para 255:** perde muito dado, já que cachorro fareja o tempo todo.

## Consequência

A classe 0 fica mais variada e o modelo precisa tolerar movimento de cabeça nela.
Isso pode aproximá-la de `comendo`/`bebendo` (5–6) na Fase 6, e esse ponto deve ser
reavaliado nessa fase.
