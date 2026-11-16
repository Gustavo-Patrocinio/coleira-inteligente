# Coleira Inteligente com IA Embarcada

Coleira para cachorro que reconhece comportamentos (parado, andando, correndo, coçando,
chacoalhando, comendo, bebendo) **dentro do próprio chip** (TinyML num nRF52840),
guarda resumos por minuto e sincroniza por BLE com um app. O backend aprende o padrão
normal de cada cachorro e avisa quando algo foge dele.

> 🚧 Em desenvolvimento: **Fase 0** (pipeline de ML com dataset público).

## Estrutura

| Pasta | Conteúdo |
|-------|----------|
| `ml/` | Python: dados, treino, avaliação, quantização |
| `firmware/` | Zephyr / nRF Connect SDK |
| `app/` | Flutter |
| `backend/` | TypeScript (Fastify) + Postgres/TimescaleDB |
| `tools/labeler/` | Ferramenta web de rotulagem (vídeo + IMU) |
| `hardware/` | CAD da caixa e PCB |
| `docs/` | Decisões (ADRs), resultados, energia, protocolos |

O plano completo, os contratos de dados e o checklist por fase ficam em [`CLAUDE.md`](CLAUDE.md).

## ML: como rodar

```bash
cd ml
uv sync          # cria o ambiente (Python 3.12) e instala dependências
uv run pytest    # testes
uv run ruff check .
```

## Resultados

Ainda não há resultados. Eles vão ficar em [`docs/results.md`](docs/results.md).
