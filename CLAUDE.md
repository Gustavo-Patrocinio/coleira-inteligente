# CLAUDE.md: Coleira Inteligente com IA Embarcada

> Contexto do projeto para o Claude Code. Leia antes de qualquer tarefa neste repositório.
> Idioma: responda e documente em **português (BR)**. Código, nomes de variáveis e commits em inglês.

---

## 1. Visão geral

Coleira para cachorro com um sensor de movimento (IMU) e um microcontrolador que **reconhece o comportamento do cachorro dentro do próprio chip (TinyML)**: parado, andando, correndo, coçando, chacoalhando, comendo e bebendo. A coleira guarda resumos por minuto e sincroniza por BLE com um app, que envia os dados para um backend. O backend calcula o padrão normal de cada cachorro e gera alertas ("coçou 3× mais que o normal", "atividade 40% abaixo do padrão").

**Objetivo:** fazer do jeito certo, como produto, não como protótipo de faculdade. Cada decisão deve ser medida e documentada.

**Princípios:**
1. **Medir, não chutar:** acurácia com divisão honesta, consumo medido com medidor de corrente, autonomia medida em campo.
2. **Cada fase termina com algo funcionando** e um critério de pronto objetivo.
3. **Documentar decisões** em `docs/decisions/` (ADR curto: contexto, decisão, alternativas, consequência).
4. **Bem-estar do animal acima de tudo:** peso, conforto, irritação na pele e nada de forçar comportamento para coletar dado.

---

## 2. Arquitetura

```
┌──────────────────────── COLEIRA ────────────────────────┐
│ IMU (LSM6DSOX, MLC interno)                              │
│   ├─ nível 1: árvore de decisão no IMU → parado/movimento│
│   └─ FIFO + interrupção → acorda o MCU                   │
│ nRF52840 (Zephyr)                                        │
│   ├─ nível 2: CNN 1D int8 (TFLite Micro) → classes finas │
│   ├─ suavização temporal → resumo por minuto → flash     │
│   └─ BLE: sync em lote, dump bruto, OTA (MCUboot)        │
└──────────────────────────┬───────────────────────────────┘
                           │ BLE
┌──────────── APP (Flutter) ┴──────────────────────────────┐
│ coleta (vídeo + dados brutos), sync, telas de rotina      │
└──────────────────────────┬───────────────────────────────┘
                           │ HTTPS
┌──────────── BACKEND ─────┴───────────────────────────────┐
│ API TypeScript (Fastify + Zod) → Postgres + TimescaleDB   │
│ jobs: baseline por cachorro, detecção de anomalia, push   │
└───────────────────────────────────────────────────────────┘
```

---

## 3. Estrutura do repositório (monorepo)

```
coleira/
├── CLAUDE.md
├── README.md                 # vitrine: resultados, fotos, gráficos, decisões
├── ml/                       # Python: dados, treino, avaliação, quantização
│   ├── data/                 # NÃO versionado (.gitignore)
│   │   ├── public/           # dataset público
│   │   ├── raw/              # sessões coletadas (csv + vídeo)
│   │   └── labels/           # rótulos exportados
│   ├── notebooks/            # exploração (numerados: 01_explore.ipynb...)
│   ├── src/coleira_ml/       # código reutilizável (janelas, features, modelos)
│   ├── models/               # artefatos exportados (.tflite, .h)
│   └── tests/
├── firmware/                 # Zephyr / nRF Connect SDK
│   ├── app/                  # aplicação principal
│   ├── logger/               # firmware coletor (Fase 1)
│   ├── boards/               # overlays (XIAO, depois a PCB própria)
│   └── west.yml              # versão do SDK fixada
├── app/                      # Flutter
├── backend/                  # TypeScript (Fastify)
│   ├── src/
│   ├── migrations/           # SQL puro (hypertables, continuous aggregates)
│   └── tests/
├── tools/
│   └── labeler/              # ferramenta web de rotulagem (HTML/JS + uPlot)
├── hardware/
│   ├── cad/                  # caixa (fontes + STL/STEP)
│   └── pcb/                  # KiCad (Fase 6)
└── docs/
    ├── decisions/            # ADRs
    ├── energy-budget.md      # orçamento de energia medido
    ├── results.md            # acurácia por fase, matrizes de confusão
    └── protocols/            # protocolo de coleta, de rotulagem
```

