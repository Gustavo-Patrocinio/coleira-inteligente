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

| Comportamento | min | Classe nossa |
|---|---:|---|
| Panting | 296 | ignorado (sobreposto a uma postura) |
| Lying chest | 188 | 0 `parado` |
| Sitting | 187 | 0 `parado` |
| Standing | 171 | 0 `parado` |
| Sniffing | 171 | 255: **sempre** aparece sozinho, sem postura ou andadura, então não dá para separar parado de andando (ADR 0004) |
| Playing | 156 | contexto: com andadura vale a andadura; sozinho, 255 |
| Walking | 131 | 1 `andando` |
| Trotting | 129 | 2 `correndo` |
| Eating | 52 | 5 `comendo` (Fase 6) |
| Tugging | 50 | 255 |
| Galloping | 29 | 2 `correndo` |
| Carrying object | 24 | contexto (igual a Playing) |
| Pacing | 13 | 1 `andando` (andadura lateral; a confirmar) |
| Drinking | 11 | 6 `bebendo` (Fase 6) |
| **Shaking** | **7** | **4 `chacoalhando`** |
| Jumping | 7 | 255 |
| Synchronization / Bowing / Extra_Sync | 3 | 255 |
| `<undefined>` | 3680 | 255 |

### Rótulos simultâneos: o que aparece junto

Combinações que guiaram as regras de `coleira_ml.public_dataset.map_label_set`:

- **Galope quase nunca aparece sozinho** (0,6 min). Aparece com `Playing` (13,6 min) ou
  `Playing + Carrying object` (14,9 min). Se `Playing` derrubasse a amostra para 255,
  perderíamos o galope inteiro. Por isso `Playing`/`Carrying object` são *contexto*.
- `Eating` aparece com postura (`Standing` 19 min, `Lying chest` 14, `Sitting` 13): vira 5.
  Com andadura (6 min): vira 255.
- O tempo é contínuo: todas as amostras estão a exatos 10 ms, sem buracos dentro de um teste.

### Depois do mapeamento + reamostragem a 50 Hz

| Classe | min | cães |
|---|---:|---:|
| 0 `parado` | 500,2 | 45 |
| 1 `andando` | 139,0 | 45 |
| 2 `correndo` | 156,0 | 45 |
| 4 `chacoalhando` | 7,0 (286 eventos, mediana de 1,4 s) | 45 |
| 5 `comendo` | 45,7 | 42 |
| 6 `bebendo` | 10,8 | 35 |
| 255 | 909,9 | — |

### Faixa do sensor

O dataset tem picos de ~19 g e ~2470 °/s. **35% das amostras de chacoalhar passam de 8 g**,
o que motivou o ADR 0005 (acelerômetro em ±16 g). O loader satura os dados na faixa do nosso
IMU (±16 g, ±2000 dps) para o treino ficar parecido com a coleira real.

Exploração com gráficos: `ml/notebooks/01_explore.ipynb`.

## Consequências para o plano

- **Tem chacoalhar (7 min), comer (52 min) e beber (11 min).** Dá para pré-treinar as classes 4–6 com dados públicos antes da coleta própria.
- **Não tem coçar.** A classe 3 depende 100% da coleta própria (Fase 1).
- `correndo` fica desbalanceado internamente: galope (29 min) é bem mais raro que trote (129 min).
- O mapeamento está implementado e testado em `coleira_ml.public_dataset` (`map_label_set`).
