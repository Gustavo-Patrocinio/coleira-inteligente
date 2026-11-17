# Indicadores para o dono (o que o app mostra)

Decidido em 2026-11-16, a partir do protótipo do app
(https://claude.ai/artifact/GAd3E31xRtwBfqTvKXkJyu, privado).

Critério: só entra na tela principal o que responde uma pergunta que o dono realmente faz
e que leva a alguma ação. Todo número é comparado com o **normal do próprio cachorro**
(baseline da Fase 4), nunca com uma regra geral.

| Indicador | Pergunta do dono | Como é calculado | Fase |
|---|---|---|---|
| **Exercício** | "Ele gastou energia hoje?" | minutos `andando` + `correndo` no dia | 3 |
| **Noite** | "Ele dormiu tranquilo?" | nº de vezes que saiu de `parado` por ≥ 1 min entre 23h e 6h, mais os minutos ativos nesse intervalo | 3 |
| **Pele** | "Está se coçando mais?" | minutos e episódios de `cocando` | 3 (depende da Fase 1–2) |
| **Algo diferente** | "Ele está apático ou mudou?" | alertas por z-score robusto contra o baseline | 4 |
| **Água** | "Está bebendo muito mais?" | minutos de `bebendo` | 6 |

## O que NÃO vai para a tela principal

- **Chacoalhões:** continuam sendo uma classe do modelo (um movimento forte que ele precisa
  reconhecer para não confundir com outros), mas o número sozinho não leva a nenhuma ação.
  Ficam disponíveis só no detalhe do dia.
- **"Horas de sono":** o acelerômetro não distingue dormindo de deitado acordado. Por isso
  o indicador é *agitação noturna*, e não duração do sono. Não prometer o que não medimos.

## Ideias para depois

- **Balançar a cabeça** (classe nova, ID 7+): sinal clássico de otite, com valor clínico
  maior que o chacoalhão de corpo inteiro. Exige coleta e ADR.
- Compartilhar um resumo com o veterinário (página web usando a API da Fase 4).