---

## 4. Contratos (não mudar sem ADR)

### 4.1 Classes (IDs estáveis)

| ID | Classe | Fase em que entra |
|----|--------|-------------------|
| 0 | `parado` (deitado, sentado, em pé, dormindo, farejar parado; ADR 0004) | 0 |
| 1 | `andando` (inclui farejar andando) | 0 |
| 2 | `correndo` (trote e galope) | 0 |
| 3 | `cocando` | 1–2 |
| 4 | `chacoalhando` | 1–2 |
| 5 | `comendo` | 6 |
| 6 | `bebendo` | 6 |
| 255 | `desconhecido` / transição | — |

Os IDs **nunca** são reaproveitados nem reordenados. Classe nova ganha ID novo.

### 4.2 Amostragem do IMU
- 50 Hz, acelerômetro ±8 g e giroscópio ±2000 dps (chacoalhar gera rotação muito rápida).
- Montagem: embaixo do pescoço, sempre na mesma orientação física (marcada na caixa).

### 4.3 Janela do modelo
- 2 s = 100 amostras, sobreposição de 50% (passo de 1 s).
- Entrada: 7 canais = ax, ay, az, gx, gy, gz e magnitude do acelerômetro.
- Saída: probabilidades por classe.
- Suavização (ADR 0002):
  - classes de estado (0, 1, 2, 5, 6): maioria nas últimas 5 janelas;
  - classes de evento (3, 4): evento confirmado com prob. ≥ `p_evento` em ≥ `n_min` janelas consecutivas (calibrados na Fase 2); o evento tem prioridade sobre o estado.
- Rótulo da janela no treino: classe com ≥ 70% das amostras; para 3 e 4, basta ≥ 50% ou ≥ 1 s contínuo. Fora disso, a janela é descartada ou rotulada 255.

### 4.4 Pacote BLE de dados brutos (Fase 1), little-endian

| Offset | Tipo | Campo |
|--------|------|-------|
| 0 | uint8 | `version` (=1) |
| 1 | uint8 | `type` (0x01 = raw) |
| 2 | uint16 | `seq` (contador de pacotes, dá a volta) |
| 4 | uint32 | `device_ms` (uptime da 1ª amostra) |
| 8 | int16 × 6 × N | amostras (ax, ay, az, gx, gy, gz), N = 10 |

Tamanho: 8 + 120 = 128 bytes → exige MTU ≥ 131.

O app grava cada pacote com `phone_ts` de recebimento. Dentro do pacote, o tempo da amostra i = `device_ms` + i × 20 ms. Entre pacotes, **não** se supõe ODR exato: a taxa real é estimada por regressão de `device_ms` e o alinhamento com o vídeo usa batidinhas no início e no fim, com correção linear (ADR 0003).

### 4.5 CSV de sessão bruta (`ml/data/raw/<session_id>/imu.csv`)
`phone_ts_ms, device_ms, seq, ax, ay, az, gx, gy, gz` (valores crus em int16; a escala fica no `meta.json`)

`meta.json`: `session_id, dog_id, device_id, start_phone_ts, video_file, video_start_phone_ts_ms, accel_range, gyro_range, odr_hz, location, surface, notes, sync_taps`

`sync_taps` = `{start_video_ms, end_video_ms, start_device_ms, end_device_ms}`, preenchido pelo labeler depois do alinhamento (ADR 0003).

### 4.6 CSV de rótulos (`ml/data/labels/<session_id>.csv`)
`start_ms, end_ms, class_id, annotator, confidence` (tempo relativo ao início do vídeo)

