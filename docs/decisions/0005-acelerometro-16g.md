# ADR 0005: acelerômetro em ±16 g

- **Status:** aceito
- **Data:** 2026-11-16
- **Contrato afetado:** seção 4.2

## Contexto

O contrato fixava o acelerômetro em ±8 g. No dataset público (coleira, reamostrado a
50 Hz), **35% das amostras de `chacoalhando` passam de 8 g** em algum eixo, com pico de
~19 g. Nas outras classes isso quase não acontece: 105 amostras em `correndo` e 2 em `parado`.
Com ±8 g, o sensor saturaria justamente na classe de evento que mais queremos detectar.

O giroscópio passa de 2000 °/s em ~9% das amostras de chacoalhar. O LSM6DS3TR-C (XIAO) e
o LSM6DSOX (Fase 5) têm 2000 °/s como máximo, então não há como subir.

## Decisão

- Acelerômetro em **±16 g** (resolução 0,488 mg/LSB em int16).
- Giroscópio continua em **±2000 dps** e aceitamos a saturação em parte do chacoalhar.
  Um sinal saturado continua muito distinto das outras classes.
- O loader do dataset público **simula a saturação** do nosso IMU (clip em ±16 g e
  ±2000 dps, antes da reamostragem), para os dados de treino ficarem parecidos com os da coleira.

## Alternativas

- **Manter ±8 g:** resolução de 0,24 mg, mas ela não ajuda (o ruído do sensor é maior que
  isso) e perde a forma do pico do chacoalhar.
- **LSM6DSV16X (giro até 4000 dps) na Fase 5:** possível. Reavaliar se a saturação do
  giroscópio prejudicar o F1 de `chacoalhando`.

## Consequência

`accel_range` no `meta.json` passa a ser 16. Firmware do logger e app usam a escala
de ±16 g. O MLC (Fase 5) também precisa ser configurado em ±16 g, já que as features e
limiares da árvore dependem da escala.
