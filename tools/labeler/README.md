# Labeler da Coleira

Ferramenta web para rotular sessões: vídeo e sinal do IMU lado a lado, com atalhos de
teclado. HTML + JS puro, sem instalar nada: **abra o `index.html` no Chrome ou no Edge**.
Precisa de internet só para baixar o uPlot (gráficos) do CDN.

## Fluxo

1. **Abrir pasta da sessão** e escolher a pasta com `imu.csv`, `meta.json` e o vídeo
   (formato dos contratos 4.4–4.5).
2. **Sincronizar** (ADR 0003):
   - pause no frame em que a mão bate na caixa (1ª batida do início) → *início / vídeo: marcar*;
   - clique em *início / sinal: marcar* e depois no pico do gráfico (o clique gruda no pico
     mais próximo, ±0,5 s);
   - repita para a 1ª batida do **fim**. Com início + fim, a deriva do relógio é corrigida.
3. **Rotular** assistindo ao vídeo: tecla da classe começa um trecho, outra tecla fecha o
   atual e começa o próximo, a mesma tecla ou `Enter` fecha. `I` marca como incerto
   (confiança 0,5), `Del` apaga o trecho sob o cursor.
4. **Exportar rótulos** gera `<session_id>.csv` no formato do contrato 4.6 (vai para
   `ml/data/labels/`). **Exportar meta.json** salva as batidas em `sync_taps`.

O trabalho fica salvo como rascunho neste navegador (por `session_id`). Ainda assim,
exporte ao terminar: o rascunho some se os dados do site forem apagados.

| Tecla | Ação |
|---|---|
| `0`–`6` | parado, andando, correndo, coçando, chacoalhando, comendo, bebendo |
| `x` | desconhecido / transição (255) |
| `Espaço` | play/pause |
| `←` `→` | ±1 s (`Shift`: ±5 s) |
| `,` `.` | ±1 frame |
| `[` `]` | velocidade (0,25× a 4×) |
| `Z` | janela do gráfico (10 s / 30 s / 120 s / tudo) |

O painel *Sessão* mostra o ODR medido e a **perda de pacotes** (critério da Fase 1: < 1%).
A legenda soma os minutos por classe e fica verde quando uma classe 0–4 passa de 3 min.

## Testar sem hardware

```bash
cd ml
uv run python scripts/make_synthetic_session.py
```

O script cria `ml/data/raw/synthetic_demo/` com um sinal real do dataset público, um vídeo
que mostra o comportamento na tela e "pisca" nas batidas, e um gabarito
(`labels_truth.csv`). Ele simula vídeo atrasado, deriva de relógio, perda de pacotes e a
volta do `seq`.

## Código

- `core.js`: lógica pura (linha do tempo, sincronização, trechos, exportação), sem DOM.
- `app.js`: interface (vídeo, uPlot, teclado).
- Testes da lógica: `node --test tools/labeler/test/core.test.js`.

Ambos são scripts clássicos (sem `import`), porque módulos ES não carregam em páginas
abertas via `file://`.
