# Indicadores para o dono (o que o app mostra)

Decidido em 2026-11-16, a partir do protótipo do app
(https://claude.ai/artifact/GAd3E31xRtwBfqTvKXkJyu, privado).

Critério: só entra na tela principal o que responde uma pergunta que o dono realmente faz
e que leva a alguma ação. Todo número é comparado com o **normal do próprio cachorro**
(baseline da Fase 4), nunca com uma regra geral.

| Indicador | Pergunta do dono | Como é calculado | Fase |
|---|---|---|---|
| **Exercício** | "Ele gastou energia hoje?" | minutos `andando` + `correndo` no dia | 3 |
| **Sono** | "Ele dormiu bem?" | ver seção *Sono* abaixo (três níveis, do mais simples ao experimental) | 3 → 5 |
| **Pele** | "Está se coçando mais?" | minutos e episódios de `cocando` | 3 (depende da Fase 1–2) |
| **Algo diferente** | "Ele está apático ou mudou?" | alertas por z-score robusto contra o baseline | 4 |
| **Água** | "Está bebendo muito mais?" | minutos de `bebendo` | 6 |

## Sono

Pedido explícito do usuário (2026-11-16). Três níveis, do mais confiável ao experimental:

1. **Sono estimado por imobilidade (actigrafia)**: horas dormindo à noite, horário em que
   deitou e levantou, nº de despertares (saiu de `parado` por ≥ 1 min), maior trecho sem
   acordar, sonecas de dia. Sai do resumo por minuto que já existe (contrato 4.7), sem
   modelo novo. Bom para tendência, não exato minuto a minuto. **Fase 3.**
2. **Dormindo × deitado acordado**: acordado, o cachorro mexe e ergue a cabeça; dormindo,
   o ângulo do pescoço muda (cabeça apoiada) e quase não há micro-movimento. Precisa de
   gabarito: **gravar noites com câmera de visão noturna na Fase 1**. Se der para separar,
   "dormindo" vira uma classe nova ou uma flag no resumo por minuto (decidir em ADR, já que
   hoje dormir está dentro da classe 0).
3. **Respiração dormindo (experimental)**: o movimento da respiração pode aparecer no
   acelerômetro quando o cachorro está imóvel. Veterinários pedem aos donos que contem a
   respiração em repouso, porque um aumento persistente (acima de ~30/min) é sinal precoce
   de problema cardíaco. É o indicador de maior valor clínico, se a coleira captar.
   - Validar com as noites gravadas na Fase 1 (contar respirações no vídeo × sinal bruto).
   - Energia: amostrar ~1 min a cada 30 min durante o sono, e não continuamente (Fase 5).
   - Exige campo novo no resumo → resumo v2 (o byte de versão do ADR 0001 já prevê isso).

O app nunca chama isso de "exame de sono": sempre "estimado pelo movimento".

## O que NÃO vai para a tela principal

- **Chacoalhões:** continuam sendo uma classe do modelo (um movimento forte que ele precisa
  reconhecer para não confundir com outros), mas o número sozinho não leva a nenhuma ação.
  Ficam disponíveis só no detalhe do dia.
- **Promessas de sono que não medimos** (fases do sono, "qualidade" em nota de 0 a 100):
  só mostrar o que os níveis acima sustentam.

## Ideias para depois

- **Balançar a cabeça** (classe nova, ID 7+): sinal clássico de otite, com valor clínico
  maior que o chacoalhão de corpo inteiro. Exige coleta e ADR.
- Compartilhar um resumo com o veterinário (página web usando a API da Fase 4).
