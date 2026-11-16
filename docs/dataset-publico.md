# Dataset público: Movement Sensor Dataset for Dog Behavior Classification

- **Fonte:** Mendeley Data, DOI [10.17632/vxhx934tbn.4](https://data.mendeley.com/datasets/vxhx934tbn) (versão 4, nov/2025)
- **Citar (pedido dos autores):**
  - Vehkaoja et al. (2022). *Description of movement sensor dataset for dog behavior classification.* Data in Brief 40, 107822.
  - Kumpulainen et al. (2021). *Dog behaviour classification with movement sensors placed on the harness and the collar.* Applied Animal Behaviour Science 241, 105393.
- **Licença:** CC BY 4.0, segundo os espelhos (forskning.fi). Falta confirmar na página do Mendeley.
- **Download:** `cd ml && uv run python scripts/download_public.py`, que confere o SHA-256 e extrai em `ml/data/public/` (pasta fora do git).

## O que tem dentro (medido em 2026-11-16)

- **45 cachorros, 62 testes** (alguns cachorros fizeram 2), 10,6 milhões de linhas.
- **100 Hz**, ActiGraph GT9X Link, com dois sensores: costas (peitoral) e **pescoço (coleira)**. Usamos só o do pescoço (`ANeck_*`, `GNeck_*`).
- Unidades aparentes: acelerômetro em **g**, giroscópio em **°/s**. As faixas de fundo de escala do GT9X ainda não foram confirmadas.
- O cabeçalho do CSV é `ANeck_x, ANeck_y`, mas o `Data_description.txt` lista `ANeck_y` antes de `ANeck_x`. Valem os nomes do cabeçalho.
- Até **3 rótulos simultâneos** por amostra (`Behavior_1..3`). Em 28% das amostras há 2 ou mais rótulos (ex.: `Panting` junto de uma postura).
- Coluna `Task` = tarefa pedida ao cachorro (sit, stand, walk, trot, play, lie down, treat-search). **Não é rótulo**: o rótulo é o `Behavior_*`.

### Minutos por comportamento (somando as 3 colunas)

| Comportamento | min | Classe nossa (proposta) |
|---|---:|---|
| Panting | 296 | ignorar (sobreposto a uma postura) |
| Lying chest | 188 | 0 `parado` |
| Sitting | 187 | 0 `parado` |
| Standing | 171 | 0 `parado` |
| Sniffing | 171 | 0 ou 1, conforme o deslocamento (ADR 0004) |
| Playing | 156 | 255 (movimento variado, não é uma classe nossa) |
| Walking | 131 | 1 `andando` |
| Trotting | 129 | 2 `correndo` |
| Eating | 52 | 5 `comendo` (Fase 6) |
| Tugging | 50 | 255 |
| Galloping | 29 | 2 `correndo` |
| Carrying object | 24 | 255 |
| Pacing | 13 | 1 `andando` (andadura lateral; a confirmar) |
| Drinking | 11 | 6 `bebendo` (Fase 6) |
| **Shaking** | **7** | **4 `chacoalhando`** |
| Jumping | 7 | 255 |
| Synchronization / Bowing / Extra_Sync | 3 | 255 |
| `<undefined>` | 3680 | 255 |

## Consequências para o plano

- **Tem chacoalhar (7 min), comer (52 min) e beber (11 min).** Dá para pré-treinar as classes 4–6 com dados públicos antes da coleta própria.
- **Não tem coçar.** A classe 3 depende 100% da coleta própria (Fase 1).
- `correndo` fica desbalanceado internamente: galope (29 min) é bem mais raro que trote (129 min).
- O mapeamento final, inclusive as regras para rótulos simultâneos, fica em código (`coleira_ml`) com teste, e não só nesta tabela.
