# Resultados

Resumo de todos os modelos. Os detalhes de cada experimento (F1 por classe, matriz de
confusão, folds) ficam nos relatórios gerados em `docs/results/`.

Regras (seção 6 do CLAUDE.md): avaliação sempre **por grupo** (cachorro / sessão), e todo
resultado traz acurácia balanceada, F1 por classe, matriz de confusão, tamanho e RAM.

## Fase 0: dataset público, só coleira, cachorros não vistos (GroupKFold 5×)

| Modelo | Classes | Acur. balanceada | F1 (por classe) | Tamanho | RAM | Relatório |
|---|---|---:|---|---:|---:|---|
| RF raso (50 árv., prof. ≤ 8) | 0, 1, 2 | **0,956 ± 0,013** | parado 0,99 · andando 0,90 · correndo 0,96 | ~64 KB* | ~1,7 KB* | [A](results/fase0_baseline.md) |
| RF raso (50 árv., prof. ≤ 8) | 0, 1, 2, 4 | 0,960 ± 0,013 | … · chacoalhando 0,93 | ~52 KB* | ~1,7 KB* | [B](results/fase0_baseline.md) |
| Árvore MLC (prof. ≤ 4, sem FFT) | parado × movimento | 0,986 ± 0,004 | parado 0,99 · movimento 0,98 | 29 nós | — | [C](results/fase0_baseline.md) |
| CNN 1D float (com augmentation) | 0, 1, 2 | 0,957 ± 0,010 | | 8,4 mil parâm. | | [D](results/fase0_cnn.md) |
| **CNN 1D int8 (com augmentation)** ✅ | 0, 1, 2 | **0,957 ± 0,010** | parado 0,99 · andando 0,91 · correndo 0,95 | **18,8 KB** (.tflite) | ~2,3 KB* (ativações) | [D](results/fase0_cnn.md) |
| CNN 1D int8, teste com coleira **girada** | 0, 1, 2 | 0,957 ± 0,010 (sem aug: **0,779**) | | | | [D](results/fase0_cnn.md) |

\* Estimativas: tamanho ≈ 10 B por nó de árvore; RAM = janela int16 + |a| + vetor de
features. Os números medidos de verdade vêm quando exportarmos para o firmware (Fase 2).

### Leitura (2026-11-16)

- ✅ **Meta da Fase 0 batida:** CNN int8 com **0,957** de acurácia balanceada em cachorros
  não vistos (meta ≥ 0,85), ocupando **18,8 KB** (meta < 64 KB).
- **Int8 não perdeu nada** em relação ao float (diferença < 0,002 em todos os folds).
- **Augmentation é o que garante robustez à rotação:** sem ele, girar a coleira derruba a
  acurácia de 0,966 para **0,779**; com ele, fica em 0,957 nos dois casos. Custa ~1 ponto
  no teste original e vale a pena, porque coleira gira no pescoço. O modelo oficial usa augmentation.
- **A CNN empata com o RF (0,956) sendo 3× menor** e sem features escolhidas à mão.
- **A maior confusão é andando → correndo (8%).** Passo rápido e trote lento são vizinhos.
- **Chacoalhar: F1 0,93 com só 390 janelas.** É um sinal bem distinto (ver `01_explore`).
- **Árvore do MLC: 98,6% com 29 nós**, o que viabiliza o nível 1 da Fase 5 (o MCU dorme
  enquanto o IMU decide "parado"). ⚠️ Ela usa features de eixos específicos (`ay`, `az`),
  que dependem da orientação da coleira. Precisa ser retreinada com rotação aleatória e
  validada nos dados próprios antes de ir para o IMU.
- ⚠️ **Tudo isso é no dataset público** (outro sensor, outra montagem, cachorros treinados
  em ambiente controlado). A queda nos dados do seu cachorro (domain gap) só será medida na Fase 1.