### 4.7 Resumo por minuto (flash → BLE → backend)
Little-endian, v1 (ADR 0001):

| Offset | Tipo | Campo |
|--------|------|-------|
| 0 | uint8 | `version` (=1) |
| 1 | uint32 | `minute_ts` (epoch s, UTC) |
| 5 | uint8 × 7 | `seconds_per_class[0..6]` |
| 12 | uint8 | `unknown_s` |
| 13 | uint8 | `battery_pct` |
| 14 | uint8 | `flags` |

= 15 bytes/min, ~21 KB/dia. Invariante: `sum(seconds_per_class) + unknown_s ≤ 60`. Classe nova → `version` novo.

---

## 5. Stack e convenções

| Parte | Stack | Convenções |
|-------|-------|------------|
| ML | Python 3.12, `uv`, numpy, pandas, scipy, scikit-learn, PyTorch, TFLite (conversão int8) | `ruff` + `pytest`; notebooks só exploram, lógica fica em `src/` |
| Firmware | Zephyr via nRF Connect SDK (versão fixada no `west.yml`), C, TFLite Micro, MCUboot | Kconfig no `prj.conf`; zero `printk` em release; consumo medido a cada mudança relevante |
| App | Flutter, `flutter_blue_plus`, `camera` | Lógica BLE isolada num serviço testável |
| Backend | Node + TypeScript, Fastify, Zod, `pg`/Kysely, Postgres 16 + TimescaleDB | Migrations em SQL puro; ingestão idempotente (`ON CONFLICT DO NOTHING`) |
| Labeler | HTML + JS puro, uPlot | Sem build step; abre direto no navegador |
| Hardware | CAD (caixa), KiCad (PCB) | Exportar STEP + STL a cada versão |

**Commits:** Conventional Commits (`feat(firmware): ...`, `fix(ml): ...`).

---

## 6. Regras para o Claude

1. **Nunca** versionar `ml/data/`, vídeos ou modelos grandes. Conferir o `.gitignore`.
2. **Divisão treino/teste sempre por grupo** (cachorro no dataset público; sessão/dia nos dados próprios). Divisão aleatória por janela é proibida, porque infla a acurácia.
3. Não alterar os contratos da seção 4 sem criar um ADR.
4. Todo firmware a partir da Fase 3 mantém **OTA funcionando**; uma mudança que quebre a atualização é bloqueante.
5. Ao reportar resultado de modelo, mostrar sempre: acurácia balanceada, F1 por classe, matriz de confusão, tamanho (KB) e RAM de inferência.
6. Consumo de energia só é afirmado com medição (PPK2) e registrado em `docs/energy-budget.md`.
7. Preferir soluções simples e explicar o porquê; o projeto também é de aprendizado.
8. Ao terminar uma tarefa de fase, atualizar o checklist abaixo.

---

## 7. Plano por fases

### Fase 0: pipeline de ML com dataset público (sem hardware)
**Objetivo:** provar o pipeline completo e ter um modelo inicial.

- [x] Setup `ml/` com `uv`, ruff e pytest
- [ ] Baixar o dataset público: Kumpulainen et al. (2021), *"Dog behaviour classification with movement sensors placed on the harness and the collar"* (Mendeley Data). Conferir no README dele a lista exata de classes e a frequência. Se houver rótulos de chacoalhar/comer/beber/farejar, guardar o mapeamento para pré-treinar as classes 3–6 depois
- [ ] Usar **só o sensor da coleira**
- [ ] Notebook `01_explore`: plotar trechos de cada comportamento
- [ ] Reamostrar para 50 Hz; mapear as classes do dataset para os IDs 0–2
- [ ] Janelamento (2 s, 50%); rótulo da janela pela regra da seção 4.3 (≥ 70%; regra especial para eventos curtos)
- [ ] Augmentation: rotação 3D aleatória dos eixos, pequeno ruído e variação de escala
- [ ] `GroupKFold` por cachorro
- [ ] Baseline: features (média, desvio, mín, máx, energia, frequência dominante FFT, magnitude) + Random Forest **raso**
- [ ] Variante "compatível com MLC": árvore rasa usando só as features que o MLC da ST calcula (média, variância, energia, pico a pico, cruzamentos por zero, mín/máx, filtros; **sem FFT**). É ela que vai para o IMU na Fase 5
- [ ] CNN 1D pequena (ex.: 3× [Conv1D k=5 → ReLU → MaxPool], 16/32/32 filtros → GAP → Dense)
- [ ] Quantizar para int8; comparar a acurácia float vs int8
- [ ] `docs/results.md`: tabela modelo × acurácia balanceada × F1 × KB

