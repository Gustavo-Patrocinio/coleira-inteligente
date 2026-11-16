# ADR 0003: sincronização de tempo das sessões (IMU × vídeo)

- **Status:** aceito
- **Data:** 2026-11-16
- **Contratos afetados:** seções 4.4 e 4.5

## Contexto

O tempo de cada amostra era calculado como `device_ms + i × 20 ms`, ou seja, supondo
que o ODR do IMU é exatamente 50 Hz. O oscilador interno do IMU pode errar alguns %,
e o relógio do celular e o do vídeo também derivam. Numa sessão de 20 min, um erro de
1% dá 12 s de deriva, maior que um chacoalhão inteiro.

Faltava também no `meta.json` o instante em que o vídeo começou no relógio do celular,
sendo que os rótulos (4.6) são relativos ao início do vídeo.

## Decisão

1. **Taxa real medida:** o ML/labeler estima a taxa real do IMU por regressão linear de
   `device_ms` (de cada pacote) contra o índice da amostra. O `i × 20 ms` vale só dentro
   do pacote. O cálculo fica em `coleira_ml` e é reaproveitado pelo labeler.
2. **Batidinhas no início e no fim** de cada sessão (3 em cada ponta). O labeler alinha
   as duas e aplica uma correção linear (offset + escala) entre o tempo do IMU e o do vídeo.
3. **Novos campos no `meta.json`:**
   - `video_start_phone_ts_ms`: início do vídeo no relógio do celular.
   - `sync_taps`: `{ "start_video_ms", "end_video_ms", "start_device_ms", "end_device_ms" }`,
     preenchido pelo labeler depois do alinhamento (vazio na coleta).

## Alternativas

- **Só as batidinhas do início (offset fixo):** não corrige a deriva.
- **Timestamp por amostra vindo do IMU:** mais preciso, mas aumenta o pacote e depende
  do suporte do driver. Fica como melhoria futura.

## Consequência

O protocolo de coleta ganha um passo no fim da sessão. Uma sessão sem as batidinhas
finais é aceita, mas marcada `drift_corrected: false` nas notas e usada com cautela.
