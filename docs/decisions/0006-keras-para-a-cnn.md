# ADR 0006: Keras/TensorFlow (e não PyTorch) para a CNN embarcada

- **Status:** aceito
- **Data:** 2026-11-16
- **Afeta:** seção 5 (stack de ML)

## Contexto

O destino da CNN é o **TFLite Micro** no nRF52840, em int8. O plano previa treinar em
PyTorch e converter. A conversão PyTorch → TFLite int8 passa por cadeias como
PyTorch → ONNX → TF (`onnx2tf`) ou pelo `ai-edge-torch`. A primeira costuma quebrar em
detalhes (layout NCHW/NHWC, operadores não suportados), e a segunda não dá suporte
oficial a Windows, que é o ambiente de desenvolvimento.

## Decisão

Treinar a CNN em **Keras 3 sobre TensorFlow** e converter com o `TFLiteConverter` nativo
(quantização int8 completa com dataset representativo). O scikit-learn continua para os
baselines.

## Alternativas

- **PyTorch + onnx2tf:** ecossistema que muita gente prefere, mas acrescenta um elo
  frágil justamente na etapa que vai para o chip.
- **PyTorch + ai-edge-torch:** caminho oficial do Google, mas sem suporte a Windows (exigiria WSL).

## Consequência

Dependência pesada (`tensorflow`, ~400 MB) no ambiente de ML. A CNN é pequena (3 camadas
convolucionais), então trocar de framework no futuro seria barato, já que a arquitetura e
os dados ficam em `coleira_ml` e não dependem do framework.