**Pronto quando:** CNN int8 com acurácia balanceada ≥ 85% em 3 classes, em cachorros não vistos, ocupando < 64 KB.

---

### Fase 1: coleta e rotulagem com o seu cachorro
**Objetivo:** 2–3 h de dados próprios sincronizados com vídeo, incluindo coçar e chacoalhar.

**Hardware:**
- [ ] Seeed XIAO nRF52840 Sense (IMU de 6 eixos + microfone + carregador embutidos). O IMU dela é um LSM6DS3TR-C, **sem MLC**. O MLC só chega com a troca de IMU na Fase 5
- [ ] Sonda SWD (J-Link EDU Mini ou Raspberry Pi Pico como debugprobe): debug no Zephyr e, na Fase 3, gravação do MCUboot no lugar do bootloader UF2 de fábrica
- [ ] LiPo 3,7 V ~250 mAh com proteção (PCM), soldada nos pads BAT+/BAT− embaixo da XIAO (a placa não tem conector JST)
- [ ] Caixa provisória impressa em 3D, com a orientação marcada

**Firmware `firmware/logger/`:**
- [ ] Leitura do IMU a 50 Hz (driver Zephyr; conferir o modelo exato do IMU da placa)
- [ ] Serviço GATT próprio, característica com notify, pacote da seção 4.4
- [ ] Negociação de MTU ≥ 131 (+ Data Length Extension); contador `seq` para detectar perda
- [ ] Plano B: se o Zephyr travar por mais de 1 fim de semana, fazer o logger em Arduino (core Seeed + ArduinoBLE) mantendo o mesmo formato de pacote

**App de coleta (`app/`, modo coleta):**
- [ ] Conectar na coleira, filmar e gravar o CSV ao mesmo tempo (seção 4.5)
- [ ] Gerar o `meta.json` da sessão (incluindo `video_start_phone_ts_ms`)
- [ ] Exportar a sessão (compartilhar ou copiar para o PC)

**Protocolo (`docs/protocols/coleta.md`):**
- [ ] Adaptação: alguns dias usando a coleira sem gravar; conferir a pele
- [ ] Sincronização: 3 batidinhas na caixa na frente da câmera no **início e no fim** de cada sessão (ADR 0003)
- [ ] Sessões de 10–20 min: dormindo, passeio com guia, brincadeira, ração, água
- [ ] Sessões longas para capturar comportamentos espontâneos (coçar); gravar depois do banho (chacoalhar)
- [ ] Variar dias, horários e pisos

**Ferramenta de rotulagem `tools/labeler/`:**
- [ ] Carregar vídeo + CSV; gráfico uPlot com cursor sincronizado ao vídeo
- [ ] Alinhamento usando as batidinhas do início e do fim (offset + correção de deriva linear); gravar `sync_taps` no `meta.json`
- [ ] Atalhos de teclado para marcar início/fim por classe
- [ ] Exportar no formato da seção 4.6

**Fechamento:**
- [ ] Rodar o modelo da Fase 0 nos dados próprios e registrar a queda (domain gap) em `docs/results.md`

**Pronto quando:** ≥ 2 h rotuladas, ≥ 3 min acumulados de cada classe 0–4, perda de pacotes < 1%.

---

### Fase 2: modelo rodando no chip (ainda no USB)
**Objetivo:** classificação ao vivo dentro do nRF batendo com o vídeo.

