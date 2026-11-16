# ADR 0002: suavização por classe e janelas de eventos curtos

- **Status:** aceito
- **Data:** 2026-11-16
- **Contrato afetado:** seção 4.3

## Contexto

O contrato previa suavização por maioria nas últimas 5 janelas (passo de 1 s) para
todas as classes, e o plano da Fase 0 mandava descartar toda janela com rótulo misto.

Um chacoalhão dura ~1–2 s e um coçar curto dura poucos segundos. Esses eventos ocupam
1–2 das 5 janelas, então **nunca ganham a maioria** e somem do resumo. Pelo mesmo motivo,
quase nenhuma janela de 2 s fica 100% "chacoalhando", e o descarte por rótulo misto
eliminaria a maior parte dos exemplos da classe mais rara.

## Decisão

**Suavização, em duas regras:**
- Classes de estado (0 `parado`, 1 `andando`, 2 `correndo`, e depois 5, 6):
  maioria nas últimas 5 janelas.
- Classes de evento (3 `cocando`, 4 `chacoalhando`): detecção de evento. O evento é
  confirmado quando a probabilidade da classe é ≥ `p_evento` em ≥ `n_min` janelas
  consecutivas (valores iniciais: `p_evento = 0,6`, `n_min = 1` para chacoalhar e 2 para
  coçar). Esses limiares são calibrados na Fase 2 com dados próprios. O evento confirmado
  tem prioridade sobre a classe de estado naqueles segundos.

**Rótulo da janela (treino e avaliação):**
- A janela recebe a classe que cobre ≥ 70% das amostras. Abaixo disso, é descartada
  (ou rotulada 255).
- Para as classes 3 e 4, também se aceitam janelas em que o evento cobre ≥ 50% das
  amostras **ou** ≥ 1 s contínuo (o que vier primeiro).

## Alternativas

- **Janela menor (1 s) para tudo:** dobra as inferências e piora as classes de estado.
- **Modelo separado para eventos:** mais preciso, mas custa mais flash e RAM. Fica para
  reavaliar se o F1 de 3 e 4 não chegar a 0,70.

## Consequência

O firmware tem dois caminhos de pós-processamento, que precisam de teste unitário com
sequências sintéticas. O treino passa a ter uma função de rotulagem de janela
parametrizável em `coleira_ml`.