- [ ] Fine-tuning: pré-treino no público + ajuste nos dados próprios (classes 0–4)
- [ ] Avaliação dividida por sessão/dia
- [ ] Exportar `.tflite` int8 → array C (`models/`)
- [ ] `firmware/app/`: integrar TFLite Micro; definir o tamanho do tensor arena
- [ ] Medir o tempo de inferência e a RAM usada
- [ ] Suavização conforme a seção 4.3: maioria para estados, detecção de evento para 3–4; calibrar `p_evento`/`n_min` em sessão de validação; teste unitário com sequências sintéticas
- [ ] Teste ao vivo: classe impressa na serial vs vídeo, numa sessão nova

**Pronto quando:** F1 ≥ 0,85 nas classes 0–2 e ≥ 0,70 em coçar/chacoalhar numa sessão nunca vista; inferência < 50 ms.

---

### Fase 3: autonomia sem fio
**Objetivo:** um dia inteiro registrado só com bateria.

- [ ] MCUboot + DFU por BLE (OTA) funcionando **antes** do resto (gravar o MCUboot via SWD, já que a XIAO vem com bootloader UF2 da Adafruit)
- [ ] Resumo por minuto (seção 4.7) gravado em flash (buffer circular, ex.: ZMS/NVS ou partição própria)
- [ ] Serviço BLE de sync: o app pede "desde o minuto X" e recebe o lote
- [ ] Modo dump bruto, ativável pelo app (para continuar coletando dataset)
- [ ] Relógio: o app envia a hora atual ao conectar; a coleira mantém
- [ ] App: tela de rotina do dia (linha do tempo por classe), sync ao abrir
- [ ] Primeira medição de consumo com PPK2 → `docs/energy-budget.md`

**Pronto quando:** 24 h seguidas registradas sem fio, sync sem perda nem duplicata, OTA testada.

---

### Fase 4: backend e alertas
**Objetivo:** o sistema entende o que é normal para cada cachorro e avisa quando foge disso.

- [ ] Postgres + TimescaleDB via Docker Compose
- [ ] Tabelas: `users`, `dogs`, `devices`, `activity_minute` (hypertable), `alerts`
- [ ] Continuous aggregates por hora e por dia
- [ ] API Fastify + Zod: auth (JWT), CRUD de cachorros/dispositivos, `POST /ingest` em lote **idempotente** (chave `device_id + minute_ts`)
- [ ] Endpoints de consulta: rotina do dia, tendências da semana/mês
- [ ] Job de baseline: por cachorro × hora do dia × (dia útil/fim de semana), janela de 28 dias, **mediana + MAD**
- [ ] Alertas por z-score robusto (|z| > 3) para atividade total, tempo coçando e chacoalhões; exigir ≥ 14 dias de histórico antes de alertar
- [ ] Push via Firebase Cloud Messaging
- [ ] Testes: ingestão duplicada, buracos no sync, fuso horário
- [ ] App: telas de tendência e de alertas

**Pronto quando:** um alerta real dispara corretamente com dados do seu cachorro; ingestão repetida não duplica.

---

### Fase 5: energia de verdade (classificação em dois níveis)
**Objetivo:** autonomia de semanas.

- [ ] Trocar para o IMU com Machine Learning Core (LSM6DSOX ou LSM6DSV16X) num breakout
- [ ] Treinar uma árvore rasa "parado vs movimento" com features suportadas pelo MLC; gerar a configuração (ferramentas da ST)
- [ ] MCU em sleep profundo; acorda por interrupção do MLC
- [ ] Enquanto parado, o MCU nem roda a CNN: só contabiliza tempo `parado`
- [ ] FIFO do IMU em lote para reduzir os despertares
- [ ] Ajustar o intervalo de advertising/conexão BLE
- [ ] Medidor de carga (MAX17048) → bateria real no app
- [ ] Medir com PPK2 cada modo: sleep, ativo, inferência, sync

**Metas (a validar com medição):**

| Modo | Meta de consumo médio |
|------|-----------------------|
| Parado (só o MLC + sleep) | < 50 µA |
| Em movimento (CNN ativa) | < 1 mA |
| Média do dia | < 200 µA → semanas com ~250 mAh |

**Pronto quando:** autonomia medida em campo ≥ 14 dias.

---

### Fase 6: produto
**Objetivo:** algo que você usaria todo dia.

- [ ] Caixa definitiva: vedação IP67 (anel de vedação), PETG/SLA + camada externa em TPU contra impacto e mordida
- [ ] Carregamento magnético por pogo pins (sem USB exposta)
- [ ] Peso < 3% do peso do cachorro; centro de massa embaixo do pescoço
- [ ] PCB própria no KiCad: módulo nRF52840 + IMU com MLC + carregador + medidor de carga + antena conforme a referência do módulo. Preferir módulo **já homologado na Anatel**: muda pouco o custo e simplifica muito a homologação do produto
- [ ] (Opcional) Fusão com áudio para `comendo`/`bebendo` (classes 5–6), ativando o microfone só quando o IMU indicar cabeça baixa + movimento leve
- [ ] README final: fotos, vídeo de demo, gráficos de acurácia e de energia, decisões

**Pronto quando:** coleira vedada rodando no dia a dia por 1 mês sem intervenção.

---

## 8. Lista de materiais (protótipo)

| Item | Fase | Observação |
|------|------|------------|
| Seeed XIAO nRF52840 Sense | 1 | Protótipo principal |
| LiPo 3,7 V 150–300 mAh com PCM | 1 | Soldada nos pads BAT+/BAT− (XIAO não tem JST); conferir a polaridade com multímetro |
| Sonda SWD (J-Link EDU Mini ou Pico debugprobe) | 1 | Debug; obrigatória para gravar o MCUboot (Fase 3) |
| Filamento PETG + TPU | 1/6 | Caixa |
| Nordic Power Profiler Kit II (PPK2) | 3 | Essencial para medir consumo |
| Breakout LSM6DSOX ou LSM6DSV16X | 5 | Machine Learning Core |
| Breakout MAX17048 | 5 | Medidor de carga |
| Pogo pins magnéticos (2 ou 4 pinos) | 6 | Carregamento vedado |
| Anel de vedação (o-ring) | 6 | Dimensionar no CAD |

---

## 9. Riscos e mitigação

| Risco | Mitigação |
|-------|-----------|
| Rotulagem cansativa → projeto para | Ferramenta própria com atalhos; sessões curtas; dataset público cobre o básico |
| Acurácia inflada por divisão errada | Regra 2 da seção 6, sem exceção |
| Coleira gira no pescoço | Augmentation de rotação + canal de magnitude + caixa com peso embaixo |
| Classes raras com poucos exemplos | Coleta contínua com o modo dump; class weights; aceitar F1 menor nelas no início |
| Zephyr com curva íngreme | Plano B em Arduino só no logger; samples oficiais da Nordic como base |
| BLE em segundo plano no iOS | Sync ao abrir o app; buffer de dias na flash |
| Água/mordida | Fase 6; até lá, uso supervisionado |
| Eventos curtos (chacoalhar) somem na suavização | Suavização por classe com detecção de evento (ADR 0002) |
| Deriva de relógio desalinha IMU e vídeo | Batidinhas no início e no fim + correção linear (ADR 0003) |
| Desconforto do cachorro | Adaptação gradual, peso mínimo, checar a pele, parar se houver incômodo |

---

## 10. Status atual

- **Fase atual:** 0
- **Próxima tarefa:** download do dataset público (Kumpulainen et al., 2021) e notebook `01_explore`
- **Hardware:** XIAO nRF52840 Sense + Raspberry Pi Pico H encomendados (AliExpress, previsão 27/nov–04/dez/2026); bateria, jumpers e kit de solda a comprar no Brasil
